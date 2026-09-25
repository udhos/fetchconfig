#!/usr/bin/perl
#
# 32-tools.t - fetchconfig::Tools helpers: dir_is_empty(), _only_entry_is(),
#              safe_rmdir()
#
# The directory predicates behind the -e (empty-directory cleanup) and -o
# (orphan cleanup) maintenance modes. safe_rmdir is the ONLY way those
# modes remove a directory: it removes exactly one directory and, because
# it uses rmdir, physically cannot remove a non-empty one. Tested against
# a File::Temp directory built and torn down inside the test.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# fetchconfig::Tools uses Detector, which loads every model; a model whose
# optional transport module is absent makes that load fail. Treat it as a
# skip (missing prerequisite), not a failure - same rule as 00-compile.t.
my $loadable = eval { require fetchconfig::Tools; 1 };
if (!$loadable) {
    plan skip_all => 'fetchconfig::Tools not loadable here (a model prerequisite is missing)';
}

# safe_rmdir logs through the module's $log; give it a quiet one.
{
    package Test::QuietLog;
    sub new   { bless {}, shift }
    sub info  { }
    sub debug { }
    sub error { }
    sub prefix { }
}
fetchconfig::Tools->init(log => Test::QuietLog->new, me => 'test');

my $root = tempdir(CLEANUP => 1);

# --- dir_is_empty ------------------------------------------------------
make_path("$root/empty");
ok( fetchconfig::Tools::dir_is_empty("$root/empty"),  'dir_is_empty: an empty directory');

make_path("$root/full");
open(my $fh, '>', "$root/full/afile"); close $fh;
ok(!fetchconfig::Tools::dir_is_empty("$root/full"),   'dir_is_empty: a non-empty directory');

ok(!fetchconfig::Tools::dir_is_empty("$root/nonexistent"),
   'dir_is_empty: a missing directory is not "empty" (opendir fails -> false)');

# a directory whose only entries are subdirectories is NOT empty
make_path("$root/withsub/child");
ok(!fetchconfig::Tools::dir_is_empty("$root/withsub"),
   'dir_is_empty: a directory containing only a subdirectory is not empty');

# --- _only_entry_is ----------------------------------------------------
make_path("$root/one");
make_path("$root/one/thedir");
ok( fetchconfig::Tools::_only_entry_is("$root/one", 'thedir'),
    '_only_entry_is: matches when the sole entry has the given name');
ok(!fetchconfig::Tools::_only_entry_is("$root/one", 'other'),
    '_only_entry_is: no match when the sole entry has a different name');

open($fh, '>', "$root/one/extra"); close $fh;
ok(!fetchconfig::Tools::_only_entry_is("$root/one", 'thedir'),
    '_only_entry_is: no match when there is more than one entry');

ok(!fetchconfig::Tools::_only_entry_is("$root/empty", 'anything'),
    '_only_entry_is: no match for an empty directory');

# --- safe_rmdir --------------------------------------------------------
make_path("$root/todelete");
ok(-d "$root/todelete", 'precondition: directory exists');
ok( fetchconfig::Tools::safe_rmdir("$root/todelete"), 'safe_rmdir removes an empty directory (returns true)');
ok(!-d "$root/todelete", 'the directory is gone');

# refuses (cannot remove) a non-empty directory: rmdir fails, returns false
make_path("$root/nonempty");
open($fh, '>', "$root/nonempty/keep"); close $fh;
ok(!fetchconfig::Tools::safe_rmdir("$root/nonempty"),
   'safe_rmdir returns false for a non-empty directory');
ok(-d "$root/nonempty", 'the non-empty directory is left intact');

# test mode ($test true): reports but does not remove
make_path("$root/testmode");
ok( fetchconfig::Tools::safe_rmdir("$root/testmode", 1),
    'safe_rmdir in test mode returns true (would delete)');
ok(-d "$root/testmode", 'test mode does not actually remove the directory');

done_testing();
