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

my $DEFAULT_PORT          = 5432;
my $DEFAULT_CONNECT_TMO   = 5;
my $DEFAULT_MAX_OUTBOX_D  = 90;
my $DEFAULT_SSLMODE       = 'disable';   # local DB on the same box; no TLS by default

# End-of-run log section header, same 92-char width as Mailer's "-----[email]-----".
my $SECTION_DIVIDER = '-----[DB writer]----------------------------------------------------------------------------';

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
        if (defined($r->{path}) && defined($r->{file_timestamp}) && defined($r->{sha1})) {
            push @{ $by_repo{$repo} }, {
                op => 'version', dev_id => $r->{dev_id},
                file_timestamp => $r->{file_timestamp}, path => $r->{path},
                size_bytes => $size, sha1 => $r->{sha1},
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
        return;
    }
    else {
        for my $op (@$ops) {
            print $fh _serialize($op), "\n";
        }
        if (!close($fh)) {
            _warn("cannot close DB spool $tmp: $!");
            unlink $tmp;
            return;
        }
    }
    if (!rename($tmp, $final)) {
        _warn("cannot finalize DB spool $final: $!");
        unlink $tmp;
    }
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
    $dbh;
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
