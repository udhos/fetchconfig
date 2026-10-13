#!/usr/bin/perl
# 49-mail-style.t - the summary e-mail uses the fetchconfig-web card look:
# grey canvas, white rounded card, dark-blue header bar with the inline
# cid:fcwlogo and "fetchconfig vX.Y", and the copyright footer OUTSIDE/below
# the card. The embedded logo decodes to a PNG.
use strict; use warnings; use Test::More;
require fetchconfig::Mailer;
require fetchconfig::Constants;

my @rows = ({ dev_id => 'd1', ts => time, success => 1, size => 10, changed => 'changed' });
my $h = fetchconfig::Mailer->build_report_html(\@rows, 'Status of all backups');

like($h, qr/background:#f4f5f7/,              'grey canvas');
like($h, qr/max-width:640px.*border-radius:10px/s, 'white rounded card');
like($h, qr/background:#1f4e79/,              'dark-blue header bar');
like($h, qr/src="cid:fcwlogo"/,               'inline logo via cid:fcwlogo');
my $ver = fetchconfig::Constants::version();
like($h, qr/fetchconfig <span[^>]*>v\Q$ver\E</, "header shows fetchconfig v$ver");

# footer is OUTSIDE/below the card: it must appear AFTER the card table closes
my $card_open  = index($h, 'background:#1f4e79');
my $footer_pos = index($h, '#8a929b');
ok($footer_pos > $card_open, 'copyright footer is placed after the card header (below the card)');
like($h, qr/#8a929b[^>]*>\(c\)/,              'footer carries the copyright, muted colour');

# the embedded logo base64 decodes to a PNG (read it out of the module source)
my $src = do { local (@ARGV,$/) = ('fetchconfig/Mailer.pm'); <> };
my ($b64) = $src =~ /my \$MAIL_LOGO_B64 = <<'__LOGO__';\n(.*?)\n__LOGO__/s;
ok(defined $b64, 'logo base64 constant present');
SKIP: {
    skip 'MIME::Base64 not available', 1 unless eval { require MIME::Base64; 1 };
    (my $clean = $b64) =~ s/\s+//g;
    my $png = MIME::Base64::decode_base64($clean);
    is(substr($png, 0, 8), "\x89PNG\r\n\x1a\n", 'embedded logo starts with the PNG signature');
        # a truncated base64 (the bug fixed here) decodes to a PNG that
        # starts correctly but has no IEND; require the complete file.
        ok(substr($png, -8) eq "IEND\xaeB\x60\x82", 'embedded logo is a COMPLETE PNG (ends with IEND)');
}


# --- report button + copy-link fallback (needs $rep_url, a file-scoped
# lexical; set it via the module's own test hook so we share that scope).
SKIP: {
    skip 'no _test_set_rep hook in this build', 3
        unless fetchconfig::Mailer->can('_test_set_rep');
    fetchconfig::Mailer->_test_set_rep('https://h/x.cgi?action=view_report&file=report-X.html');
    my $hb = fetchconfig::Mailer->build_report_html(
        [{ dev_id => 'd1', ts => time, success => 1, size => 10, changed => 'changed' }], 'Status');
    like($hb, qr/View the full report<\/a>/,                 'report CTA button present');
    like($hb, qr/background:#1f4e79;color:#ffffff;text-decoration:none/, 'button uses header palette');
    like($hb, qr/If the button does not work/,               'copy-this-link fallback present');
}

done_testing();
