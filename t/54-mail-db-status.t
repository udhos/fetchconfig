#!/usr/bin/perl
#
# 54-mail-db-status.t - the DB-history writer status box in the summary mail:
#   - History::mail_status returns the right (state,label,detail) per state
#   - Mailer::_db_status_box_html maps state -> palette/pill
#   - build_report_html/_text include the box ONLY when asked (main summary),
#     and show the grey "not configured" box when no db: is set
# No DB and no Net::Telnet are needed (the "off" path needs neither).
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::History');
require_ok('fetchconfig::Mailer');

# --- mail_status, db: not configured -> grey "off" --------------------------
{
    my ($state, $label, $detail) = fetchconfig::History->mail_status;
    is($state, 'off', 'mail_status state is off when no db:');
    is($label, 'NOT CONFIGURED', 'off label');
    like($detail, qr/not configured/i, 'off detail mentions not configured');
}

# --- _db_status_box_html palette mapping ------------------------------------
{
    my $ok = fetchconfig::Mailer->_db_status_box_html('ok', 'WRITTEN', 'All 3 record(s) written; outbox empty.');
    like($ok, qr/#2e7d32/,                 'ok box uses green accent');
    like($ok, qr/Backup history database/, 'ok box has the title');
    like($ok, qr/WRITTEN/,                 'ok box has the WRITTEN pill');
    like($ok, qr/All 3 record\(s\) written/, 'ok box carries the detail');
    # Pill sits in its own cell (padding-left), not on a margin Outlook would drop.
    like($ok,   qr/padding-left:8px/, 'pill in its own cell for Outlook spacing');
    unlike($ok, qr/margin-left/,      'no inline margin Outlook would ignore');

    my $bad = fetchconfig::Mailer->_db_status_box_html('incomplete', 'INCOMPLETE', '1 run(s) still pending (oldest X); will retry next run.');
    like($bad, qr/#c62828/,    'incomplete box uses red accent');
    like($bad, qr/INCOMPLETE/, 'incomplete box has the INCOMPLETE pill');

    my $off = fetchconfig::Mailer->_db_status_box_html('off', 'NOT CONFIGURED', 'History database export is not configured.');
    like($off, qr/#8a929b/,         'off box uses grey accent');
    like($off, qr/NOT CONFIGURED/,  'off box has the NOT CONFIGURED pill');

    # HTML-unsafe detail is escaped
    my $esc = fetchconfig::Mailer->_db_status_box_html('off', 'X', 'a <b> & "c"');
    like($esc, qr/&lt;b&gt;/, 'detail is HTML-escaped');
    unlike($esc, qr/<b>/,     'no raw tag leaks through');
}

# --- build_report_html: box only with the flag ------------------------------
{
    my @rows = (
        { dev_id => 'sw01', ts => 1700000000, success => 1, size => 100, changed => 'changed' },
    );

    my $with = fetchconfig::Mailer->build_report_html(\@rows, 'Status of all backups', 1);
    like($with, qr/Backup history database/, 'box present when flag set');
    like($with, qr/NOT CONFIGURED/,          'shows grey box when db: is off');

    my $without = fetchconfig::Mailer->build_report_html(\@rows, 'Status of all backups');
    unlike($without, qr/Backup history database/, 'no box without the flag (override mails)');

    my $text = fetchconfig::Mailer->build_report_text(\@rows, 'Status of all backups', 1);
    like($text, qr/Backup history database: NOT CONFIGURED - /, 'text twin present with flag');
    my $text0 = fetchconfig::Mailer->build_report_text(\@rows, 'Status of all backups');
    unlike($text0, qr/Backup history database:/, 'no text line without the flag');
}

done_testing();
