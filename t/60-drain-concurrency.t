#!/usr/bin/perl
#
# 60-drain-concurrency.t - the concurrency- and crash-safe DB outbox drain
# (fetchconfig::History). Two fetchconfig runs may share a repository with no
# lock, so each spool file is claimed by an atomic rename before it is read, a
# failed drain un-claims it, and a file orphaned by a crashed drainer is
# recovered on a later run. This covers:
#   - _claim: wins a file by renaming it to <path>.draining.<pid>; reports 'lost'
#     when the file is already gone (another drainer took it)
#   - _pid_alive: self alive, a reaped child dead, pid 1 alive
#   - _reclaim_orphans: dead-owner orphan re-queued; live-owner orphan left;
#     over-retention orphan dropped; orphan whose base already exists dropped
#   - _drain end to end (mock DBI): happy path leaves the outbox empty; a commit
#     failure un-claims the file back to its base name (never a stuck .draining);
#     an orphan from a crashed drainer is reclaimed and delivered
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

require_ok('fetchconfig::History');

my $H = 'fetchconfig::History';

# local-wall-clock stamp helpers (same format _write_spool uses)
sub _stamp {
    my ($t) = @_; $t = time unless defined $t;
    my @l = localtime($t);
    sprintf("%04d%02d%02d_%02d%02d%02d",
            $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1], $l[0]);
}
sub _dbfiles   { my @f = sort glob("$_[0]/.db-*"); @f }               # all spool files
sub _bases     { my @f = grep { !/\.draining\./ } _dbfiles($_[0]); @f } # claimable spools
sub _drainings { my @f = grep {  /\.draining\./ } _dbfiles($_[0]); @f } # in-progress spools
sub _touch { my ($p, $c) = @_; open(my $f, '>', $p) or die "$p: $!"; print $f ($c // ''); close $f; }
# Run $code with History's _warn() (which warns to STDERR when no logger is set)
# captured, so an expected warning is asserted instead of polluting "make test".
sub _warns (&) { my ($code) = @_; my @w; local $SIG{__WARN__} = sub { push @w, $_[0] }; $code->(); @w }

# --- _claim ------------------------------------------------------------------
{
    my $repo = tempdir(CLEANUP => 1);
    my $path = "$repo/.db-12345-" . _stamp();
    _touch($path, "x\n");

    my ($work, $why, $err) = fetchconfig::History::_claim($path);
    is($why, 'ok', '_claim wins an existing file');
    is($work, "$path.draining.$$", '_claim renames to <path>.draining.<pid>');
    ok(-e $work && !-e $path, 'claimed file carries the in-progress name only');

    my ($w2, $why2) = fetchconfig::History::_claim($path);
    is($why2, 'lost', '_claim on an already-taken file reports lost');
    ok(!defined $w2, 'no work path when the claim is lost');
}

# --- _pid_alive --------------------------------------------------------------
{
    is(fetchconfig::History::_pid_alive($$), 1, '_pid_alive: self is alive');
    is(fetchconfig::History::_pid_alive(1),  1, '_pid_alive: pid 1 is alive (running or EPERM)');
    is(fetchconfig::History::_pid_alive('x'), 1, '_pid_alive: a garbled pid is treated as alive (never stolen)');

  SKIP: {
        skip "fork not available", 1 if $^O eq 'MSWin32';
        my $pid = fork();
        if (defined $pid && $pid == 0) { exit 0; }   # child exits immediately
        skip "fork failed", 1 unless defined $pid;
        waitpid($pid, 0);                            # reap -> pid now refers to nothing
        is(fetchconfig::History::_pid_alive($pid), 0, '_pid_alive: a reaped child is dead');
    }
}

# --- _reclaim_orphans --------------------------------------------------------
# A dead owner pid for the orphan-name tests (reaped child); fall back to a
# high, almost-certainly-unused pid where fork is unavailable.
my $DEAD = do {
    my $p;
    unless ($^O eq 'MSWin32') {
        $p = fork();
        if (defined $p && $p == 0) { exit 0; }
        waitpid($p, 0) if defined $p;
    }
    (defined $p && !fetchconfig::History::_pid_alive($p)) ? $p : 2_000_000_000;
};
my $MAXAGE = time - 90 * 86400;   # retention window used by the drop branch

# dead-owner orphan -> renamed back to its claimable base
{
    my $repo = tempdir(CLEANUP => 1);
    my $base = "$repo/.db-99999-" . _stamp();
    _touch("$base.draining.$DEAD", "op=run\tdev_id=d1\n");
    fetchconfig::History::_reclaim_orphans($repo, $MAXAGE);
    ok(-e $base, 'dead-owner orphan is reclaimed to the base name');
    is(scalar(_drainings($repo)), 0, 'no .draining file left after reclaim');
}

# live-owner orphan -> left in place (a drainer is still working it)
{
    my $repo = tempdir(CLEANUP => 1);
    my $orphan = "$repo/.db-99999-" . _stamp() . ".draining.$$";
    _touch($orphan, "op=run\tdev_id=d1\n");
    fetchconfig::History::_reclaim_orphans($repo, $MAXAGE);
    ok(-e $orphan, 'live-owner orphan is left untouched');
    is(scalar(_bases($repo)), 0, 'live-owner orphan is not re-queued');
}

# over-retention orphan -> dropped (same policy as a stale base spool)
{
    my $repo = tempdir(CLEANUP => 1);
    fetchconfig::History->parse_db_line('t', 1, 'db:',
        'db_inst=fc,db_user=u,db_host=localhost', undef);   # sets db_max_outbox_days for the warn text
    my $orphan = "$repo/.db-99999-20000101_000000.draining.$DEAD";   # year 2000 = ancient
    _touch($orphan, "op=run\tdev_id=d1\n");
    my @w = _warns { fetchconfig::History::_reclaim_orphans($repo, $MAXAGE) };
    ok(!-e $orphan, 'over-retention orphan is dropped');
    is(scalar(_dbfiles($repo)), 0, 'nothing re-queued from a dropped orphan');
    like("@w", qr/dropping stale in-progress DB spool/, 'warns about the dropped stale orphan');
}

# orphan whose base already exists (pid reuse, same second) -> orphan dropped
{
    my $repo = tempdir(CLEANUP => 1);
    my $stamp = _stamp();
    my $base = "$repo/.db-77777-$stamp";
    _touch($base, "op=run\tdev_id=fresh\n");
    _touch("$base.draining.$DEAD", "op=run\tdev_id=stale\n");
    fetchconfig::History::_reclaim_orphans($repo, $MAXAGE);
    ok(-e $base, 'the existing base spool is kept');
    is(scalar(_drainings($repo)), 0, 'the duplicate orphan is dropped');
}

# --- _drain end to end (mock DBI) --------------------------------------------
our $MOCK;
$INC{'DBI.pm'} = 1;
{ package DBI; our $errstr = ''; sub connect { $MOCK } }

my $RUNOP = sub {
    { op => 'run', dev_id => $_[0] // 'd1', run_end => 123, state => 'success',
      changed => 'f', duration_sec => 1, size_bytes => 10, fail_reason => undef,
      repository => $_[1] // '.' };
};

# happy path: the file is delivered and the outbox is left empty
{
    my $repo = tempdir(CLEANUP => 1);
    $MOCK = MockDbh->new(commit_ok => 1);
    ok(fetchconfig::History::_write_spool($repo, [ $RUNOP->('d1', $repo) ]),
       'wrote a spool file');
    is(scalar(_bases($repo)), 1, 'one claimable spool before draining');

    fetchconfig::History::_drain({ $repo => 1 });
    is(scalar(_dbfiles($repo)), 0, 'drain delivered the file: outbox empty');
    like($H->status_line, qr/outbox empty/, 'status line reports the outbox empty');
}

# commit failure: the file is un-claimed back to its base name (no stuck .draining)
{
    my $repo = tempdir(CLEANUP => 1);
    $MOCK = MockDbh->new(commit_ok => 0);
    fetchconfig::History::_write_spool($repo, [ $RUNOP->('d1', $repo) ]);

    my @w = _warns { fetchconfig::History::_drain({ $repo => 1 }) };
    is(scalar(_bases($repo)), 1, 'a failed drain leaves the file under its claimable name');
    is(scalar(_drainings($repo)), 0, 'a failed drain leaves no stuck .draining file');
    like($H->status_line, qr/pending/, 'status line reports the file pending');
    like("@w", qr/DB commit failed/, 'warns on the commit failure');
}

# crash recovery: an orphan left by a dead drainer is reclaimed and delivered
{
    my $repo = tempdir(CLEANUP => 1);
    $MOCK = MockDbh->new(commit_ok => 1);
    fetchconfig::History::_write_spool($repo, [ $RUNOP->('d1', $repo) ]);
    my ($base) = _bases($repo);
    rename($base, "$base.draining.$DEAD");          # simulate: claimed, then the drainer died
    is(scalar(_bases($repo)), 0, 'precondition: only an orphaned .draining file exists');

    fetchconfig::History::_drain({ $repo => 1 });
    is(scalar(_dbfiles($repo)), 0, 'the orphan is reclaimed and delivered: outbox empty');
    like($H->status_line, qr/outbox empty/, 'status line reports the outbox empty after recovery');
}

done_testing();

# --- a minimal DBI handle mock (commit_ok toggles commit success) ------------
{
    package MockSth;
    sub new { my ($c, $p, $sql) = @_; bless { p => $p, sql => $sql }, $c }
    sub execute {
        my ($s, @bind) = @_;
        push @{ $s->{p}{calls} }, { sql => $s->{sql}, bind => [@bind] };
        return $s->{sql} =~ /^\s*SELECT/i ? '0E0' : 1;
    }
    sub fetchrow_arrayref {
        my $s = shift;
        return [1] if $s->{sql} =~ /information_schema/;   # _probe_delta_cols -> cols present
        return undef;                                      # pg_class probe -> inventory off
    }
    sub finish { 1 }

    package MockDbh;
    sub new { my ($c, %o) = @_; bless { calls => [], commit_ok => 1, %o }, $c }
    sub prepare    { my ($s, $sql) = @_; MockSth->new($s, $sql) }
    sub commit     { $_[0]{commit_ok} }
    sub rollback   { 1 }
    sub disconnect { 1 }
    sub errstr     { '' }
}
