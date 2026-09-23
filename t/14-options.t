#!/usr/bin/perl
#
# 14-options.t - mask_secrets(), opt_trim(), dev_option(), dev_option_flag()
#
# The option layer: how a device-table line's secrets are hidden from the
# log, how option whitespace is trimmed, and how per-device options
# resolve (device value, else model default, else undef - with timeout's
# 30-second fallback). dev_option/dev_option_flag are methods, so the
# tests use a real model object (CiscoIOS) with a hand-built option table;
# no network is involved.
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::Abstract');

# --- mask_secrets ------------------------------------------------------
sub mask { fetchconfig::model::Abstract::mask_secrets($_[0]) }

is(mask('cisco-ios d1 h user=admin,pass=secret,timeout=10'),
   'cisco-ios d1 h user=admin,pass=***,timeout=10',
   'pass= masked, other options untouched');
is(mask('x enable=E,community=C'),
   'x enable=***,community=***',
   'enable= and community= masked');
is(mask('PASS=UpperCase'),
   'PASS=***',
   'case-insensitive (PASS)');
is(mask('a pass=one,b pass=two'),
   'a pass=***,b pass=***',
   'every pass= token is masked (global), not just the first');
is(mask('user=admin,to=a@b.example'),
   'user=admin,to=a@b.example',
   'non-secret options are not masked');

# Behaviour to be aware of (pinned, not endorsed): the pattern is
# \b(pass|enable|community)=, so "password=" is NOT masked - "pass"
# must be immediately followed by "=". Documented here so a change to
# mask_secrets is a conscious one.
is(mask('x password=P'),   'x password=P',   'password= is NOT masked (pass must be followed by =)');
is(mask('x passphrase=K'), 'x passphrase=K', 'passphrase= is NOT masked');

# --- opt_trim ----------------------------------------------------------
sub trim { fetchconfig::model::Abstract::opt_trim($_[0]) }

is(trim('  x  '), 'x',    'surrounding spaces trimmed');
is(trim('a b'),   'a b',  'internal space kept');
is(trim(' a b '), 'a b',  'trim ends, keep middle');
is(trim('x'),     'x',    'single char');
is(trim(''),      '',     'empty string');
is(trim("\tx\t"), 'x',    'tabs trimmed');

# --- dev_option / dev_option_flag (need a model object) ----------------
SKIP: {
    my $ok = eval {
        require fetchconfig::Logger;
        require fetchconfig::model::CiscoIOS;
        1;
    };
    skip('CiscoIOS/Logger not loadable here', 12) unless $ok;

    my $log = fetchconfig::Logger->new({ prefix => 't' });
    # Silence debug/info so the "Using 30s fetch timeout ..." notice that
    # dev_option emits does not clutter the TAP stream; errors still show.
    { no warnings 'redefine', 'once';
      *fetchconfig::Logger::debug = sub { };
      *fetchconfig::Logger::info  = sub { }; }
    my $m   = fetchconfig::model::CiscoIOS->new($log);
    $m->{default_options} = { keep => 5, timeout => 15 };

    # resolution order
    is($m->dev_option({}, 'keep'),          5,  'dev_option falls back to model default');
    is($m->dev_option({ keep => 9 }, 'keep'), 9, 'device value overrides the default');
    is($m->dev_option({}, 'timeout'),       15, 'timeout default from model default');
    ok(!defined($m->dev_option({}, 'no_such_option')), 'unknown option is undef');

    # timeout's special 30-second fallback when nothing is set
    $m->{default_options} = {};
    is($m->dev_option({}, 'timeout'), 30, 'timeout falls back to 30 when unset anywhere');

    # dev_option_flag: on/off/unset, case- and whitespace-insensitive
    is($m->dev_option_flag({ debug => 'on'  }, 'debug', 0), 1, 'flag on  -> 1');
    is($m->dev_option_flag({ debug => 'off' }, 'debug', 0), 0, 'flag off -> 0');
    is($m->dev_option_flag({ debug => 'ON'  }, 'debug', 0), 1, 'flag ON  -> 1 (case-insensitive)');
    is($m->dev_option_flag({ debug => ' on ' }, 'debug', 0), 1, 'flag " on " -> 1 (trimmed)');
    is($m->dev_option_flag({}, 'debug', 1), 1, 'unset flag uses default (1)');
    is($m->dev_option_flag({}, 'debug', 0), 0, 'unset flag uses default (0)');
    is($m->dev_option_flag({ debug => 'yes' }, 'debug', 0), 0,
       'a value other than "on" is 0 (only "on" is true)');
}

done_testing();
