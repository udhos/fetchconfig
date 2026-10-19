#!/usr/bin/perl
#
# 52-recorder.t - record-session.pl internals (the bug fixes in 9.71).
#
# record-session.pl is a modulino: the "return 1 if caller" guard lets this
# test require() it to reach its pure subs (masking, render, telnet) without
# opening a device session. Covers:
#   - secret masking across read boundaries        (bugs 1 and 3)
#   - password masking stops at Enter in one read  (bug 2)
#   - .txt render: charset-select, split escape, telnet IAC   (bug 4)
#   - telnet option negotiation is answered        (bug 5)
#
use strict;
use warnings;
use Test::More;

my $path = 'tools/record-session.pl';
my $ok = eval { require $path; 1 };
plan skip_all => "cannot load $path: $@" unless $ok;

# ---- bug 1: a device-output secret split across two reads is fully masked ----
{
    my @c = (['<', 'snmp-server community pub'], ['<', "lic\n"]);
    main::secret_pass(\@c, [], 1);
    my $joined = join '', map { $_->[1] } @c;
    is($joined, "snmp-server community xxxxxx\n",
       'bug1: community value split across reads is fully masked');
    is(length($c[0][1]), 25, 'bug1: first read keeps its original length');
    is(length($c[1][1]), 4,  'bug1: second read keeps its original length');
}

# ---- bug 3: a -m secret typed over several reads is masked -------------------
{
    my @c = (['>', 'super'], ['>', 'secret']);
    main::secret_pass(\@c, ['supersecret'], 1);
    is(join('', map { $_->[1] } @c), 'xxxxxxxxxxx',
       'bug3: -m token split across reads is masked');
}

# ---- bug 2: password masking stops at Enter even with more text in the read --
{
    my @c = (['<', 'Password: '], ['>', "mypass\rshow version\r"]);
    main::pw_pass(\@c);
    is($c[1][1], "xxxxxx\rshow version\r",
       'bug2: password masked, command after Enter is NOT masked');
}

# a normal command (no preceding password prompt) is left untouched
{
    my @c = (['<', "switch> "], ['>', "show running-config\r"]);
    main::pw_pass(\@c);
    is($c[1][1], "show running-config\r", 'bug2: ordinary input is not masked');
}

# ---- bug 4a: ESC ( B (charset select) is consumed, not printed as "(B" -------
{
    my $txt = main::render_txt_body([['<', "\x1b(Bhello world\n"]]);
    like($txt, qr/hello world/, 'bug4a: text renders');
    unlike($txt, qr/\(B/,       'bug4a: charset-select not shown as "(B"');
}

# ---- bug 4b: an escape split across two reads is reassembled -----------------
{
    my $txt = main::render_txt_body([['<', "first\n\x1b[2"], ['<', "Jsecond\n"]]);
    like($txt,   qr/second/,   'bug4b: text after a split ESC[2J renders');
    unlike($txt, qr/\[2J/,     'bug4b: split escape not leaked as literal text');
}

# ---- bug 4c: telnet IAC negotiation bytes are not shown in the .txt ----------
{
    my $txt = main::render_txt_body([['<', "\xff\xfb\x01visible\n"]]);
    like($txt,   qr/visible/,  'bug4c: text renders');
    unlike($txt, qr/\xff/,     'bug4c: IAC byte not present in the render');
}

# ---- bug 5: telnet negotiation is answered -----------------------------------
{
    my $carry = '';
    my ($resp, $clean) =
        main::telnet_negotiation("\xff\xfb\x01login: ", \$carry, 80, 40);  # IAC WILL ECHO
    is($clean, 'login: ',                 'bug5: IAC stripped from the clean stream');
    is($resp, "\xff\xfd\x01",             'bug5: WILL ECHO is answered with DO ECHO');

    ($resp, $clean) = main::telnet_negotiation("\xff\xfd\x18", \$carry, 80, 40); # IAC DO TTYPE
    is($resp, "\xff\xfb\x18",             'bug5: DO TTYPE is answered with WILL TTYPE');

    # an IAC sequence split across two reads is carried and answered
    $carry = '';
    ($resp, $clean) = main::telnet_negotiation("\xff\xfb", \$carry, 80, 40);
    is($resp, '',                         'bug5: partial IAC produces no premature reply');
    is($carry, "\xff\xfb",                'bug5: partial IAC is carried');
    ($resp, $clean) = main::telnet_negotiation("\x01", \$carry, 80, 40);
    is($resp, "\xff\xfd\x01",             'bug5: carried IAC WILL ECHO answered once complete');
}

done_testing();
