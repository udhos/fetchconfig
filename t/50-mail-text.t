#!/usr/bin/perl
# 50-mail-text.t - the text/plain part carries a plain-text summary: a
# statistics block and a per-device table (no diffs), matching the HTML
# data. Columns are auto-sized; skipped is shown only when it occurs.
use strict; use warnings; use Test::More;
require fetchconfig::Mailer;

# set the report link via the test hook (file-scoped lexical)
fetchconfig::Mailer->_test_set_rep('https://h/x.cgi?action=view_report&file=report-X.html')
    if fetchconfig::Mailer->can('_test_set_rep');

my @rows = (
    { dev_id => 'rtrcore11loop.schuler.de', ts => 1760000000, success => 1, size => 7296,  changed => 'unchanged' },
    { dev_id => 'short',                     ts => 1760000001, success => 0, size => undef, changed => 'n/a' },
    { dev_id => 'sidvpn-03',                 ts => 1760000002, state => 'skipped', size => undef, changed => 'n/a' },
);
my $t = fetchconfig::Mailer->build_report_text(\@rows, 'Status of all backups');

like($t,   qr/fetchconfig backup summary - \d{4}-\d\d-\d\d/, 'has a dated heading');
like($t,   qr/Statistics:/,                 'has a statistics block');
like($t,   qr/^\s*success\s+1/m,            'counts success');
like($t,   qr/^\s*failed\s+1/m,             'counts failed');
like($t,   qr/^\s*skipped\s+1/m,            'counts skipped (shown because it occurred)');
like($t,   qr/Devices:/,                    'has a device table');
like($t,   qr/Device-ID\s+Date\s+Time\s+State\s+Size\s+Changes/, 'device table header');
like($t,   qr/rtrcore11loop\.schuler\.de\s+2\S+\s+\S+\s+success\s+7296\s+unchanged/, 'a success device row');
like($t,   qr/sidvpn-03\s+\S+\s+\S+\s+skipped\s+-\s+n\/a/,  'a skipped device row (size -, changes n/a)');
like($t,   qr{Full report:\s+https://h/x\.cgi}, 'includes the full-report link');
unlike($t, qr/<[a-z]/i,                     'contains no HTML tags');

# columns auto-size: the long dev_id is not truncated
like($t, qr/rtrcore11loop\.schuler\.de/, 'long device id present in full');

done_testing();
