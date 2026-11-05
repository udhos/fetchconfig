# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2007 Everton da Silva Marques
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
# fetchconfig::Rename - rename a device id everywhere it is used.
#
# --rename-device-id --old X --new Y [--replay-db-change] [-T]
#
# Renames one device's id in the device table, in the on-disk backup tree
# (every dated leaf directory and the backup files inside, plus the repo-root
# <id>.status / <id>.debug), and - if a db: line is configured - in the
# backup-history database (carried on the existing statistics outbox as an
# op=rename record that the drain applies).
#
# Ordering & safety (see the change request):
#   1. validate the new id (pre-lock);
#   2. take an EXCLUSIVE lock on the device-table file (sidecar);
#   3. re-check under the lock: old present & new absent in the table, no
#      on-disk artifacts for new, and (if the DB is reachable) no DB rows for
#      new - unless a journal for this exact old->new says we are resuming;
#   4. write a journal file in the repository;
#   5. sweep the on-disk artifacts old->new (idempotent);
#   6. atomically rewrite the one device-table line (field 2 only);
#   7. queue op=rename into the repository outbox;
#   8. remove the journal; release the lock;
#   9. drain the outbox (applies the DB change now, or leaves it queued if the
#      DB is down); report; exit 0 (done) / 1 (DB queued) / 2 (refusal).
#
# --replay-db-change (standalone, replay_db below) just drains the outboxes of
# every loaded device's repository: the catch-up after a DB outage.
#

package fetchconfig::Rename;

use strict;
use warnings;

use fetchconfig::Lock;
use fetchconfig::History;

# A case-only rename (sw1 -> SW1) on a case-insensitive filesystem (Windows)
# needs a temp-name two-step; a direct rename() is fine on Linux/AIX.
sub _case_insensitive_fs { return $^O =~ /^(?:MSWin32|cygwin|msys)$/i ? 1 : 0; }

sub _rename_path {
    my ($from, $to) = @_;
    return 1 if !-e $from && -e $to;    # already done (idempotent resume)
    if (lc($from) eq lc($to) && $from ne $to && _case_insensitive_fs()) {
        my $tmp = "$from.rename-tmp.$$";
        rename($from, $tmp) or return 0;
        return rename($tmp, $to) ? 1 : 0;
    }
    return rename($from, $to) ? 1 : 0;
}

# Existing <repo>/YYYYMM/YYYYMMDD/<id> leaf directories, in order.
sub _leaf_dirs {
    my ($repo, $id) = @_;
    my @leaves;
    my $rdh;
    opendir($rdh, $repo) or return @leaves;
    my @months = sort grep { /^\d{6}$/ && -d "$repo/$_" } readdir($rdh);
    closedir($rdh);
    for my $m (@months) {
        my $mp = "$repo/$m";
        my $mdh;
        opendir($mdh, $mp) or next;
        my @days = sort grep { /^\d{8}$/ && -d "$mp/$_" } readdir($mdh);
        closedir($mdh);
        for my $d (@days) {
            my $leaf = "$mp/$d/$id";
            push @leaves, $leaf if -d $leaf;
        }
    }
    return @leaves;
}

# Any on-disk artifact of $id: a leaf dir, a .status or a .debug. Used as the
# collision check for the new id (the "orphan scan scoped to new").
sub _has_artifacts {
    my ($repo, $id) = @_;
    return 1 if _leaf_dirs($repo, $id);
    return 1 if -e "$repo/$id.status";
    return 1 if -e "$repo/$id.debug";
    return 0;
}

# Rename every on-disk artifact of $old to $new. Idempotent. Returns 1 on
# success, 0 on a filesystem error (recorded in $did).
sub _sweep {
    my ($log, $old, $new, $repo, $dry, $did) = @_;
    my ($dirs, $files) = (0, 0);

    for my $leaf (_leaf_dirs($repo, $old)) {
        my $dh;
        if (opendir($dh, $leaf)) {
            my @fs = grep { /^\Q$old\E\.run\./ } readdir($dh);
            closedir($dh);
            for my $f (@fs) {
                (my $nf = $f) =~ s/^\Q$old\E\.run\./$new.run./;
                if ($dry) { $log->info("would rename file: $leaf/$f -> $nf"); $files++; next; }
                unless (_rename_path("$leaf/$f", "$leaf/$nf")) {
                    $log->error("--rename-device-id: rename failed: $leaf/$f -> $nf: $!");
                    $did->{error} = 1; return 0;
                }
                $files++;
            }
        }
        (my $target = $leaf) =~ s{/\Q$old\E$}{/$new};
        if ($dry) { $log->info("would rename dir: $leaf -> $target"); $dirs++; next; }
        unless (_rename_path($leaf, $target)) {
            $log->error("--rename-device-id: rename failed: $leaf -> $target: $!");
            $did->{error} = 1; return 0;
        }
        $dirs++;
    }

    for my $suf (qw(status debug)) {
        my $from = "$repo/$old.$suf";
        my $to   = "$repo/$new.$suf";
        next unless -e $from;
        if ($dry) { $log->info("would rename: $from -> $to"); $did->{$suf} = 1; next; }
        unless (_rename_path($from, $to)) {
            $log->error("--rename-device-id: rename failed: $from -> $to: $!");
            $did->{error} = 1; return 0;
        }
        $did->{$suf} = 1;
    }

    $did->{dirs} = $dirs;
    $did->{files} = $files;
    return 1;
}

# Read the device table; return (\@lines, $old_idx, $new_present). $old_idx is
# the index of the data line whose id (field 2) is $old, or undef. Keyword lines
# (directory:/default:/email:/db:), comments and blanks are ignored.
sub _scan_table {
    my ($file, $old, $new) = @_;
    my $fh;
    open($fh, '<', $file) or return (undef);
    my @lines = <$fh>;
    close $fh;
    my ($old_idx, $new_present);
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        next if $l =~ /^\s*(#|$)/;
        next if $l =~ /^\s*(?:directory|default|email|db)\s*:/i;
        next unless $l =~ /^\s*(\S+)\s+(\S+)\s+\S+/;   # model  id  host ...
        my $id = $2;
        $old_idx = $i if $id eq $old;
        $new_present = 1 if $id eq $new;
    }
    return (\@lines, $old_idx, $new_present);
}

# Rewrite field 2 (the id) of $lines->[$idx] from $old to $new, preserving the
# model, host, options, inline comment and spacing, and write the file back
# atomically (temp + rename). Returns 1 on success, 0 on error.
sub _write_table {
    my ($log, $file, $lines, $idx, $old, $new) = @_;
    my $l = $lines->[$idx];
    unless ($l =~ s/^(\s*\S+\s+)\Q$old\E(\s)/$1$new$2/) {
        $log->error("--rename-device-id: could not locate the id to rewrite on the device line");
        return 0;
    }
    $lines->[$idx] = $l;

    # The atomic replace below (temp + rename) creates a NEW inode owned by
    # whoever runs the rename (root, under cron) with the default umask mode.
    # Capture the original owner/group/mode first and restore them on the temp
    # before the swap, so the device table keeps its ownership and permissions --
    # otherwise fetchconfig-web (running as its own user) could no longer edit it.
    my @st = stat($file);

    my $tmp = "$file.rename.$$";
    my $out;
    unless (open($out, '>', $tmp)) {
        $log->error("--rename-device-id: cannot write $tmp: $!");
        return 0;
    }
    print $out @$lines;
    unless (close($out)) {
        $log->error("--rename-device-id: cannot close $tmp: $!");
        unlink $tmp; return 0;
    }

    if (@st) {
        my ($mode, $uid, $gid) = ($st[2] & 07777, $st[4], $st[5]);
        # chown first (it can strip set-id bits on some systems), then chmod.
        unless (chown($uid, $gid, $tmp)) {
            $log->error("--rename-device-id: could not restore owner $uid:$gid on $file ($!);"
                . " fetchconfig-web may be unable to edit it -- fix with: chown $uid:$gid $file");
        }
        chmod($mode, $tmp);
    }

    unless (rename($tmp, $file)) {
        $log->error("--rename-device-id: cannot replace $file: $!");
        unlink $tmp; return 0;
    }
    return 1;
}

#
# The rename driver. Returns a process exit code: 0 done, 1 the DB change was
# left queued (run --replay-db-change later), 2 a validation/collision refusal
# (nothing changed).
#
sub run {
    my ($class, %a) = @_;
    my $log = $a{log};
    my $old = $a{old};
    my $new = $a{new};
    my $dry = $a{dry_run} ? 1 : 0;

    # 1. validate (pre-lock)
    if (!defined($old) || $old eq '' || !defined($new) || $new eq '') {
        $log->error("--rename-device-id requires --old and --new");
        return 2;
    }
    if ($old eq $new) {
        $log->error("--rename-device-id: --old and --new are the same ('$old')");
        return 2;
    }
    unless (fetchconfig::model::Detector->valid_dev_id($new)) {
        $log->error("--rename-device-id: invalid --new id '$new'"
            . " (allowed characters: letters, digits, '_', '.', '-'; not all dots)");
        return 2;
    }

    # 2. locate old in the loaded table
    my $info = fetchconfig::model::Detector->device_info($old);
    unless (defined $info) {
        $log->error("--rename-device-id: device '$old' is not in the loaded device table");
        return 2;
    }
    my $file = $info->{file};
    if (!defined($file) || $file eq '<cmdline>') {
        $log->error("--rename-device-id: device '$old' comes from -line=, not a -devices= file; cannot rewrite it");
        return 2;
    }
    if (defined(fetchconfig::model::Detector->device_info($new))) {
        $log->error("--rename-device-id: new id '$new' already exists in the device table");
        return 2;
    }
    my $mod  = $info->{model};
    my $tab  = $info->{dev_opt_tab};
    my $repo = $mod->dev_option($tab, "repository");
    unless (defined($repo) && length($repo)) {
        $log->error("--rename-device-id: device '$old' has no repository configured");
        return 2;
    }

    my $journal = "$repo/.rename-$old-to-$new.inprogress";
    my $resuming = (-e $journal) ? 1 : 0;
    $log->info("--rename-device-id: resuming an interrupted rename (journal present)") if $resuming && $log;

    # 3. exclusive lock on the device-table file
    my ($lock, $st) = fetchconfig::Lock->acquire($file, exclusive => 1, timeout => 5);
    if ($st eq 'timeout') {
        $log->error("--rename-device-id: could not lock $file within 5s"
            . " (a run or another rename holds it) - try again");
        return 2;
    }
    if ($st eq 'nolock') {
        $log->error("--rename-device-id: cannot create the lock "
            . fetchconfig::Lock->sidecar_path($file) . " - refusing to rename without a lock");
        return 2;
    }

    my %did;
    my $locked_rc = eval {
        $class->_locked_phase($log, $old, $new, $file, $repo, $journal, $resuming, $dry, \%did);
    };
    my $perr = $@;
    fetchconfig::Lock->release($lock);

    if (!defined($locked_rc)) {
        $log->error("--rename-device-id: aborted: " . ($perr || 'unknown error'));
        return 1;   # may be partially done; the journal (if written) allows a re-run
    }
    return $locked_rc if $locked_rc != 0;    # refusal: nothing changed

    # 9. DB: drain the outbox (applies op=rename now, or leaves it queued).
    my $db_pending = 0;
    if (fetchconfig::History->configured) {
        if ($dry) {
            $log->info("would apply DB rename: UPDATE {backup_current,backup_runs,backup_versions}"
                . " SET dev_id='$new' WHERE dev_id='$old'");
            fetchconfig::History->replay($log, [$repo], 1);
        }
        else {
            $db_pending = fetchconfig::History->replay($log, [$repo], 0);
            $did{db_applied} = $db_pending ? 0 : 1;
        }
    }

    $class->_report($log, $old, $new, $file, $repo, $dry, \%did, $db_pending);

    return 0 if $dry;
    return $db_pending ? 1 : 0;
}

# Steps 3-8 under the exclusive lock. Returns 0 to proceed (done, caller drains),
# 2 to refuse (nothing changed), or dies on an unexpected I/O failure.
sub _locked_phase {
    my ($class, $log, $old, $new, $file, $repo, $journal, $resuming, $dry, $did) = @_;

    # re-check the table under the lock (TOCTOU)
    my ($lines, $old_idx, $new_present) = _scan_table($file, $old, $new);
    die "cannot read device table $file: $!\n" unless defined $lines;

    unless ($resuming) {
        if (!defined $old_idx) {
            $log->error("--rename-device-id: '$old' is no longer in $file (changed under us) - aborting");
            return 2;
        }
        if ($new_present) {
            $log->error("--rename-device-id: '$new' already appears in $file - aborting");
            return 2;
        }
        # on-disk collision: new must have no artifacts
        if (_has_artifacts($repo, $new)) {
            $log->error("--rename-device-id: on-disk backups/status already exist for '$new'"
                . " in $repo - aborting (clean them up or pick another id)");
            return 2;
        }
        # DB collision: new must have no rows (only when the DB is reachable)
        if (fetchconfig::History->configured) {
            my $cnt = fetchconfig::History->row_count_for_dev($log, $new);
            if (defined($cnt) && $cnt > 0) {
                $log->error("--rename-device-id: the history DB already has $cnt row(s) for '$new'"
                    . " - aborting (a ghost from a deleted device; clean it up first)");
                return 2;
            }
            $log->info("--rename-device-id: DB unreachable - skipping the new-id pre-check"
                . " (the apply-time transaction is the backstop)") unless defined($cnt);
        }
    }

    # dry run: report the plan (sweep counts + table line) and stop, no writes.
    if ($dry) {
        _sweep($log, $old, $new, $repo, 1, $did);
        if (defined $old_idx) {
            $log->info("would rewrite device-table line " . ($old_idx + 1) . " in $file: id '$old' -> '$new'");
        }
        return 0;
    }

    # 4. journal
    unless ($resuming) {
        if (open(my $jh, '>', $journal)) {
            print $jh "old=$old\nnew=$new\nstarted=" . scalar(localtime) . "\n";
            close $jh;
        } else {
            die "cannot write journal $journal: $!\n";
        }
    }

    # 5. file sweep (idempotent)
    unless (_sweep($log, $old, $new, $repo, 0, $did)) {
        die "on-disk rename failed (journal kept at $journal for a re-run)\n";
    }

    # 6. atomic table edit (skip if already done on a resume)
    if (defined $old_idx) {
        unless (_write_table($log, $file, $lines, $old_idx, $old, $new)) {
            die "device-table rewrite failed (journal kept at $journal)\n";
        }
        $did->{table} = 1;
    }
    else {
        $did->{table} = 0;   # resume: table line was already updated
    }

    # 7. queue the DB rename into the repository outbox
    if (fetchconfig::History->configured) {
        unless (fetchconfig::History->queue_rename($log, $repo, $old, $new)) {
            $log->error("--rename-device-id: could not queue the DB rename into the outbox"
                . " - the file/table rename is done; re-run to retry the DB part");
        } else {
            $did->{db_queued} = 1;
        }
    }

    # 8. remove the journal (the mutation is committed)
    unlink $journal;

    return 0;
}

sub _report {
    my ($class, $log, $old, $new, $file, $repo, $dry, $did, $db_pending) = @_;

    my @steps;
    my $pfx = $dry ? "[preview] " : "";
    push @steps, "device id: '$old' -> '$new'";
    push @steps, "device table: $file" . ($dry ? " (would update)" : (($did->{table} // 1) ? " (line updated)" : " (already updated)"));
    push @steps, "backup directories renamed: " . ($did->{dirs} // 0);
    push @steps, "backup files renamed: "       . ($did->{files} // 0);
    push @steps, ".status renamed" if $did->{status};
    push @steps, ".debug renamed"  if $did->{debug};
    if (fetchconfig::History->configured) {
        if ($dry) {
            push @steps, "history DB: would UPDATE dev_id across backup_current/backup_runs/backup_versions";
        } elsif ($db_pending) {
            push @steps, "history DB: change QUEUED in the outbox (DB unreachable) -"
                . " run 'fetchconfig.pl --replay-db-change -devices=...' when the DB is back";
        } else {
            push @steps, "history DB: updated";
        }
    }

    $log->info("${pfx}rename summary:") if $log;
    $log->info("  - $_") for @steps;

    return if $dry;

    my $to = fetchconfig::Mailer->configured_recipient;
    return unless defined $to;

    my $subject = "fetchconfig: device '$old' renamed to '$new'";
    my $text = "fetchconfig device-id rename\n\n" . join("\n", map { " - $_" } @steps) . "\n";
    # Same visual frame as the backup summary mail (header bar + logo + footer).
    my $html = fetchconfig::Mailer->build_notice_html("fetchconfig device-id rename", \@steps);
    eval { fetchconfig::Mailer->send_mail($to, $subject, $html, $text); 1 }
        or $log->error("--rename-device-id: sending the report mail failed: $@");
}

#
# --replay-db-change: drain the outboxes of every loaded device's repository.
# Returns 0 if nothing is left pending, 1 if some ops could not be applied
# (DB unreachable), 2 on a usage problem.
#
sub replay_db {
    my ($class, %a) = @_;
    my $log = $a{log};
    my $dry = $a{dry_run} ? 1 : 0;

    unless (fetchconfig::History->configured) {
        $log->error("--replay-db-change requires a db: line in the device table");
        return 2;
    }

    my %repos;
    for my $id (fetchconfig::model::Detector->device_ids) {
        my $info = fetchconfig::model::Detector->device_info($id) or next;
        my $r = $info->{model}->dev_option($info->{dev_opt_tab}, "repository");
        $repos{$r} = 1 if defined($r) && length($r);
    }
    my @repos = sort keys %repos;
    unless (@repos) {
        $log->error("--replay-db-change: no repositories found among the loaded devices");
        return 2;
    }

    return fetchconfig::History->replay($log, \@repos, $dry);
}

1;
