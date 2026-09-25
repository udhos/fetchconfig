#!/usr/bin/perl
#
# 31-config-equal.t - config_equal_ignoring_lines()
#
# Several models override config_equal to ignore a line the device
# rewrites on every read (ASA "!!: Written by ...", NX-OS "!Time:", a
# re-salted hash), so that a volatile line does not by itself count as a
# change. config_equal_ignoring_lines strips every line matching a regex
# from both files before comparing, and returns false if either file
# cannot be read (so the newer version is kept rather than silently
# discarded). Tested against throwaway files in a File::Temp directory.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

my $loadable = eval {
    require fetchconfig::Logger;
    require fetchconfig::model::CiscoIOS;
    1;
};
if (!$loadable) {
    plan skip_all => 'CiscoIOS/Logger not loadable here (missing prerequisite)';
}

my $log = fetchconfig::Logger->new({ prefix => 't' });
{ no warnings 'redefine', 'once';
  *fetchconfig::Logger::debug = sub { };
  *fetchconfig::Logger::info  = sub { };
  *fetchconfig::Logger::error = sub { }; }
my $m = fetchconfig::model::CiscoIOS->new($log);

my $dir = tempdir(CLEANUP => 1);
sub write_file {
    my ($name, $text) = @_;
    open(my $fh, '>', "$dir/$name") or die "write $name: $!";
    print $fh $text;
    close $fh;
}

my $IGNORE = qr/^!Time:/;

# Three files: A and B differ ONLY in the ignored line; C differs in a
# real line as well.
write_file('a.cfg', "hostname sw01\n!Time: 10:00:00\ninterface e0\n");
write_file('b.cfg', "hostname sw01\n!Time: 23:59:59\ninterface e0\n");
write_file('c.cfg', "hostname sw02\n!Time: 10:00:00\ninterface e0\n");
write_file('d.cfg', "hostname sw01\ninterface e0\n");   # no volatile line at all

ok( $m->config_equal_ignoring_lines($dir, 'a.cfg', $dir, 'b.cfg', $IGNORE),
    'equal when only the ignored line differs');
ok(!$m->config_equal_ignoring_lines($dir, 'a.cfg', $dir, 'c.cfg', $IGNORE),
    'not equal when a real line differs (ignored line notwithstanding)');
ok( $m->config_equal_ignoring_lines($dir, 'a.cfg', $dir, 'a.cfg', $IGNORE),
    'a file equals itself');
ok( $m->config_equal_ignoring_lines($dir, 'a.cfg', $dir, 'd.cfg', $IGNORE),
    'equal when one file has the volatile line and the other does not (both stripped)');

# A missing file -> false, so the caller keeps the newer version rather
# than discarding it as "unchanged".
ok(!$m->config_equal_ignoring_lines($dir, 'a.cfg', $dir, 'gone.cfg', $IGNORE),
    'missing current file -> not equal (keep the newer version)');
ok(!$m->config_equal_ignoring_lines($dir, 'gone.cfg', $dir, 'a.cfg', $IGNORE),
    'missing previous file -> not equal');

# Multiple ignored lines, and the ignore pattern matching mid-file.
write_file('e.cfg', "!Time: 1\nhostname sw01\n!Time: 2\nend\n");
write_file('f.cfg', "!Time: 9\nhostname sw01\n!Time: 8\nend\n");
ok( $m->config_equal_ignoring_lines($dir, 'e.cfg', $dir, 'f.cfg', $IGNORE),
    'all matching lines stripped, wherever they appear');

done_testing();
