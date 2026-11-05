# fetchconfig - Retrieving configuration for multiple devices
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# fetchconfig is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fetchconfig; see the file COPYING. If not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
# $Id: History.pm,v 1.0 2026/10/31 00:00:00 tammer Exp $

# Optional PostgreSQL backup-history writer. Inert unless a "db:" line is set in
# the device table (default: level). Flow:
#
#   parse_db_line()  records the db: config at device-table parse time.
#   finish()         end-of-run, PARENT only, after every worker result has been
#                    replayed into fetchconfig::Mailer. It builds the per-run ops
#                    from the recorded results, writes a per-repository WRITE-AHEAD
#                    spool file (<repo>/.db-<pid>-<ts>), then drains all spool
#                    files (this run's plus any backlog) into the DB in one
#                    transaction per file, oldest first. The fetch path never
#                    touches the DB; an outage only defers the drain.
#
# PostgreSQL 8.2+ compatible: no ON CONFLICT/MERGE/jsonb; append-only inserts use
# INSERT ... WHERE NOT EXISTS; the per-device current row is UPDATE-else-INSERT.
# All DML uses DBI placeholders. DBI/DBD::Pg are loaded only when a db: is set.
# The schema and the writer role are owned by fetchconfig-web; this module only
# writes and never issues DDL.

package fetchconfig::History;

use strict;
use warnings;
use Text::ParseWords ();
use Time::Local qw(timelocal timegm);
use Digest::SHA ();   # core; only used by the --db-backfill path

# A true-UTC instant -> the "local wall-clock epoch" convention the DB uses
# (local date/time encoded as seconds, as if UTC; see
# Abstract::backup_epoch_from_parts). Everything stored in the DB (run_end,
# last_good_at, expired_at, file_timestamp) uses this one convention, so the box's
# local time is consistent across all columns and fetchconfig-web renders the
# values as-is, with no timezone conversion.
sub _local_epoch {
    my ($t) = @_;
    $t = time unless defined $t;
    my @l = localtime($t);
    return timegm($l[0], $l[1], $l[2], $l[3], $l[4], $l[5]);
}

my %db_cfg;        # parsed db: options
my $db_seen = 0;   # a db: line was present
my $log;           # logger (fetchconfig::Logger)
my %summary;       # drain result for the status mail
my $delta_cols;    # 1/0 after probing: does backup_versions have lines_added/_removed?
                   # (undef = not probed -> treated as absent; keeps unit tests 8.2-neutral)

my $DEFAULT_PORT          = 5432;
my $DEFAULT_CONNECT_TMO   = 5;
my $DEFAULT_MAX_OUTBOX_D  = 90;
my $DEFAULT_SSLMODE       = 'disable';   # local DB on the same box; no TLS by default

# End-of-run log section header, same 92-char width as Mailer's "-----[email]-----".
my $SECTION_DIVIDER = '-----[DB writer]----------------------------------------------------------------------------';

# --db-backfill logs its own section under this label, same width as the writer one.
my $BACKFILL_DIVIDER = '-----[DB backfill]'
    . ('-' x (length($SECTION_DIVIDER) - length('-----[DB backfill]')));

# --replay-db-change and the end-of-rename drain log under this label.
my $REPLAY_DIVIDER = '-----[DB replay]'
    . ('-' x (length($SECTION_DIVIDER) - length('-----[DB replay]')));

sub configured { $db_seen }

#
# db: db_inst=fetchconfig,db_user=fetchconfig_dashboard,db_pass=xxx,db_host=localhost
#
# Comma-separated key=value using the device-table quoting rules (a db_pass that
# contains "," or "=" survives inside a double-quoted span). Never logs db_pass.
#
sub parse_db_line {
    my ($class, $file, $line_num, $line, $rest, $logger) = @_;

    $log = $logger if defined($logger);
    $db_seen = 1;

    foreach (Text::ParseWords::parse_line(',', 1, $rest)) {
        next unless defined && /\S/;
        if (/^([^=]+)=(.*)$/s) {
            my $opt = _trim($1);
            my $val = _dequote(_trim($2));
            $db_cfg{$opt} = $val;
            next;
        }
        _err($file, $line_num, "bad db option '" . _mask($_) . "'");
    }

    # defaults
    $db_cfg{db_connect_timeout}= $DEFAULT_CONNECT_TMO  unless _posint($db_cfg{db_connect_timeout});
    $db_cfg{db_max_outbox_days}= $DEFAULT_MAX_OUTBOX_D unless _posint($db_cfg{db_max_outbox_days});
    $db_cfg{db_sslmode}        = $DEFAULT_SSLMODE      unless defined($db_cfg{db_sslmode}) && length($db_cfg{db_sslmode});

    for my $req (qw(db_inst db_user db_host)) {
        _err($file, $line_num, "db: missing required key '$req'")
            unless defined($db_cfg{$req}) && length($db_cfg{$req});
    }

    # Split db_host into host + port now so a bad value is reported at parse time.
    my ($host, $port) = _parse_host($db_cfg{db_host});
    if (!defined($host)) {
        _err($file, $line_num, "db: bad db_host '" . ($db_cfg{db_host} // '') . "'");
    }
    $db_cfg{_host} = $host;
    $db_cfg{_port} = $port;   # may be undef -> default at connect
}

#
# IPv6-capable host[:port] split. Bracket convention so a port is still
# expressible with an IPv6 literal:
#   [addr]:port -> (addr, port)        IPv6 with port
#   [addr]      -> (addr, undef)       IPv6, default port
#   >=2 colons, no brackets -> (whole, undef)   bare IPv6 literal, default port
#   exactly one colon -> host:port
#   no colon          -> (host, undef)
# Returns (undef) on a malformed value.
#
sub _parse_host {
    my ($raw) = @_;
    return (undef) unless defined($raw) && length($raw);

    if ($raw =~ /^\[([^\]]+)\](?::(\d+))?$/) {         # [addr] or [addr]:port
        return ($1, $2);
    }
    return (undef) if $raw =~ /[\[\]]/;                # stray bracket -> malformed

    my $colons = ($raw =~ tr/:/:/);
    if ($colons >= 2) {                               # bare IPv6 literal, host only
        return ($raw, undef);
    }
    if ($colons == 1) {                               # host:port
        my ($h, $p) = split /:/, $raw, 2;
        return (undef) unless length($h) && $p =~ /^\d+$/;
        return ($h, $p);
    }
    return ($raw, undef);                             # hostname/IPv4, default port
}

# End-of-run step (parent). No-op unless db: is set. Builds ops from the recorded
# results, writes the write-ahead spool per repository, drains all spools.
sub finish {
    my ($class, $logger) = @_;
    $log = $logger if defined($logger);
    return unless $db_seen;

    # Own log section, mirroring the mail's "-----[email]-----". Emitted first so
    # any spool/drain warnings below land under it; the result line closes it.
    # Independent of "email:" (this runs before send_summaries, which returns
    # early without mail), so a no-mail run still reports the DB outcome.
    $log->info($SECTION_DIVIDER) if $log;

    my @results = fetchconfig::Mailer->results;
    my @expires = fetchconfig::Mailer->expires;

    my %by_repo = _ops_by_repo(\@results, \@expires);

    # Write this run's spool file into each repository that produced ops.
    for my $repo (sort keys %by_repo) {
        _write_spool($repo, $by_repo{$repo});
    }

    # Drain every repository we have touched (this run's repos). Leftover spool
    # files in a retired repository are not scanned here (documented edge).
    my %repos = map { $_ => 1 } keys %by_repo;
    _drain(\%repos);

    # Close the section with the result line (same text as the mail footer).
    my $line = $class->status_line;
    $log->info($line) if $log && defined($line);
}

# --- Device-id rename support + standalone outbox replay ----------------------

# Queue one op=rename into $repo's outbox (its own spool file, timestamp-ordered
# with any other ops). The drain -- replay() below, or the next run's finish --
# applies it. Idempotent at apply time (WHERE dev_id=<old>). Returns 1 if the op
# was written to the outbox, 0 otherwise.
sub queue_rename {
    my ($class, $logger, $repo, $old, $new) = @_;
    $log = $logger if defined($logger);
    return 0 unless defined($repo) && length($repo);
    return _write_spool($repo, [ { op => 'rename', old_dev_id => $old, new_dev_id => $new } ]) ? 1 : 0;
}

# Drain the outboxes of the given repositories on demand: the end-of-rename
# apply, and the standalone --replay-db-change maintenance mode. Mirrors finish's
# drain + status line but is not tied to a fetch run. $preview only reports what
# is pending (no DB writes). Returns 0 if nothing is left pending, 1 otherwise.
sub replay {
    my ($class, $logger, $repos_ref, $preview) = @_;
    $log = $logger if defined($logger);
    my @repos = $repos_ref ? @$repos_ref : ();

    $log->info($REPLAY_DIVIDER) if $log;

    if ($preview) {
        my ($pending, $oldest) = (0, undef);
        for my $repo (@repos) {
            for my $f (_spool_files($repo)) {
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
            }
        }
        $log->info("--replay-db-change: $pending pending DB spool file(s)"
            . (defined($oldest) ? " (oldest $oldest)" : "")
            . " - preview, nothing applied") if $log;
        return $pending ? 1 : 0;
    }

    my %repos = map { $_ => 1 } @repos;
    _drain(\%repos);
    my $line = $class->status_line;
    $log->info($line) if $log && defined($line);
    return ($summary{ok} ? 0 : 1);
}

# Total rows the DB currently holds for $dev_id across the three tables, or undef
# if the DB is unreachable / DBI is unavailable (the caller then skips the live
# pre-check and relies on the apply-time transaction as the backstop). Used by
# --rename-device-id to refuse a new id that already has DB rows (a ghost from a
# previously-deleted device).
sub row_count_for_dev {
    my ($class, $logger, $dev_id) = @_;
    $log = $logger if defined($logger);
    return undef unless $db_seen;
    return undef unless eval { require DBI; 1 };
    my $dbh = _connect() or return undef;
    my $total = 0;
    for my $tbl (qw(backup_current backup_runs backup_versions)) {
        my ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM $tbl WHERE dev_id = ?", undef, $dev_id);
        if (!defined($n)) { $dbh->disconnect; return undef; }
        $total += $n;
    }
    $dbh->disconnect;
    return $total;
}

# --- Backfill (--db-backfill) -------------------------------------------------
# Reconstruct the DB history from the backups already on disk, for every loaded
# device. Direct writes, idempotent and repeatable: an existing row is left
# alone, so a re-run only fills what is still missing (and does not re-hash a
# backup that is already recorded). Fills:
#   backup_versions - one row per on-disk backup; sha1 recomputed from the file
#                     bytes (the live writer hashes the same bytes it writes, so
#                     the value is identical).
#   backup_runs     - one row per on-disk backup (state=success, changed=changed,
#                     run_end = the file timestamp, duration_sec NULL). The dense
#                     run history (unchanged/failed runs) left no file and cannot
#                     be reconstructed; only the saved change-events are added.
#   backup_current  - one row per device that has none yet, from <dev_id>.status
#                     (the authoritative last run) plus the newest backup (size,
#                     last_good); never overwrites a row a real run already wrote.
# $preview (-T): report what WOULD be inserted; connects read-only, no hashing,
# no writes. Returns a process exit code (0 ok, 1 DB unreachable or write error).
sub backfill {
    my ($class, $logger, $preview) = @_;
    $log = $logger if defined($logger);

    $log->info($BACKFILL_DIVIDER) if $log;

    unless ($db_seen) {
        $log->error("--db-backfill: no db: configured in the device table") if $log;
        return 1;
    }
    unless (eval { require DBI; 1 }) {
        $log->error("--db-backfill: DBI not available (install DBI and DBD::Pg)") if $log;
        return 1;
    }

    my $dbh = _connect();
    unless ($dbh) {
        $log->error("--db-backfill: cannot connect to the history database") if $log;
        return 1;
    }

    my @dev_ids = fetchconfig::model::Detector->device_ids;
    $log->info("--db-backfill: scanning " . scalar(@dev_ids) . " device(s)"
               . ($preview ? " (preview - no writes)" : "")) if $log;

    my %t = (ver => 0, vupd => 0, run => 0, cur => 0, vskip => 0, rskip => 0, cskip => 0, errors => 0);

    for my $dev_id (@dev_ids) {
        my $info = fetchconfig::model::Detector->device_info($dev_id);
        next unless defined($info);
        my $mod  = $info->{model};
        my $tab  = $info->{dev_opt_tab};
        my $repo = $mod->dev_option($tab, "repository");
        next unless defined($repo) && length($repo);

        # Enumerate on-disk backups (quietly - an empty device is not an error).
        my %dir_tab;
        $mod->scan_dir(\%dir_tab, $dev_id, $repo);
        my @unparsed;
        my @files = fetchconfig::model::Abstract::sort_backups_desc(
                        $dev_id, [keys %dir_tab], \@unparsed);

        my ($newest_ts, $newest_size);
        my $prev_lines;   # normalized lines of the previous (older) backup, for the delta
        my %d = (ver => 0, vupd => 0, run => 0, cur => 0, vskip => 0, rskip => 0, cskip => 0);
        my $dev_err = 0;

        # Oldest first, so each version's delta is against its immediate predecessor.
        for my $file (reverse @files) {
            my $fts = fetchconfig::model::Abstract->backup_epoch_from_filename($dev_id, $file);
            next unless defined($fts);
            my $dir  = $dir_tab{$file};
            my $path = "$dir/$file";
            $log->debug("process: $path") if $log;
            my $size = (stat($path))[7];
            $newest_ts = $fts; $newest_size = $size;   # oldest-first: the last seen is newest

            # Normalized line view (ignore-aware where the model's rules are loaded,
            # raw otherwise - e.g. a template not loaded in backfill) and the delta
            # against the previous version. undef = baseline or an unreadable file.
            my $curr_lines = $mod->config_norm_lines($dir, $file);
            my ($la, $lr);
            if (defined($prev_lines) && defined($curr_lines)) {
                ($la, $lr) = fetchconfig::model::Abstract::line_delta($prev_lines, $curr_lines);
            }
            $prev_lines = $curr_lines if defined($curr_lines);

            # --- backup_versions: insert a missing row, or fill a NULL delta -------
            if ($delta_cols) {
                my ($ok, $row) = _fetch_row($dbh,
                    'SELECT lines_added FROM backup_versions WHERE dev_id = ? AND file_timestamp = ?',
                    $dev_id, $fts);
                if (!$ok) { $dev_err = 1; last; }
                if (!$row) {                                   # no row -> insert (with delta)
                    if ($preview) { $d{ver}++; }
                    else {
                        my $sha1 = _sha1_file($path);
                        if (!defined $sha1) {
                            $log->error("--db-backfill: cannot read $path - skipping its version row") if $log;
                            $t{errors}++;
                        }
                        elsif (defined _apply_op($dbh, { op => 'version', dev_id => $dev_id,
                                file_timestamp => $fts, path => $path, size_bytes => $size,
                                sha1 => $sha1, lines_added => $la, lines_removed => $lr })) { $d{ver}++; }
                        else { $dev_err = 1; last; }
                    }
                }
                elsif (!defined($row->[0]) && defined($la)) {  # existing row, NULL delta -> fill it
                    if ($preview) { $d{vupd}++; }
                    elsif (defined _do($dbh,
                        'UPDATE backup_versions SET lines_added = ?, lines_removed = ?
                         WHERE dev_id = ? AND file_timestamp = ?',
                        $la, $lr, $dev_id, $fts)) { $d{vupd}++; }
                    else { $dev_err = 1; last; }
                }
                else { $d{vskip}++; }                          # baseline, or delta already present
            }
            else {
                # Web schema < 2.12 (no delta columns): original insert-missing only.
                my $ve = _row_exists($dbh,
                    'SELECT 1 FROM backup_versions WHERE dev_id = ? AND file_timestamp = ?',
                    $dev_id, $fts);
                if (!defined $ve) { $dev_err = 1; last; }
                elsif ($ve)       { $d{vskip}++; }
                elsif ($preview)  { $d{ver}++; }
                else {
                    my $sha1 = _sha1_file($path);
                    if (!defined $sha1) {
                        $log->error("--db-backfill: cannot read $path - skipping its version row") if $log;
                        $t{errors}++;
                    }
                    elsif (defined _apply_op($dbh, { op => 'version', dev_id => $dev_id,
                            file_timestamp => $fts, path => $path,
                            size_bytes => $size, sha1 => $sha1 })) { $d{ver}++; }
                    else { $dev_err = 1; last; }
                }
            }

            # --- backup_runs: synthetic change-event (run_end = the file timestamp) -
            my $re = _row_exists($dbh,
                'SELECT 1 FROM backup_runs WHERE dev_id = ? AND run_end = ?',
                $dev_id, $fts);
            if (!defined $re) { $dev_err = 1; last; }
            elsif ($re)       { $d{rskip}++; }
            elsif ($preview)  { $d{run}++; }
            elsif (defined _apply_op($dbh, { op => 'run', dev_id => $dev_id, run_end => $fts,
                    state => 'success', changed => 'changed', duration_sec => undef,
                    size_bytes => $size, fail_reason => undef, repository => $repo }))
                              { $d{run}++; }
            else              { $dev_err = 1; last; }
        }

        # backup_current - only for a device that has no row yet.
        unless ($dev_err) {
            my $ce = _row_exists($dbh,
                'SELECT 1 FROM backup_current WHERE dev_id = ?', $dev_id);
            if (!defined $ce) { $dev_err = 1; }
            elsif ($ce)       { $d{cskip}++; }
            else {
                my $cur = _current_row($dev_id, $repo, $newest_ts, $newest_size);
                if ($cur && $preview) { $d{cur}++; }
                elsif ($cur) {
                    if (defined _do($dbh,
                        'INSERT INTO backup_current
                           (dev_id, repository, run_end, state, changed, duration_sec,
                            size_bytes, fail_reason, last_good_at, last_good_size)
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                        @{$cur}{qw(dev_id repository run_end state changed duration_sec
                                   size_bytes fail_reason last_good_at last_good_size)}))
                        { $d{cur}++; }
                    else { $dev_err = 1; }
                }
            }
        }

        if ($preview) {
            $dbh->rollback;
        }
        elsif ($dev_err) {
            $dbh->rollback;
            $t{errors}++;
            $log->error("--db-backfill: dev=$dev_id rolled back after a DB error") if $log;
            next;   # do not fold this device's tentative counts
        }
        elsif (!$dbh->commit) {
            $t{errors}++;
            $log->error("--db-backfill: dev=$dev_id commit failed: "
                       . ($DBI::errstr // 'unknown')) if $log;
            next;
        }
        $t{$_} += $d{$_} for keys %d;
    }

    $dbh->disconnect;

    if ($log) {
        my $verb  = $preview ? "would add"  : "added";
        my $verb2 = $preview ? "would fill" : "filled";
        $log->info(sprintf(
            "--db-backfill: %s %d version, %d run, %d current row(s); %s %d line-delta(s) "
            . "on existing rows; skipped %d/%d/%d already present; %d error(s)",
            $verb, $t{ver}, $t{run}, $t{cur}, $verb2, $t{vupd},
            $t{vskip}, $t{rskip}, $t{cskip}, $t{errors}));
        if ($t{errors}) { $log->error("--db-backfill: finished with $t{errors} error(s)"); }
        else            { $log->info("Success"); }
    }

    return $t{errors} ? 1 : 0;
}

# Build a backup_current row for a device that has none yet, from its .status
# file (the authoritative last run) plus the newest on-disk backup (size +
# last_good). Falls back to the newest backup alone - a saved backup is a
# successful run by definition - when there is no .status. Returns a hashref, or
# undef if there is nothing on disk to record.
sub _current_row {
    my ($dev_id, $repo, $newest_ts, $newest_size) = @_;

    my %s = _read_status("$repo/$dev_id.status");
    if (defined($s{state}) && defined($s{run_end})) {
        my $ok = ($s{state} eq 'success');
        return {
            dev_id         => $dev_id,
            repository     => $repo,
            run_end        => $s{run_end},
            state          => $s{state},
            changed        => (defined($s{changed}) ? $s{changed} : 'unknown'),
            duration_sec   => $s{duration_sec},
            size_bytes     => ($ok ? $newest_size : undef),
            fail_reason    => undef,
            last_good_at   => ($ok ? $s{run_end} : $newest_ts),
            last_good_size => $newest_size,
        };
    }
    return undef unless defined($newest_ts);   # no .status and no backups on disk
    return {
        dev_id         => $dev_id,
        repository     => $repo,
        run_end        => $newest_ts,
        state          => 'success',
        changed        => 'changed',
        duration_sec   => undef,
        size_bytes     => $newest_size,
        fail_reason    => undef,
        last_good_at   => $newest_ts,
        last_good_size => $newest_size,
    };
}

# Parse a <dev_id>.status file. Returns a hash with state/changed/duration_sec
# and run_end (the end date+time encoded with the DB's local-wall-clock-epoch
# convention, same as a backup's file_timestamp). Empty list if unreadable.
sub _read_status {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my %raw;
    while (my $ln = <$fh>) {
        $raw{$1} = $2 if $ln =~ /^([a-z_]+)\s*=\s*(.*?)\s*$/;
    }
    close $fh;

    my %out;
    $out{state}        = $raw{backup_state}   if defined $raw{backup_state};
    $out{changed}      = $raw{backup_changed} if defined $raw{backup_changed};
    $out{duration_sec} = $raw{backup_duration_sec}
        if defined($raw{backup_duration_sec}) && $raw{backup_duration_sec} =~ /^\d+$/;
    if (defined($raw{backup_end_date}) && defined($raw{backup_end_time})
        && $raw{backup_end_date} =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        my ($y, $mo, $dd) = ($1, $2, $3);
        if ($raw{backup_end_time} =~ /^(\d{2}):(\d{2}):(\d{2})$/) {
            $out{run_end} =
                fetchconfig::model::Abstract::backup_epoch_from_parts($y, $mo, $dd, $1, $2, $3);
        }
    }
    %out;
}

# Whether a row exists (1/0); undef on a DB error so the caller can abort.
sub _row_exists {
    my ($dbh, $sql, @bind) = @_;
    my $sth = $dbh->prepare($sql) or return undef;
    return undef unless defined $sth->execute(@bind);
    my $row = $sth->fetchrow_arrayref;
    $sth->finish;
    return $row ? 1 : 0;
}

# Fetch one row: returns ($ok, $row). $ok=0 on a DB error (caller aborts); $row is
# the first row's arrayref, or undef when no row matched (a column value may itself
# be undef for a NULL). Used by backfill to tell "no version row" from "row present
# with a NULL delta" from "row already has a delta".
sub _fetch_row {
    my ($dbh, $sql, @bind) = @_;
    my $sth = $dbh->prepare($sql) or return (0, undef);
    return (0, undef) unless defined $sth->execute(@bind);
    my $row = $sth->fetchrow_arrayref;
    $sth->finish;
    (1, $row);
}

# sha1 of a file's raw bytes - identical to what a live save records (it hashes
# the exact bytes it writes). undef if the file cannot be read.
sub _sha1_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    binmode $fh;
    my $sha = Digest::SHA->new(1);
    my $ok  = eval { $sha->addfile($fh); 1 };
    close $fh;
    return $ok ? $sha->hexdigest : undef;
}

# Build the per-repository op list from the run's results and expire events.
sub _ops_by_repo {
    my ($results, $expires) = @_;
    my %by_repo;

    for my $r (@$results) {
        my $repo = $r->{repository};
        next unless defined($repo) && length($repo);

        my $elapsed = (defined($r->{elapsed}) && $r->{elapsed} =~ /^\d+$/) ? $r->{elapsed} : 0;
        my $end_ts  = (defined($r->{ts}) && $r->{ts} =~ /^\d+$/) ? $r->{ts} + $elapsed : time;
        my $run_end = _local_epoch($end_ts);

        my $state = defined($r->{state}) ? $r->{state}
                  : !defined($r->{success}) ? 'skipped'
                  : $r->{success} ? 'success' : 'failed';

        my $changed;
        if ($state ne 'success')                                        { $changed = 'unknown'; }
        elsif (defined($r->{changed}) && $r->{changed} eq 'initial')    { $changed = 'initial'; }
        elsif ($r->{changes_only}) {
            $changed = (defined($r->{changed}) && $r->{changed} eq 'unchanged') ? 'unchanged' : 'changed';
        }
        else                                                            { $changed = 'forced'; }

        my $success    = ($state eq 'success') ? 1 : 0;
        my $size       = (defined($r->{size}) && $r->{size} =~ /^\d+$/) ? $r->{size} : undef;
        my $fail_reason= ($state eq 'failed') ? 'other' : undef;

        # run (dense) + current (per device) - always.
        push @{ $by_repo{$repo} }, {
            op => 'run', dev_id => $r->{dev_id}, run_end => $run_end, state => $state,
            changed => $changed, duration_sec => $elapsed, size_bytes => $size,
            fail_reason => $fail_reason, repository => $repo,
        };
        push @{ $by_repo{$repo} }, {
            op => 'current', dev_id => $r->{dev_id}, run_end => $run_end, state => $state,
            changed => $changed, duration_sec => $elapsed, size_bytes => $size,
            fail_reason => $fail_reason, repository => $repo, success => $success,
        };

        # version (sparse) - only a retained backup carries path/sha1/timestamp.
        # lines_added/lines_removed are the per-version delta (undef = baseline or
        # not computed); they round-trip through the spool like any other field.
        if (defined($r->{path}) && defined($r->{file_timestamp}) && defined($r->{sha1})) {
            push @{ $by_repo{$repo} }, {
                op => 'version', dev_id => $r->{dev_id},
                file_timestamp => $r->{file_timestamp}, path => $r->{path},
                size_bytes => $size, sha1 => $r->{sha1},
                lines_added => $r->{lines_added}, lines_removed => $r->{lines_removed},
            };
        }
    }

    for my $e (@$expires) {
        my $repo = $e->{repository};
        next unless defined($repo) && length($repo);
        next unless defined($e->{file_timestamp});
        push @{ $by_repo{$repo} }, {
            op => 'expire', dev_id => $e->{dev_id}, file_timestamp => $e->{file_timestamp},
        };
    }

    %by_repo;
}

# Write one write-ahead spool file (<repo>/.db-<pid>-YYYYMMDD_HHMMSS) atomically
# (temp + rename). Dotfile, so the repository scan skips it.
sub _write_spool {
    my ($repo, $ops) = @_;
    return unless @$ops;

    my @t = localtime(time);
    my $stamp = sprintf("%04d%02d%02d_%02d%02d%02d",
                        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    my $final = "$repo/.db-$$-$stamp";
    my $tmp   = "$final.tmp";

    if (!open(my $fh, '>', $tmp)) {
        _warn("cannot write DB spool $tmp: $!");
        return 0;
    }
    else {
        for my $op (@$ops) {
            print $fh _serialize($op), "\n";
        }
        if (!close($fh)) {
            _warn("cannot close DB spool $tmp: $!");
            unlink $tmp;
            return 0;
        }
    }
    if (!rename($tmp, $final)) {
        _warn("cannot finalize DB spool $final: $!");
        unlink $tmp;
        return 0;
    }
    return 1;
}

# Drain the spool files of every given repository into the DB. One transaction
# per file, oldest first; stop on the first failure (that file and all later
# ones stay for the next run); delete only after COMMIT. Prune spool files older
# than db_max_outbox_days before draining.
sub _drain {
    my ($repos) = @_;

    my $delivered = 0;   # ops committed this drain
    my $pending   = 0;   # spool files left behind
    my $oldest;          # oldest pending ts string

    # Load DBI only now (optional dependency).
    if (!eval { require DBI; 1 }) {
        _warn("DBI not available - DB history disabled this run (spool kept)");
        for my $repo (sort keys %$repos) {
            for my $f (_spool_files($repo)) {
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
            }
        }
        %summary = (delivered => 0, pending => $pending, oldest => $oldest, ok => 0);
        return;
    }

    my $dbh = _connect();
    if (!$dbh) {
        for my $repo (sort keys %$repos) {
            for my $f (_spool_files($repo)) {
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
            }
        }
        %summary = (delivered => 0, pending => $pending, oldest => $oldest, ok => 0);
        return;
    }

    my $max_age = time - $db_cfg{db_max_outbox_days} * 86400;
    my $stopped = 0;

    REPO: for my $repo (sort keys %$repos) {
        my @files = _spool_files($repo);
        for my $f (@files) {
            # prune the very old (whole file dropped).
            my $epoch = _stamp_epoch($f->{stamp});
            if (defined($epoch) && $epoch < $max_age) {
                _warn("dropping DB spool older than $db_cfg{db_max_outbox_days} days: $f->{path}");
                unlink $f->{path};
                next;
            }

            if ($stopped) {
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
                next;
            }

            my ($ops, $read_ok) = _read_spool($f->{path});
            if (!$read_ok) {
                # unreadable/corrupt - leave it, stop (manual attention).
                $stopped = 1;
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
                next;
            }

            my $applied = _apply_file($dbh, $ops);
            if ($applied < 0) {
                $dbh->rollback;
                $stopped = 1;
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
                _warn("DB drain failed on $f->{path} (left for next run): " . ($dbh->errstr // 'unknown'));
                next;
            }
            if (!$dbh->commit) {
                $dbh->rollback;
                $stopped = 1;
                $pending++;
                $oldest = $f->{stamp} if !defined($oldest) || $f->{stamp} lt $oldest;
                _warn("DB commit failed on $f->{path} (left for next run): " . ($dbh->errstr // 'unknown'));
                next;
            }
            unlink $f->{path};
            $delivered += $applied;
        }
    }

    $dbh->disconnect;
    %summary = (delivered => $delivered, pending => $pending, oldest => $oldest,
                ok => ($pending == 0) ? 1 : 0);
}

# Apply all ops of one spool file within the current transaction. Returns the
# number of ops applied, or -1 on the first error (caller rolls back).
sub _apply_file {
    my ($dbh, $ops) = @_;
    my $n = 0;
    for my $op (@$ops) {
        my $ok = _apply_op($dbh, $op);
        return -1 unless $ok;
        $n++;
    }
    $n;
}

# One op -> pre-9.5 DML via placeholders. Returns 1 on success, 0 on error.
sub _apply_op {
    my ($dbh, $op) = @_;
    my $kind = $op->{op} // '';

    if ($kind eq 'run') {
        my $sql = 'INSERT INTO backup_runs
                     (dev_id, run_end, state, changed, duration_sec, size_bytes, fail_reason, repository)
                   SELECT ?, ?, ?, ?, ?, ?, ?, ?
                   WHERE NOT EXISTS (SELECT 1 FROM backup_runs WHERE dev_id = ? AND run_end = ?)';
        return _do($dbh, $sql,
            $op->{dev_id}, $op->{run_end}, $op->{state}, $op->{changed},
            $op->{duration_sec}, $op->{size_bytes}, $op->{fail_reason}, $op->{repository},
            $op->{dev_id}, $op->{run_end});
    }

    if ($kind eq 'version') {
        # Write lines_added/lines_removed too when the web 2.12 columns exist
        # (probed at connect); otherwise the original 5-column insert.
        if ($delta_cols) {
            my $sql = 'INSERT INTO backup_versions
                         (dev_id, file_timestamp, path, size_bytes, sha1, lines_added, lines_removed)
                       SELECT ?, ?, ?, ?, ?, ?, ?
                       WHERE NOT EXISTS (SELECT 1 FROM backup_versions WHERE dev_id = ? AND file_timestamp = ?)';
            return _do($dbh, $sql,
                $op->{dev_id}, $op->{file_timestamp}, $op->{path}, $op->{size_bytes}, $op->{sha1},
                $op->{lines_added}, $op->{lines_removed},
                $op->{dev_id}, $op->{file_timestamp});
        }
        my $sql = 'INSERT INTO backup_versions
                     (dev_id, file_timestamp, path, size_bytes, sha1)
                   SELECT ?, ?, ?, ?, ?
                   WHERE NOT EXISTS (SELECT 1 FROM backup_versions WHERE dev_id = ? AND file_timestamp = ?)';
        return _do($dbh, $sql,
            $op->{dev_id}, $op->{file_timestamp}, $op->{path}, $op->{size_bytes}, $op->{sha1},
            $op->{dev_id}, $op->{file_timestamp});
    }

    if ($kind eq 'current') {
        # UPDATE-else-INSERT. Two UPDATE shapes avoid a boolean bind in a CASE
        # (safer on 8.2): a successful run advances last_good_*, a non-success
        # run leaves them untouched.
        my ($sql, @bind);
        if ($op->{success}) {
            $sql = 'UPDATE backup_current SET repository=?, run_end=?, state=?, changed=?,
                        duration_sec=?, size_bytes=?, fail_reason=?, last_good_at=?, last_good_size=?
                    WHERE dev_id=?';
            @bind = ($op->{repository}, $op->{run_end}, $op->{state}, $op->{changed},
                     $op->{duration_sec}, $op->{size_bytes}, $op->{fail_reason},
                     $op->{run_end}, $op->{size_bytes}, $op->{dev_id});
        }
        else {
            $sql = 'UPDATE backup_current SET repository=?, run_end=?, state=?, changed=?,
                        duration_sec=?, size_bytes=?, fail_reason=?
                    WHERE dev_id=?';
            @bind = ($op->{repository}, $op->{run_end}, $op->{state}, $op->{changed},
                     $op->{duration_sec}, $op->{size_bytes}, $op->{fail_reason}, $op->{dev_id});
        }
        my $rows = _do($dbh, $sql, @bind);
        return 0 unless defined($rows);
        return 1 if $rows > 0;

        # no existing row -> insert
        my $isql = 'INSERT INTO backup_current
                      (dev_id, repository, run_end, state, changed, duration_sec,
                       size_bytes, fail_reason, last_good_at, last_good_size)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';
        my $lga = $op->{success} ? $op->{run_end}    : undef;
        my $lgs = $op->{success} ? $op->{size_bytes} : undef;
        return defined(_do($dbh, $isql,
            $op->{dev_id}, $op->{repository}, $op->{run_end}, $op->{state}, $op->{changed},
            $op->{duration_sec}, $op->{size_bytes}, $op->{fail_reason}, $lga, $lgs)) ? 1 : 0;
    }

    if ($kind eq 'expire') {
        my $sql = 'UPDATE backup_versions SET expired=true, expired_at=?
                   WHERE dev_id=? AND file_timestamp=?';
        return defined(_do($dbh, $sql, _local_epoch(time), $op->{dev_id}, $op->{file_timestamp})) ? 1 : 0;
    }

    # Device-id rename (--rename-device-id): move every row of the device from
    # the old id to the new one, in the same transaction as any neighbouring
    # ops. Idempotent: once applied, WHERE dev_id=<old> matches nothing and the
    # three UPDATEs are 0-row no-ops. The table names are fixed, never input.
    # Needs GRANT UPDATE (dev_id) on the three tables (fetchconfig-web schema).
    if ($kind eq 'rename') {
        for my $tbl (qw(backup_current backup_runs backup_versions)) {
            my $r = _do($dbh, "UPDATE $tbl SET dev_id=? WHERE dev_id=?",
                        $op->{new_dev_id}, $op->{old_dev_id});
            return 0 unless defined($r);
        }
        return 1;
    }

    _warn("unknown DB op '$kind' in spool - skipping");
    return 1;   # don't wedge the drain on an unknown op
}

# Prepared-ish execute; returns affected rows (>=0) or undef on error.
sub _do {
    my ($dbh, $sql, @bind) = @_;
    my $sth = $dbh->prepare($sql);
    return undef unless $sth;
    my $rv = $sth->execute(@bind);
    return undef unless defined($rv);
    return $rv + 0;
}

sub _connect {
    my $dsn = "dbi:Pg:dbname=$db_cfg{db_inst}";
    $dsn .= ";host=$db_cfg{_host}" if defined($db_cfg{_host}) && length($db_cfg{_host});
    $dsn .= ";port=" . ($db_cfg{_port} // $DEFAULT_PORT);
    # Note: "sslmode" and "connect_timeout" here are the libpq DSN keywords
    # (fixed); the config keys the user sets are db_sslmode / db_connect_timeout.
    $dsn .= ";sslmode=$db_cfg{db_sslmode}" if defined($db_cfg{db_sslmode}) && length($db_cfg{db_sslmode});
    $dsn .= ";connect_timeout=$db_cfg{db_connect_timeout}";

    my $dbh = DBI->connect($dsn, $db_cfg{db_user}, $db_cfg{db_pass},
                           { AutoCommit => 0, RaiseError => 0, PrintError => 0 });
    if (!$dbh) {
        _warn("DB connect failed (spool kept): " . ($DBI::errstr // 'unknown'));
        return undef;
    }
    _probe_delta_cols($dbh);
    $dbh;
}

# Do the backup_versions.lines_added/lines_removed columns exist (web schema
# >= 2.12)? Probed once per connection so the writer stays compatible with a web
# side not yet upgraded: present -> write the deltas; absent -> write as before
# and the columns simply go unpopulated until the 2.12 migration is applied.
sub _probe_delta_cols {
    my ($dbh) = @_;
    my $r = _row_exists($dbh,
        "SELECT 1 FROM information_schema.columns
         WHERE table_name = 'backup_versions' AND column_name = 'lines_added'");
    $delta_cols = (defined($r) && $r) ? 1 : 0;
    if (!$delta_cols && $log) {
        $log->info("DB: backup_versions has no lines_added/lines_removed yet"
                   . " - run the fetchconfig-web 2.12 upgrade to enable line deltas");
    }
}

# The spool files of one repository, oldest-first. A name is .db-<pid>-<stamp>;
# sort by stamp then pid (timestamp is the order, pid the tiebreaker). The .tmp
# in-progress files are skipped.
sub _spool_files {
    my ($repo) = @_;
    my @out;
    if (opendir(my $dh, $repo)) {
        while (my $name = readdir $dh) {
            next unless $name =~ /^\.db-(\d+)-(\d{8}_\d{6})$/;
            push @out, { path => "$repo/$name", pid => $1, stamp => $2 };
        }
        closedir $dh;
    }
    sort { $a->{stamp} cmp $b->{stamp} || $a->{pid} <=> $b->{pid} } @out;
}

sub _stamp_epoch {
    my ($stamp) = @_;
    return undef unless defined($stamp)
        && $stamp =~ /^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$/;
    return eval { timelocal($6, $5, $4, $3, $2 - 1, $1) };
}

# --- spool line (de)serialization: tab-separated escaped key=value -----------

sub _serialize {
    my ($op) = @_;
    my @kv;
    foreach my $k (sort keys %$op) {
        my $v = $op->{$k};
        if (!defined($v)) { push @kv, "$k=~"; next; }
        $v =~ s/\\/\\\\/g; $v =~ s/\t/\\t/g; $v =~ s/\n/\\n/g;
        push @kv, "$k=$v";
    }
    join("\t", @kv);
}

sub _read_spool {
    my ($path) = @_;
    my @ops;
    my $fh;
    if (!open($fh, '<', $path)) {
        _warn("cannot read DB spool $path: $!");
        return (\@ops, 0);
    }
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my %op;
        foreach my $kv (split /\t/, $line) {
            my ($k, $v) = split /=/, $kv, 2;
            next unless defined $k;
            if (defined($v) && $v eq '~') { $op{$k} = undef; next; }
            $v = '' unless defined $v;
            # Single-pass inverse of _serialize: a backslash escape is decoded by
            # its FOLLOWING char, so "\\t" (escaped backslash + literal t, e.g. a
            # Windows path C:\temp) is not mistaken for an escaped tab.
            $v =~ s/\\(.)/ $1 eq 't' ? "\t" : $1 eq 'n' ? "\n" : $1 /ge;
            $op{$k} = $v;
        }
        push @ops, \%op;
    }
    close $fh;
    (\@ops, 1);
}

# --- status for the end-of-run mail / log ------------------------------------

# A single aggregated line, or undef when db: is not configured.
sub status_line {
    my ($class) = @_;
    return undef unless $db_seen;
    return 'DB history: no records this run.' unless %summary;

    if ($summary{ok}) {
        return "DB history: all $summary{delivered} record(s) written; outbox empty.";
    }
    my $oldest = defined($summary{oldest}) ? $summary{oldest} : 'unknown';
    return "DB history: INCOMPLETE - $summary{pending} run(s) still pending"
         . " (oldest $oldest); will retry next run.";
}

# Parts for the summary-mail status box (and its text twin): ($state, $label,
# $detail). $state is 'off' | 'ok' | 'incomplete' (picks grey/green/red);
# $label is the short pill word; $detail is the message without the "DB history:"
# prefix (the box title carries that). Always returns a value, so the box is
# shown even when db: is not configured (a grey "not configured" note).
sub mail_status {
    my ($class) = @_;
    return ('off', 'NOT CONFIGURED', 'History database export is not configured.')
        unless $db_seen;
    if (%summary && $summary{ok}) {
        return ('ok', 'WRITTEN',
                "All $summary{delivered} record(s) written; outbox empty.");
    }
    my $pending = (%summary && defined $summary{pending}) ? $summary{pending} : 0;
    my $oldest  = (%summary && defined $summary{oldest})  ? $summary{oldest}  : 'unknown';
    return ('incomplete', 'INCOMPLETE',
            "$pending run(s) still pending (oldest $oldest); will retry next run.");
}

# --- small helpers -----------------------------------------------------------

sub _trim { my $s = shift; return '' unless defined $s; $s =~ s/^\s+//; $s =~ s/\s+$//; $s }

sub _dequote {
    my $s = shift;
    return $s unless defined $s;
    $s =~ s/^"(.*)"$/$1/s;   # strip one surrounding double-quote pair
    $s;
}

sub _posint { my $v = shift; defined($v) && $v =~ /^\d+$/ && $v > 0 }

# Mask anything that looks like a db_pass value before logging a raw line.
sub _mask {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/(db_pass\s*=\s*)("[^"]*"|\S+)/$1****/ig;
    $s;
}

sub _err {
    my ($file, $num, $msg) = @_;
    if ($log) { $log->error("$msg at file=$file line=$num"); }
    else      { warn "fetchconfig::History: $msg at file=$file line=$num\n"; }
}

sub _warn {
    my ($msg) = @_;
    if ($log) { $log->error("fetchconfig::History: $msg"); }
    else      { warn "fetchconfig::History: $msg\n"; }
}

1;
