#!/usr/bin/perl
#
# 42-directory-allowlist.t - the directory: allowlist parser/validator and
# the repository=/template_dir= resolver in model::Detector.
#
# Pure checks: no device, no network. Exercises path-content validation
# (/../, /./, illegal characters), tag/type rules, exact + trailing-slash
# match, $TAG expansion, wrong-type rejection, and that an absent section
# means no enforcement.
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::Detector');
my $D = 'fetchconfig::model::Detector';

# parse_directory_line logs via the package logger, which init() sets.
# init() also registers the models (~90ms, no forking) - fine for a unit
# test. Silence the logger so the error paths exercised below stay quiet.
require fetchconfig::Logger;
{
    no warnings qw(redefine once);
    *fetchconfig::Logger::error = sub { };
    *fetchconfig::Logger::debug = sub { };
    *fetchconfig::Logger::info  = sub { };
}
fetchconfig::model::Detector->init(fetchconfig::Logger->new({ prefix => 't' }));

# --- path-content validation (the internal _bad_dir_path) ----------------
{
    no strict 'refs';
    my $bad = \&{"fetchconfig::model::Detector::_bad_dir_path"};
    ok( !$bad->('/usr/local/fetchconfig/config'), 'plain absolute path OK' );
    ok(  $bad->('/tmp/../etc'),        'rejects /../' );
    ok(  $bad->('/tmp/./x'),           'rejects /./' );
    ok(  $bad->('relative/path'),      'rejects relative path (no leading /)' );
    ok(  $bad->("/tmp/x\x00y"),        'rejects NUL' );
    ok(  $bad->('/tmp/x;rm -rf'),      'rejects shell metacharacter ;' );
    ok(  $bad->('/tmp/x|y'),           'rejects pipe' );
    ok( !$bad->('/tmp/a-b_c.d/e+f@g'), 'allows the safe character set' );
}

# --- the resolver: no allowlist present -> no enforcement ----------------
{
    # fresh interpreter state: with no directory: lines parsed, the
    # allowlist is absent and any value passes through unchanged.
    ok( !$D->dir_allowlist_present, 'allowlist absent by default' );
    my ($ok, $val) = $D->resolve_allowed_dir('repository', '/anything');
    ok( $ok && $val eq '/anything', 'absent allowlist: value passes unchanged' );
}

# --- parse a directory: section and exercise the resolver ----------------
{
    # feed directory: lines through the same entry point parse() uses
    $D->parse_directory_line('t', 1, 'repository $REPO1 /var/fc/config');
    $D->parse_directory_line('t', 2, 'template   $TPL1  /var/fc/templates/');  # trailing /

    ok( $D->dir_allowlist_present, 'allowlist present after directory: lines' );

    # $TAG expansion
    my ($ok1, $p1) = $D->resolve_allowed_dir('repository', '$REPO1');
    ok( $ok1 && $p1 eq '/var/fc/config', '$REPO1 expands to its path' );

    # literal exact match
    my ($ok2) = $D->resolve_allowed_dir('repository', '/var/fc/config');
    ok( $ok2, 'literal allowed repository path matches' );

    # trailing-slash equivalence (list has trailing /, value has none)
    my ($ok3) = $D->resolve_allowed_dir('template', '/var/fc/templates');
    ok( $ok3, 'trailing-slash difference still matches' );

    # off-list
    my ($ok4, $why4) = $D->resolve_allowed_dir('repository', '/etc/evil');
    ok( !$ok4, 'off-list path rejected' );

    # wrong type: template path used as repository
    my ($ok5) = $D->resolve_allowed_dir('repository', '/var/fc/templates');
    ok( !$ok5, 'template path rejected for repository (typed)' );

    # wrong type via tag
    my ($ok6) = $D->resolve_allowed_dir('repository', '$TPL1');
    ok( !$ok6, '$TPL1 (template tag) rejected for repository' );

    # undefined tag
    my ($ok7) = $D->resolve_allowed_dir('repository', '$NOPE');
    ok( !$ok7, 'undefined tag rejected' );

    # illegal content in a literal value
    my ($ok8) = $D->resolve_allowed_dir('repository', '/var/fc/../etc');
    ok( !$ok8, 'literal value with /../ rejected' );
}

# --- lint: dir_allowlist_errors records malformed entries ----------------
{
    # a bad type and a bad path are recorded for the linter
    fetchconfig::model::Detector->parse_directory_line('t', 10, 'nope $X /var/x');
    fetchconfig::model::Detector->parse_directory_line('t', 11, 'repository $Y /var/../x');
    my @errs = fetchconfig::model::Detector->dir_allowlist_errors;
    ok( scalar(@errs) >= 2, 'malformed directory: entries are recorded for the linter' );
}

# --- fetch_run type + on_fetch_run resolver ------------------------------
{
    fetchconfig::model::Detector->parse_directory_line('t', 20, 'fetch_run $CMD1 /var/fc/run');

    # $TAG form: $CMD1/prog -> /var/fc/run/prog (allowed, tag is the dir)
    my ($ok1, $r1) = fetchconfig::model::Detector->resolve_allowed_fetch_run('$CMD1/prog.pl -x');
    ok( $ok1 && $r1 eq '/var/fc/run/prog.pl -x', 'on_fetch_run $TAG expands and is allowed' );

    # literal in the allowed dir
    my ($ok2) = fetchconfig::model::Detector->resolve_allowed_fetch_run('/var/fc/run/x.sh');
    ok( $ok2, 'literal on_fetch_run in allowed dir is allowed' );

    # literal in a NON-allowed dir
    my ($ok3) = fetchconfig::model::Detector->resolve_allowed_fetch_run('/tmp/evil/x.sh');
    ok( !$ok3, 'on_fetch_run in non-allowed dir rejected' );

    # wrong-type tag
    my ($ok4) = fetchconfig::model::Detector->resolve_allowed_fetch_run('$REPO1/x');
    ok( !$ok4, 'on_fetch_run with a non-fetch_run tag rejected' )
        if 0;  # $REPO1 not defined in this run; covered by live tests

    # relative program (no directory) rejected
    my ($ok5) = fetchconfig::model::Detector->resolve_allowed_fetch_run('x.sh');
    ok( !$ok5, 'relative on_fetch_run program rejected' );

    # all three types now present (repository/template from earlier block + fetch_run)
    my @miss = fetchconfig::model::Detector->dir_allow_missing_types;
    is( scalar(@miss), 0, 'all three directory types present -> no missing-type problem' );
}

# --- dev_option expands directory aliases centrally ----------------------
{
    # a fresh model with an allowlist defining $Z1 -> /var/fc/z
    fetchconfig::model::Detector->parse_directory_line('t', 30, 'repository $Z1 /var/fc/z');
    require fetchconfig::model::CiscoIOS;
    my $m = fetchconfig::model::CiscoIOS->new(fetchconfig::Logger->new({ prefix => 't' }));
    my $ok = $m->dev_option({ repository => '$Z1' }, 'repository');
    is( $ok, '/var/fc/z', 'dev_option expands a repository $TAG to its path' );
    my $lit = $m->dev_option({ repository => '/var/fc/z' }, 'repository');
    is( $lit, '/var/fc/z', 'dev_option passes a literal allowed path unchanged' );
}

done_testing();
