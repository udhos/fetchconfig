#!/usr/bin/perl
# 46-locking.t - device-lock primitives: sha256 path, acquire/contention,
# retry, release; and clean_lock_dir (flock-first, min 1 day).
use strict; use warnings; use Test::More;
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw(tempdir);

my $loadable = eval { require fetchconfig::Logger; require fetchconfig::model::CiscoIOS; 1 };
plan skip_all => 'model not loadable here' unless $loadable;

my $log = fetchconfig::Logger->new({ prefix => 't' });
{ no warnings 'redefine','once'; *fetchconfig::Logger::debug=sub{}; *fetchconfig::Logger::info=sub{}; *fetchconfig::Logger::error=sub{}; }
my $m = fetchconfig::model::CiscoIOS->new($log);

# the lock gate uses the on/off convention (dev_option_flag)
$m->{default_options} = { lock => 'on' };
is($m->dev_option_flag({}, 'lock', 0), 1, 'lock=on enables locking');
$m->{default_options} = { lock => 'off' };
is($m->dev_option_flag({}, 'lock', 0), 0, 'lock=off disables locking');
$m->{default_options} = {};
is($m->dev_option_flag({}, 'lock', 0), 0, 'lock unset disables locking');
is($m->dev_option_flag({ lock => 'on' }, 'lock', 0), 1, 'lock=on on the device line enables');

# lock_dir must be a directory-valued option so a "directory: lock $TAG"
# alias expands, exactly like repository=/template_dir=. With no allowlist
# a literal path passes through; the alias-expansion path is covered by the
# allowlist tests. Here we at least prove a literal lock_dir is returned.
is($m->dev_option({ lock_dir => '/custom/lock' }, 'lock_dir'), '/custom/lock',
   'literal lock_dir passes through unchanged');

my $d = tempdir(CLEANUP => 1);
my $path = $m->device_lock_path($d, 'dev01');
like($path, qr{/[0-9a-f]{64}\.lock$}, 'lock path is <sha256(dev_id)>.lock');

my $fh = $m->acquire_device_lock($path, 'dev01', 0, 1);
ok(ref($fh) || ref(\$fh) eq 'GLOB', 'first acquire gets the lock');

# a child contends; retry=0 -> immediate 'locked'
my $pid = fork();
if (!$pid) {
    my $r = $m->acquire_device_lock($path, 'dev01', 0, 1);
    exit($r eq 'locked' ? 0 : 1);
}
waitpid($pid, 0);
is($? >> 8, 0, 'contending child with lock_retry=0 gets "locked" immediately');

# child with retry=2,time=1 waits ~2s then 'locked'
my $t0 = time;
$pid = fork();
if (!$pid) {
    my $r = $m->acquire_device_lock($path, 'dev01', 2, 1);
    exit($r eq 'locked' ? 0 : 1);
}
waitpid($pid, 0);
is($? >> 8, 0, 'contending child with retry=2 gets "locked" after retrying');
ok(time - $t0 >= 2, 'the retry actually waited (>= 2s)');

close($fh);   # release
my $fh2 = $m->acquire_device_lock($path, 'dev01', 0, 1);
ok(ref($fh2) || ref(\$fh2) eq 'GLOB', 'lock re-acquirable after release');
close($fh2);

done_testing();

