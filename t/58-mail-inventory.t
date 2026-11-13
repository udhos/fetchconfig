#!/usr/bin/perl
# 58-mail-inventory.t - the summary e-mail's SNMP-inventory additions (9.80):
#   * inv_state() maps a result row to success | failed | N/A | not due
#   * the HTML body carries an Inventory count table and an Inventory column
#   * the plain-text body carries an Inventory count block and column
use strict; use warnings; use Test::More;
require fetchconfig::Mailer;

my $t = time;

# --- inv_state() mapping -------------------------------------------------------
is(fetchconfig::Mailer::inv_state({ inv_status => 'successful' }), 'success',
   'inv_state: successful -> success');
is(fetchconfig::Mailer::inv_state({ inv_status => 'failed' }), 'failed',
   'inv_state: failed -> failed');
is(fetchconfig::Mailer::inv_state({ inv_status => 'disabled' }), 'N/A',
   'inv_state: disabled -> N/A');
is(fetchconfig::Mailer::inv_state({ inv_status => 'none' }), 'N/A',
   'inv_state: none -> N/A');
is(fetchconfig::Mailer::inv_state({}), 'N/A',
   'inv_state: no inventory fields -> N/A');
is(fetchconfig::Mailer::inv_state({ inv_status => 'successful', inv_notdue => 1 }), 'not due',
   'inv_state: interval-skip (inv_notdue) -> not due, overriding the carried-forward status');

# --- a mixed fleet covering all four states -----------------------------------
my @rows = (
    { dev_id => 'd-ok',     ts => $t, success => 1, size => 10, changed => 'unchanged', inv_status => 'successful' },
    { dev_id => 'd-fail',   ts => $t, success => 1, size => 20, changed => 'changed',   inv_status => 'failed' },
    { dev_id => 'd-off',    ts => $t, success => 1, size => 30, changed => 'unchanged', inv_status => 'disabled' },
    { dev_id => 'd-plain',  ts => $t, success => 1, size => 40, changed => 'unchanged' },  # no inventory
    { dev_id => 'd-notdue', ts => $t, success => 1, size => 50, changed => 'unchanged', inv_status => 'successful', inv_notdue => 1 },
);
# expected inventory counts: success 1, failed 1, N/A 2, not due 1  (sums to 5)

# --- HTML -----------------------------------------------------------------------
my $inv = fetchconfig::Mailer->build_inv_stats_table_html(\@rows);
like($inv, qr{Inventory</th>.*?Count</th>}s, 'inv count table has the Inventory/Count header');
like($inv, qr{success</span></td><td[^>]*>\s*1\s*</td>}, 'inv count: success = 1');
like($inv, qr{failed</span></td><td[^>]*>\s*1\s*</td>},  'inv count: failed = 1');
like($inv, qr{N/A</span></td><td[^>]*>\s*2\s*</td>},     'inv count: N/A = 2');
like($inv, qr{not due</span></td><td[^>]*>\s*1\s*</td>}, 'inv count: not due = 1');

my $dev = fetchconfig::Mailer->build_device_table_html(\@rows);
like($dev, qr{Inventory</th>},                 'device table has an Inventory column header');
like($dev, qr{color: #2e7d32;">success</span>}, 'device table: success rendered green');
like($dev, qr{color: #b06a00;">not due</span>}, 'device table: not due rendered amber');
like($dev, qr{color: #8a929b;">N/A</span>},     'device table: N/A rendered grey');

# full HTML body: the inventory count table sits between stats and the device table
my $body = fetchconfig::Mailer->build_report_html(\@rows, 'Status of all backups');
my $p_stats = index($body, '>Statistic<');
my $p_inv   = index($body, '>Inventory<');       # the count-table header (first occurrence)
my $p_dev   = index($body, '>Device-ID<');
ok($p_stats >= 0 && $p_inv > $p_stats && $p_dev > $p_inv,
   'HTML order: Statistics, then Inventory counts, then the device table');

# --- plain text -----------------------------------------------------------------
my $text = fetchconfig::Mailer->build_report_text(\@rows, 'Status of all backups');
like($text, qr/^Inventory:/m,            'text body has an Inventory: counts block');
like($text, qr/success\s+1/,             'text inv count: success 1');
like($text, qr/N\/A\s+2/,                'text inv count: N/A 2');
like($text, qr/not due\s+1/,             'text inv count: not due 1');
like($text, qr/Device-ID.*Inventory/,    'text device table has an Inventory column');

done_testing();
