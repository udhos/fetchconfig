#!/usr/bin/perl
#
# 56-rename-device-id.t - fetchconfig --rename-device-id / --replay-db-change:
#   - fetchconfig::Lock: exclusive excludes exclusive (with a bounded timeout),
#     shared+shared is compatible, release frees it
#   - fetchconfig::History op=rename: _apply_op issues the three UPDATE SET dev_id
#     statements (idempotent by WHERE dev_id=old), returns 0 on a DB error;
#     queue_rename writes a spool the reader reads back; row_count_for_dev sums
#     the three tables and is undef when the DB is unreachable
#   - end-to-end (fetchconfig.pl as a child, when its model deps are loadable):
#     -T previews without writing; a real rename moves every dated leaf dir + the
#     files inside + <id>.status and rewrites only field 2 of the table line;
#     a re-run refuses (old gone); in-table / on-disk collisions and a bad new id
#     are refused with exit 2.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);

require_ok('fetchconfig::Lock');
require_ok('fetchconfig::History');

# --- Lock: acquire/release, shared compatibility, sidecar path ---------------
# NB: contention is tested CROSS-PROCESS below, not in-process: flock() is
# per-open-file-description on Linux (two handles in one process conflict) but
# emulated via per-process fcntl locks on AIX (a second request in the same
# process is granted). The feature only ever contends across processes (a run
# vs a rename), so that is what the test exercises.
{
    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;

    my ($l1, $s1) = fetchconfig::Lock->acquire($path, exclusive => 1, timeout => 0);
    is($s1, 'ok', 'exclusive lock acquired');
    fetchconfig::Lock->release($l1);

    my ($l3, $s3) = fetchconfig::Lock->acquire($path, exclusive => 1, timeout => 0);
    is($s3, 'ok', 'exclusive lock acquired again after release');
    fetchconfig::Lock->release($l3);

    my ($a, $sa) = fetchconfig::Lock->acquire($path, exclusive => 0, timeout => 0);
    my ($b, $sb) = fetchconfig::Lock->acquire($path, exclusive => 0, timeout => 0);
    is($sa, 'ok', 'first shared lock acquired');
    is($sb, 'ok', 'second shared lock acquired (shared is compatible)');
    fetchconfig::Lock->release($a);
    fetchconfig::Lock->release($b);

    is(fetchconfig::Lock->sidecar_path('/x/devtab'), '/x/devtab.lock',
       'sidecar path is <table>.lock');
    unlink "$path.lock";
}

# --- Lock contention is cross-process ----------------------------------------
SKIP: {
    skip "fork not available", 1 if $^O eq 'MSWin32';
    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;

    my ($held, $hs) = fetchconfig::Lock->acquire($path, exclusive => 1, timeout => 0);
    # a child process must NOT be able to take the exclusive lock the parent holds
    my $pid = fork();
    if (defined $pid && $pid == 0) {
        my ($cl, $cs) = fetchconfig::Lock->acquire($path, exclusive => 1, timeout => 1);
        exit($cs eq 'timeout' ? 0 : 1);
    }
    waitpid($pid, 0) if defined $pid;
    is($? >> 8, 0, 'a separate process cannot take the exclusive lock while it is held');

    fetchconfig::Lock->release($held);
    unlink "$path.lock";
}

# --- op=rename via _apply_op (mock dbh) --------------------------------------
{
    my $dbh = MockDbh->new;
    my $ok = fetchconfig::History::_apply_op($dbh,
        { op => 'rename', old_dev_id => 'sw1', new_dev_id => 'core-sw1' });
    is($ok, 1, 'op=rename applied');
    my @u = grep { $_->{sql} =~ /UPDATE\s+(\S+)\s+SET dev_id/ } @{ $dbh->{calls} };
    is(scalar(@u), 3, 'three UPDATE SET dev_id statements issued');
    my %tbl = map { ($_->{sql} =~ /UPDATE\s+(\S+)\s+SET/)[0] => 1 } @u;
    ok($tbl{backup_current} && $tbl{backup_runs} && $tbl{backup_versions},
       'all three history tables updated');
    is($u[0]{bind}[0], 'core-sw1', 'binds new id first');
    is($u[0]{bind}[1], 'sw1',      'binds old id in the WHERE');

    # a DB error on any table -> op fails (0), so the drain rolls back/leaves it
    my $bad = MockDbh->new(fail => 1);
    is(fetchconfig::History::_apply_op($bad,
        { op => 'rename', old_dev_id => 'a', new_dev_id => 'b' }), 0,
       'op=rename returns 0 when an UPDATE errors');
}

# --- queue_rename writes a spool the reader reads back -----------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $LOG  = FakeLog->new;
    ok(fetchconfig::History->queue_rename($LOG, $repo, 'sw1', 'core-sw1'),
       'queue_rename wrote the outbox spool');
    my ($spool) = grep { /\.db-/ } glob("$repo/.db-*");
    ok(defined $spool, 'a .db-* spool file exists');
    my ($ops, $read_ok) = fetchconfig::History::_read_spool($spool);
    ok($read_ok, 'spool is readable');
    is(scalar(@$ops), 1, 'one op in the spool');
    is($ops->[0]{op},          'rename',   'op kind is rename');
    is($ops->[0]{old_dev_id},  'sw1',      'old id preserved');
    is($ops->[0]{new_dev_id},  'core-sw1', 'new id preserved');
}

# --- row_count_for_dev (mock DBI) -------------------------------------------
our $MOCK;
$INC{'DBI.pm'} = 1;
{ package DBI; our $errstr = ''; sub connect { $MOCK } }
{
    my $LOG = FakeLog->new;
    fetchconfig::History->parse_db_line('t', 1, 'db:',
        'db_inst=fc,db_user=u,db_host=localhost', $LOG);

    $MOCK = MockDbh->new(counts => { backup_current => 1, backup_runs => 4, backup_versions => 2 });
    is(fetchconfig::History->row_count_for_dev($LOG, 'newid'), 7,
       'row_count_for_dev sums the three tables');

    $MOCK = undef;    # DBI->connect returns undef -> unreachable
    ok(!defined(fetchconfig::History->row_count_for_dev($LOG, 'newid')),
       'row_count_for_dev is undef when the DB is unreachable');
}

# --- end-to-end via fetchconfig.pl (only when the model deps are loadable) ---
SKIP: {
    my $have = do {
        my $v = `$^X @{[ map { "-I$_" } @INC ]} fetchconfig.pl -v 2>/dev/null`;
        ($? == 0 && $v =~ /\d+\.\d+/) ? 1 : 0;
    };
    skip "fetchconfig.pl model deps not loadable in this environment", 14 unless $have;

    require File::Spec;
    my $run = sub {
        my (@args) = @_;
        open(my $olderr, '>&', \*STDERR);
        open(STDERR, '>', File::Spec->devnull);
        my $rc = system($^X, (map { "-I$_" } @INC), 'fetchconfig.pl', @args);
        open(STDERR, '>&', $olderr);
        return $rc >> 8;
    };

    my $w    = tempdir(CLEANUP => 1);
    my $repo = "$w/repo";
    my $mk = sub {
        system("rm", "-rf", $repo);
        mkdir $repo;
        for my $p ("202601/20260115", "202602/20260203") {
            system("mkdir", "-p", "$repo/$p/sw1");
        }
        _spit("$repo/202601/20260115/sw1/sw1.run.20260115.120000", "v1\n");
        _spit("$repo/202601/20260115/sw1/sw1.run.20260115.130000", "v2\n");
        _spit("$repo/202602/20260203/sw1/sw1.run.20260203.090000", "v3\n");
        _spit("$repo/sw1.status", "state=success\n");
        _spit("$w/table",
            "# t\ncisco-ios  sw1  10.0.0.1  user=u,pass=p,enable=p,repository=$repo,keep=10\n"
          . "cisco-ios  sw2  10.0.0.2  user=u,pass=p,enable=p,repository=$repo,keep=10\n");
    };

    # -T previews, writes nothing
    $mk->();
    is($run->("-devices=$w/table", "--rename-device-id", "--old", "sw1", "--new", "core1", "-T"),
       0, 'dry-run exits 0');
    ok(-d "$repo/202601/20260115/sw1", 'dry-run left the old leaf dir');
    ok(_slurp("$w/table") =~ /\bsw1\b/, 'dry-run left the table unchanged');

    # real rename -- give the table a distinctive mode first, so we can prove the
    # atomic rewrite preserves owner (uid) and permissions (fetchconfig-web edits it).
    chmod 0664, "$w/table";
    my @before = stat("$w/table");
    is($run->("-devices=$w/table", "--rename-device-id", "--old", "sw1", "--new", "core1"),
       0, 'rename exits 0');
    my @after = stat("$w/table");
    is($after[4], $before[4], 'device-table owner (uid) preserved across the rewrite');
    is($after[2] & 07777, 0664, 'device-table mode preserved across the rewrite');
    ok(-f "$repo/202601/20260115/core1/core1.run.20260115.120000", 'file renamed in leaf 1');
    ok(-f "$repo/202602/20260203/core1/core1.run.20260203.090000", 'file renamed in leaf 2');
    ok(-f "$repo/core1.status", '.status renamed');
    ok(!-e "$repo/202601/20260115/sw1", 'old leaf dir gone');
    my $tbl = _slurp("$w/table");
    ok($tbl =~ /^cisco-ios\s+core1\s+10\.0\.0\.1\s+user=u,/m, 'table line 1 rewritten, rest preserved');
    ok($tbl =~ /^cisco-ios\s+sw2\s/m, 'the other device line is untouched');

    # re-run refuses (old gone)
    isnt($run->("-devices=$w/table", "--rename-device-id", "--old", "sw1", "--new", "core1"),
         0, 're-run refuses: old id no longer present');

    # bad new id refused
    is($run->("-devices=$w/table", "--rename-device-id", "--old", "sw2", "--new", "bad/id"),
       2, 'invalid new id refused with exit 2');
}

done_testing();

sub _spit { my ($p, $c) = @_; open(my $f, '>', $p) or die "$p: $!"; print $f $c; close $f; }
sub _slurp { my ($p) = @_; open(my $f, '<', $p) or return ''; local $/; my $c = <$f>; close $f; $c; }

# --- fakes -------------------------------------------------------------------
{
    package FakeLog;
    sub new   { bless { msgs => [] }, shift }
    sub info  { push @{ $_[0]{msgs} }, $_[1] }
    sub error { push @{ $_[0]{msgs} }, $_[1] }
    sub debug { }
}
{
    package MockSth;
    sub new { my ($c, $p, $sql) = @_; bless { p => $p, sql => $sql }, $c }
    sub execute {
        my ($s, @bind) = @_;
        push @{ $s->{p}{calls} }, { sql => $s->{sql}, bind => [@bind] };
        return undef if $s->{p}{fail} && $s->{sql} =~ /UPDATE/;
        return $s->{sql} =~ /^\s*SELECT/i ? "0E0" : 1;
    }
    sub fetchrow_arrayref {
        my $s = shift;
        return [1] if $s->{sql} =~ /information_schema/;   # probe_delta_cols
        undef;
    }
    sub finish { 1 }

    package MockDbh;
    sub new { my ($c, %o) = @_; bless { calls => [], %o }, $c }
    sub prepare { my ($s, $sql) = @_; MockSth->new($s, $sql) }
    sub selectrow_array {
        my ($s, $sql, $attr, @bind) = @_;
        if ($sql =~ /COUNT\(\*\)\s+FROM\s+(\S+)/) {
            return $s->{counts}{$1};
        }
        return;
    }
    sub commit     { 1 }
    sub rollback   { 1 }
    sub disconnect { 1 }
}
