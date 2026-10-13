#!/usr/bin/perl
# 45-numeric-options.t - F1.1 (keep=) and F1.2 (timeout family) validation.
use strict; use warnings; use Test::More;
my $loadable = eval { require fetchconfig::Logger; require fetchconfig::model::CiscoIOS; 1 };
plan skip_all => 'CiscoIOS/Logger not loadable here' unless $loadable;

my $log = fetchconfig::Logger->new({ prefix => 't' });
{ no warnings 'redefine','once'; *fetchconfig::Logger::debug=sub{}; *fetchconfig::Logger::info=sub{}; }
my $m = fetchconfig::model::CiscoIOS->new($log);
$m->{default_options} = {};

# F1.2: timeout family - bad value falls back to default, good value kept
is($m->dev_option({timeout=>'0'},   'timeout'), 30, 'timeout=0 -> default 30 (not wait-forever)');
is($m->dev_option({timeout=>'abc'}, 'timeout'), 30, 'timeout=abc -> default 30');
is($m->dev_option({timeout=>'-5'},  'timeout'), 30, 'timeout=-5 -> default 30');
is($m->dev_option({timeout=>'45'},  'timeout'), 45, 'timeout=45 -> 45');

# dev_option_posint: allow_zero distinguishes lock_retry (0 ok) from times
is($m->dev_option_posint({lock_retry=>'0'},      'lock_retry', 5, 1), 0,  'lock_retry=0 allowed');
is($m->dev_option_posint({lock_retry=>'abc'},    'lock_retry', 5, 1), 5,  'lock_retry=abc -> default 5');
is($m->dev_option_posint({lock_retry_time=>'0'}, 'lock_retry_time', 10, 0), 10, 'lock_retry_time=0 -> default 10 (no busy-spin)');
is($m->dev_option_posint({lock_retry_time=>'30'},'lock_retry_time', 10, 0), 30, 'lock_retry_time=30 -> 30');
is($m->dev_option_posint({}, 'lock_retry', 5, 1), 5, 'lock_retry unset -> default 5');

done_testing();
