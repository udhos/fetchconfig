#!/usr/bin/perl
#
# 53-history.t - fetchconfig::History: the pure, device-free logic of the
# optional DB backup-history writer. No DB and no Net::Telnet are needed:
#   - db_host parsing (IPv6 bracket convention)
#   - spool serialize/parse round-trip
#   - op building from run results (run/current always, version only when a
#     backup is retained, expire events)
#   - the pre-9.5 DML selection and bind values, via a mock DBI handle
# The DB connection and drain I/O are integration concerns, not covered here.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

require_ok('fetchconfig::History');
my $H = 'fetchconfig::History';

# --- db_host parsing (IPv6-capable). _parse_host is a plain sub (1 arg) -------
{
    my $ph = \&fetchconfig::History::_parse_host;
    is_deeply([$ph->('localhost')],        ['localhost', undef],  'host, no port');
    is_deeply([$ph->('localhost:5432')],   ['localhost', '5432'], 'host:port');
    is_deeply([$ph->('db.example.com')],   ['db.example.com', undef], 'fqdn');
    is_deeply([$ph->('192.0.2.10:6543')],  ['192.0.2.10', '6543'], 'ipv4:port');
    is_deeply([$ph->('[2001:db8::1]:5432')],['2001:db8::1', '5432'], 'ipv6 bracket + port');
    is_deeply([$ph->('[2001:db8::1]')],    ['2001:db8::1', undef], 'ipv6 bracket, no port');
    is_deeply([$ph->('2001:db8::1')],      ['2001:db8::1', undef], 'bare ipv6 -> host only');
    is_deeply([$ph->('fe80::1')],          ['fe80::1', undef],     'bare ipv6 short');
    is_deeply([$ph->('')],                 [undef],                'empty -> undef');
    is_deeply([$ph->('[bad')],             [undef],                'stray bracket -> undef');
}

# --- spool serialize / parse round-trip -------------------------------
{
    my @ops = (
        { op=>'run', dev_id=>'d1', run_end=>1000, state=>'success', changed=>'changed',
          duration_sec=>3, size_bytes=>100, fail_reason=>undef, repository=>'/r' },
        { op=>'version', dev_id=>'d1', file_timestamp=>111, path=>'/r/a b\tc',
          size_bytes=>100, sha1=>'deadbeef' },
    );
    my ($fh, $path) = tempfile(UNLINK => 1);
    print $fh fetchconfig::History::_serialize($_), "\n" for @ops;
    close $fh;

    my ($got, $ok) = fetchconfig::History::_read_spool($path);
    ok($ok, 'spool read ok');
    is(scalar(@$got), 2, 'two ops read back');
    is($got->[0]{op}, 'run', 'op kind preserved');
    is($got->[0]{run_end}, 1000, 'int field preserved');
    ok(!defined($got->[0]{fail_reason}), 'undef round-trips as undef');
    is($got->[1]{path}, '/r/a b\tc', 'embedded tab/space in path round-trips');
    is($got->[1]{sha1}, 'deadbeef', 'sha1 preserved');
}

# --- op building from results -----------------------------------------
{
    my @results = (
        # retained change -> run + current + version
        { dev_id=>'d1', repository=>'/r', ts=>1000, elapsed=>3, success=>1, size=>100,
          changes_only=>1, changed=>'changed', path=>'/r/f1', file_timestamp=>111, sha1=>'aa' },
        # changes_only unchanged (discarded) -> run + current, NO version
        { dev_id=>'d2', repository=>'/r', ts=>1000, elapsed=>2, success=>1, size=>100,
          changes_only=>1, changed=>'unchanged' },
        # failed -> run + current (fail_reason), NO version
        { dev_id=>'d3', repository=>'/r', ts=>1000, elapsed=>0, success=>0, size=>undef,
          changed=>'n/a' },
        # initial in a second repo -> run + current + version
        { dev_id=>'d4', repository=>'/r2', ts=>1000, elapsed=>5, success=>1, size=>200,
          changed=>'initial', path=>'/r2/f', file_timestamp=>222, sha1=>'bb' },
    );
    my @expires = ( { dev_id=>'d1', repository=>'/r', file_timestamp=>99 } );

    my %by = fetchconfig::History::_ops_by_repo(\@results, \@expires);

    my %kinds_r  = _count_kinds($by{'/r'});
    my %kinds_r2 = _count_kinds($by{'/r2'});

    is($kinds_r{run},     3, '/r: run op per result');
    is($kinds_r{current}, 3, '/r: current op per result');
    is($kinds_r{version}, 1, '/r: version only for the retained change');
    is($kinds_r{expire},  1, '/r: expire op present');
    is($kinds_r2{run},    1, '/r2: run');
    is($kinds_r2{version},1, '/r2: version for initial');

    my ($ver) = grep { $_->{op} eq 'version' } @{$by{'/r'}};
    is($ver->{dev_id}, 'd1', 'version op dev_id');
    is($ver->{sha1},   'aa', 'version op sha1');
    is($ver->{file_timestamp}, 111, 'version op file_timestamp');

    my ($fail_cur) = grep { $_->{op} eq 'current' && $_->{dev_id} eq 'd3' } @{$by{'/r'}};
    is($fail_cur->{state}, 'failed', 'failed run state');
    is($fail_cur->{fail_reason}, 'other', 'failed run fail_reason=other');
    is($fail_cur->{success}, 0, 'failed current success flag 0');

    my ($init_cur) = grep { $_->{op} eq 'current' && $_->{dev_id} eq 'd4' } @{$by{'/r2'}};
    is($init_cur->{changed}, 'initial', 'initial changed value');
    is($init_cur->{success}, 1, 'initial success flag 1');
    is($init_cur->{run_end}, fetchconfig::History::_local_epoch(1005),
       'run_end = local-wall-clock epoch of (ts + elapsed)');
}

sub _count_kinds { my ($ops) = @_; my %k; $k{$_->{op}}++ for @$ops; %k }

# --- pre-9.5 DML selection + binds via a mock DBI handle --------------
{
    my $dbh = MockDbh->new;

    ok(fetchconfig::History::_apply_op($dbh, {
        op=>'run', dev_id=>'d1', run_end=>1000, state=>'success', changed=>'changed',
        duration_sec=>3, size_bytes=>100, fail_reason=>undef, repository=>'/r' }),
       'run op applies');
    like($dbh->last->{sql}, qr/INSERT INTO backup_runs/, 'run -> insert backup_runs');
    like($dbh->last->{sql}, qr/WHERE NOT EXISTS/, 'run -> idempotent guard');
    is(scalar(@{$dbh->last->{bind}}), 10, 'run bind count');

    $dbh->reset;
    ok(fetchconfig::History::_apply_op($dbh, {
        op=>'version', dev_id=>'d1', file_timestamp=>111, path=>'/r/f', size_bytes=>100, sha1=>'aa' }),
       'version op applies');
    like($dbh->last->{sql}, qr/INSERT INTO backup_versions/, 'version -> insert backup_versions');
    is(scalar(@{$dbh->last->{bind}}), 7, 'version bind count');

    # current, existing row (UPDATE affects 1) -> single statement, advances last_good
    $dbh->reset; $dbh->{rows} = 1;
    ok(fetchconfig::History::_apply_op($dbh, {
        op=>'current', dev_id=>'d1', run_end=>1000, state=>'success', changed=>'changed',
        duration_sec=>3, size_bytes=>100, fail_reason=>undef, repository=>'/r', success=>1 }),
       'current op (update) applies');
    is(scalar(@{$dbh->{calls}}), 1, 'current update: one statement when row exists');
    like($dbh->{calls}[0]{sql}, qr/UPDATE backup_current/, 'current -> update');
    like($dbh->{calls}[0]{sql}, qr/last_good_at=\?/, 'success update advances last_good');

    # current, no row (UPDATE affects 0) -> update then insert
    $dbh->reset; $dbh->{rows} = 0;
    ok(fetchconfig::History::_apply_op($dbh, {
        op=>'current', dev_id=>'d9', run_end=>1000, state=>'failed', changed=>'unknown',
        duration_sec=>0, size_bytes=>undef, fail_reason=>'other', repository=>'/r', success=>0 }),
       'current op (insert) applies');
    is(scalar(@{$dbh->{calls}}), 2, 'current insert: update then insert when no row');
    like($dbh->{calls}[0]{sql}, qr/UPDATE backup_current/, 'first stmt update');
    unlike($dbh->{calls}[0]{sql}, qr/last_good/, 'non-success update leaves last_good untouched');
    like($dbh->{calls}[1]{sql}, qr/INSERT INTO backup_current/, 'second stmt insert');

    $dbh->reset;
    ok(fetchconfig::History::_apply_op($dbh, {
        op=>'expire', dev_id=>'d1', file_timestamp=>111 }), 'expire op applies');
    like($dbh->last->{sql}, qr/UPDATE backup_versions SET expired=true/, 'expire -> update expired');
}

done_testing();

# --- a minimal DBI handle mock ---------------------------------------
{
    package MockSth;
    sub new { my ($c, $parent, $sql) = @_; bless { parent=>$parent, sql=>$sql }, $c }
    sub execute {
        my ($s, @bind) = @_;
        push @{ $s->{parent}{calls} }, { sql => $s->{sql}, bind => [@bind] };
        return $s->{parent}{rows};   # affected-row count the mock is set to
    }

    package MockDbh;
    sub new   { bless { calls => [], rows => 1 }, shift }
    sub reset { my $s = shift; $s->{calls} = []; $s->{rows} = 1; }
    sub last  { my $s = shift; $s->{calls}[-1] }
    sub prepare { my ($s, $sql) = @_; MockSth->new($s, $sql) }
    sub commit     { 1 }
    sub rollback   { 1 }
    sub disconnect { 1 }
    sub errstr     { '' }
}
