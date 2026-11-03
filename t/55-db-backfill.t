#!/usr/bin/perl
#
# 55-db-backfill.t - fetchconfig::History --db-backfill and the per-version line
# deltas (lines_added/lines_removed):
#   - _sha1_file reproduces exactly what a live save stores (same bytes hashed)
#   - _read_status parses <dev_id>.status and encodes run_end with the DB's
#     local-wall-clock-epoch convention
#   - _current_row from .status / the no-.status fallback
#   - Abstract::line_delta (dependency-free +added/-removed) and config_norm_lines
#     (ignore-aware line view)
#   - backfill() end to end against a query-aware mock DBI and a fake device layer:
#     insert version+run+current with deltas when the 2.12 columns exist; FILL the
#     delta on an existing NULL row; skip populated rows; -T preview writes nothing;
#     and the backward-compatible path when the columns are absent.
# No real DB is needed (DBI is stubbed) and no Net::Telnet (Abstract loads alone).
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);

require_ok('fetchconfig::model::Abstract');
require_ok('fetchconfig::History');
my $H = 'fetchconfig::History';
my $A = 'fetchconfig::model::Abstract';

# --- _sha1_file == the live-save hash ----------------------------------------
{
    my @lines = ('line one', 'router# show run', '', 'end');
    my ($fh, $p) = tempfile(UNLINK => 1);
    binmode $fh;
    print $fh map { "$_\n" } @lines;          # exactly how dump_config writes it
    close $fh;

    my $live = Digest::SHA->new(1);
    $live->add("$_\n") for @lines;            # exactly how the save path hashes it

    is(fetchconfig::History::_sha1_file($p), $live->hexdigest,
       '_sha1_file reproduces the live-save sha1');
    ok(!defined fetchconfig::History::_sha1_file("$p.nope"),
       '_sha1_file undef on unreadable file');
}

# --- _read_status ------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $sp  = "$dir/d.status";
    open(my $s, '>', $sp) or die;
    print $s "[d]\n",
             "backup_start_date=2026-01-01\n", "backup_start_time=11:59:57\n",
             "backup_end_date=2026-01-02\n",   "backup_end_time=03:04:05\n",
             "backup_duration_sec=8\n", "backup_state=success\n",
             "backup_changed=changed\n";
    close $s;

    my %st = fetchconfig::History::_read_status($sp);
    is($st{state},        'success', 'status state');
    is($st{changed},      'changed', 'status changed');
    is($st{duration_sec}, 8,         'status duration');
    is($st{run_end}, fetchconfig::model::Abstract::backup_epoch_from_parts(2026, 1, 2, 3, 4, 5),
       'run_end is the end date/time as a local-wall-clock epoch');

    my %none = fetchconfig::History::_read_status("$dir/missing.status");
    is_deeply(\%none, {}, 'missing status file -> empty');
}

# --- _current_row ------------------------------------------------------------
{
    my $repo  = tempdir(CLEANUP => 1);
    my $epoch = fetchconfig::model::Abstract::backup_epoch_from_parts(2026, 1, 2, 3, 4, 5);

    my $write_status = sub {
        my ($state, $changed) = @_;
        open(my $s, '>', "$repo/dev1.status") or die;
        print $s "[dev1]\nbackup_end_date=2026-01-02\nbackup_end_time=03:04:05\n",
                 "backup_duration_sec=8\nbackup_state=$state\nbackup_changed=$changed\n";
        close $s;
    };

    $write_status->('success', 'changed');
    my $c = fetchconfig::History::_current_row('dev1', $repo, 999, 4096);
    is($c->{run_end},        $epoch,  'success: run_end from .status');
    is($c->{state},          'success','success: state');
    is($c->{size_bytes},     4096,    'success: size = newest backup');
    is($c->{last_good_at},   $epoch,  'success: last_good_at = this run');
    is($c->{last_good_size}, 4096,    'success: last_good_size = newest backup');

    $write_status->('failed', 'unknown');
    $c = fetchconfig::History::_current_row('dev1', $repo, 999, 4096);
    is($c->{state},        'failed', 'failed: state');
    ok(!defined $c->{size_bytes},    'failed: no this-run size');
    is($c->{last_good_at}, 999,      'failed: last_good_at = newest backup timestamp');
    is($c->{last_good_size}, 4096,   'failed: last_good_size = newest backup');

    my $repo2 = tempdir(CLEANUP => 1);   # no .status
    $c = fetchconfig::History::_current_row('dev1', $repo2, 777, 100);
    is($c->{state},        'success', 'no .status: newest backup is a success by definition');
    is($c->{run_end},      777,       'no .status: run_end = newest backup');
    is($c->{last_good_at}, 777,       'no .status: last_good_at = newest backup');
    ok(!defined fetchconfig::History::_current_row('dev1', $repo2, undef, undef),
       'no .status and no backups -> nothing to record');
}

# --- Abstract::line_delta (dependency-free +added / -removed) -----------------
{
    my $ld = \&fetchconfig::model::Abstract::line_delta;
    is_deeply([$ld->(["a\n","b\n"],        ["a\n","b\n"])],            [0,0], 'identical -> 0/0');
    is_deeply([$ld->(["a\n","b\n"],        ["a\n","b\n","c\n"])],      [1,0], 'append -> +1');
    is_deeply([$ld->(["a\n","b\n","c\n"],  ["a\n","c\n"])],           [0,1], 'remove -> -1');
    is_deeply([$ld->(["a\n","x\n","c\n"],  ["a\n","y\n","c\n"])],     [1,1], 'changed line -> +1/-1');
    is_deeply([$ld->([],                   ["a\n","b\n"])],           [2,0], 'from empty -> +2');
    is_deeply([$ld->(["a\n","b\n"],        [])],                      [0,2], 'to empty -> -2');
    is_deeply([$ld->(["a\n","b\n","c\n"],  ["a\n","b\n","x\n","c\n"])],[1,0],'middle insert -> +1');
}

# --- Abstract::config_norm_lines (ignore-aware) ------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    open(my $f, '>', "$dir/c") or die;
    print $f "alpha\n!volatile 123\nbeta\n";
    close $f;

    my $m = bless {}, 'NormModel';           # ISA Abstract, settable ignore
    local $NormModel::IGNORE;                # undef -> raw
    is_deeply($m->config_norm_lines($dir, 'c'),
              ["alpha\n", "!volatile 123\n", "beta\n"], 'raw keeps every line');
    $NormModel::IGNORE = qr/^!volatile/;
    is_deeply($m->config_norm_lines($dir, 'c'),
              ["alpha\n", "beta\n"], 'ignore_re drops the matching line');
}

# --- backfill() end to end (query-aware mock DBI + fake device layer) ---------
# Stub DBI so "require DBI" and DBI->connect succeed without a real driver.
our $MOCK;
$INC{'DBI.pm'} = 1;
{ package DBI; our $errstr = ''; sub connect { $MOCK } }

{
    my $repo = tempdir(CLEANUP => 1);
    # Two versions, file2 one line longer -> live-style delta +1 / -0.
    open(my $b1, '>', "$repo/dev1.run.20260101.120000") or die;
    print $b1 "hostname r1\nend\n"; close $b1;
    open(my $b2, '>', "$repo/dev1.run.20260102.120000") or die;
    print $b2 "hostname r1\nlogging on\nend\n"; close $b2;
    open(my $s, '>', "$repo/dev1.status") or die;
    print $s "[dev1]\nbackup_end_date=2026-01-02\nbackup_end_time=12:00:03\n",
             "backup_duration_sec=3\nbackup_state=success\nbackup_changed=changed\n";
    close $s;

    { no warnings 'once';
      $fetchconfig::model::Detector::INFO{dev1} =
          { model => FakeModel->new($repo), dev_opt_tab => {} };
    }

    my $LOG = FakeLog->new;
    $H->parse_db_line('t', 1, 'db:', 'db_inst=fc,db_user=u,db_host=localhost', $LOG);

    my $match = sub { my $re = shift; grep { $_->{sql} =~ $re } @{$MOCK->{calls}} };

    # A) delta columns present, nothing stored yet -> insert everything, with deltas
    $MOCK = MockDbh->new(probe_cols => 1, ver_row => undef, run_exists => 0, cur_exists => 0);
    @{$LOG->{msgs}} = (); @{$LOG->{dbg}} = ();
    is($H->backfill($LOG, 0), 0, 'A: backfill succeeds');
    my @vins = $match->(qr/INSERT INTO backup_versions/);
    is(scalar(@vins), 2, 'A: 2 version rows inserted');
    like($vins[0]{sql}, qr/lines_added/, 'A: version insert carries the delta columns');
    ok(!defined $vins[0]{bind}[5],        'A: oldest version delta is NULL (baseline)');
    is($vins[1]{bind}[5], 1,              'A: newer version lines_added = 1');
    is($vins[1]{bind}[6], 0,              'A: newer version lines_removed = 0');
    is(scalar($match->(qr/INSERT INTO backup_runs/)),    2, 'A: 2 run rows');
    is(scalar($match->(qr/INSERT INTO backup_current/)), 1, 'A: 1 current row');
    ok((grep { /^[0-9a-f]{40}$/ } @{$vins[1]{bind}}), 'A: version insert carries a sha1');
    ok((grep { /added 2 version, 2 run, 1 current/ } @{$LOG->{msgs}}), 'A: summary counts');
    ok(scalar(grep { /^process: / } @{$LOG->{dbg}}) >= 2, 'A: a "process:" line per backup');
    ok((grep { $_ eq 'Success' } @{$LOG->{msgs}}), 'A: logs "Success"');

    # B) delta columns present, rows exist with NULL delta -> FILL via UPDATE
    $MOCK = MockDbh->new(probe_cols => 1, ver_row => [undef], run_exists => 1, cur_exists => 1);
    is($H->backfill($LOG, 0), 0, 'B: backfill succeeds');
    is(scalar($match->(qr/INSERT INTO/)), 0, 'B: nothing inserted (all rows present)');
    my @upd = $match->(qr/UPDATE backup_versions SET lines_added/);
    is(scalar(@upd), 1, 'B: one existing row gets its delta filled');
    is($upd[0]{bind}[0], 1, 'B: filled lines_added = 1');
    is($upd[0]{bind}[1], 0, 'B: filled lines_removed = 0');
    ok((grep { /filled 1 line-delta/ } @{$LOG->{msgs}}), 'B: summary reports the fill');

    # C) preview with delta columns, nothing stored -> no writes, counts only
    $MOCK = MockDbh->new(probe_cols => 1, ver_row => undef, run_exists => 0, cur_exists => 0);
    @{$LOG->{msgs}} = ();
    is($H->backfill($LOG, 1), 0, 'C: preview succeeds');
    is(scalar($match->(qr/INSERT INTO|UPDATE /)), 0, 'C: preview writes nothing');
    ok((grep { /would add 2 version/ } @{$LOG->{msgs}}), 'C: preview reports would-add');

    # D) delta columns ABSENT (web < 2.12) -> original insert, no delta columns
    $MOCK = MockDbh->new(probe_cols => 0, ver_row => undef, run_exists => 0, cur_exists => 0);
    is($H->backfill($LOG, 0), 0, 'D: backfill succeeds without delta columns');
    my @vins_d = $match->(qr/INSERT INTO backup_versions/);
    is(scalar(@vins_d), 2, 'D: 2 version rows inserted');
    unlike($vins_d[0]{sql}, qr/lines_added/, 'D: no delta columns in the insert');

    # E) delta columns present, rows already populated -> idempotent, no writes
    $MOCK = MockDbh->new(probe_cols => 1, ver_row => [5], run_exists => 1, cur_exists => 1);
    is($H->backfill($LOG, 0), 0, 'E: re-run succeeds');
    is(scalar($match->(qr/INSERT INTO|UPDATE /)), 0, 'E: nothing written on a full re-run');
}

done_testing();

# --- fakes -------------------------------------------------------------------
{
    package NormModel;                         # exercises Abstract::config_norm_lines
    use parent -norequire, 'fetchconfig::model::Abstract';   # @ISA at compile time
    our $IGNORE;
    sub config_ignore_re { $IGNORE }
}
{
    package fetchconfig::model::Detector;      # only the two methods backfill uses
    our %INFO;
    sub device_ids  { sort keys %INFO }
    sub device_info { my ($c, $d) = @_; $INFO{$d} }
}
{
    package FakeModel;
    sub new { my ($c, $repo) = @_; bless { repo => $repo }, $c }
    sub dev_option { my ($s, $tab, $opt) = @_; $opt eq 'repository' ? $s->{repo} : undef }
    sub scan_dir {
        my ($s, $dt, $dev, $repo) = @_;
        opendir(my $dh, $repo) or return 1;
        for (readdir $dh) { $dt->{$_} = $repo if /^\Q$dev\E\.run\./ && -f "$repo/$_"; }
        closedir $dh;
        0;
    }
    sub config_norm_lines {                    # raw lines (no template loaded in backfill)
        my ($s, $dir, $file) = @_;
        open(my $fh, '<', "$dir/$file") or return undef;
        my @l = <$fh>; close $fh; \@l;
    }
}
{
    package FakeLog;   # mirrors fetchconfig::Logger (info/debug/error, no warn)
    sub new   { bless { msgs => [], dbg => [] }, shift }
    sub info  { push @{ $_[0]{msgs} }, $_[1] }
    sub error { push @{ $_[0]{msgs} }, $_[1] }
    sub debug { push @{ $_[0]{dbg} },  $_[1] }
}
{
    package MockSth;
    sub new { my ($c, $p, $sql) = @_; bless { p => $p, sql => $sql }, $c }
    sub execute {
        my ($s, @bind) = @_;
        push @{ $s->{p}{calls} }, { sql => $s->{sql}, bind => [@bind] };
        return $s->{sql} =~ /^\s*SELECT/i ? "0E0" : 1;   # SELECT fetched; write = 1 row
    }
    # Answer the different SELECTs backfill runs, driven by the MockDbh config.
    sub fetchrow_arrayref {
        my $s = shift; my $p = $s->{p}; my $sql = $s->{sql};
        return ($p->{probe_cols} ? [1] : undef) if $sql =~ /information_schema/;
        return $p->{ver_row}                     if $sql =~ /FROM backup_versions/;
        return ($p->{run_exists} ? [1] : undef)  if $sql =~ /FROM backup_runs/;
        return ($p->{cur_exists} ? [1] : undef)  if $sql =~ /FROM backup_current/;
        undef;
    }
    sub finish { 1 }

    package MockDbh;
    sub new { my ($c, %o) = @_; bless { calls => [], %o }, $c }
    sub prepare { my ($s, $sql) = @_; MockSth->new($s, $sql) }
    sub commit     { 1 }
    sub rollback   { 1 }
    sub disconnect { 1 }
}
