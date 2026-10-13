#!/usr/bin/perl
#
# 44-allowlist-abort.t - a directory: allowlist with a parse error must
# abort the run (exit != 0) before any device is fetched, rather than
# continue with a silently reduced allowlist (9.68). --list-allowed-dirs
# stays exempt. Tests the driver decision in isolation (no transport
# modules): given a non-empty error list and no --list-allowed-dirs, the
# guard aborts; with --list-allowed-dirs it does not.
#
use strict;
use warnings;
use Test::More;

# the guard, mirrored from fetchconfig.pl
sub would_abort {
    my ($errors_ref, $list_allowed_dirs) = @_;
    return 0 if defined $list_allowed_dirs;
    return @$errors_ref ? 1 : 0;
}

ok( would_abort(['bad path'], undef),            'aborts when the allowlist has an error');
ok(!would_abort([],           undef),            'does not abort when the allowlist is clean');
ok(!would_abort(['bad path'], 1),                '--list-allowed-dirs is exempt (reports instead)');
ok(!would_abort([],           1),                '--list-allowed-dirs with a clean allowlist: fine');
ok( would_abort(['e1','e2'],  undef),            'aborts on multiple errors');

done_testing();
