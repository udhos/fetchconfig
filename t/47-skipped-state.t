#!/usr/bin/perl
# 47-skipped-state.t - a lock-skip (state => 'skipped') must show as
# "skipped" in the summary statistics and the per-device State column, not
# as "failed". Tests Mailer::row_state / _report_state directly (no models).
use strict; use warnings; use Test::More;
require fetchconfig::Mailer;

my $ok   = { dev_id=>'ok01',   ts=>time, success=>1, size=>100, changed=>'changed' };
my $fail = { dev_id=>'fail01', ts=>time, success=>0, size=>undef, changed=>'n/a' };
my $skip = { dev_id=>'skip01', ts=>time, state=>'skipped', size=>undef, changed=>'n/a' };

is(fetchconfig::Mailer::row_state($ok),   'success', 'success row -> success');
is(fetchconfig::Mailer::row_state($fail), 'failed',  'failed row -> failed');
is(fetchconfig::Mailer::row_state($skip), 'skipped', 'skipped row -> skipped (not failed)');

is(fetchconfig::Mailer::_report_state($skip), 'Skipped', 'change-report state of a skip is Skipped');

# the statistics tally must put the skip in its own bucket
my %c; $c{fetchconfig::Mailer::row_state($_)}++ for ($ok, $fail, $skip);
is($c{skipped}, 1, 'skipped counted in the skipped bucket');
is($c{failed},  1, 'only the real failure is in the failed bucket');
is($c{success}, 1, 'success bucket unaffected');

done_testing();
