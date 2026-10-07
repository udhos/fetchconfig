#!/usr/bin/perl
#
# 42-template-syntax.t - the "# syntax_style:" header parsing used by
# fetchconfig.pl --template-syntax. The option reads a template file and
# prints the declared syntax style (for a config viewer like
# fetchconfig-web to pick a highlighter); it never affects a backup.
#
# This tests the parsing rule in isolation (same regex as the driver), so
# it needs no transport modules.
#
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

# the parsing rule, identical to template_syntax_of() in fetchconfig.pl
sub parse_style {
    my ($text) = @_;
    for my $line (split /\n/, $text) {
        return $1 if $line =~ /^\s*#\s*syntax_style\s*:\s*([A-Za-z0-9_-]+)/i;
    }
    return undef;
}

# declared values (the full set fetchconfig-web maps)
for my $v (qw(cisco-ios procurve comware zyxel aruba-cx nexus mediant template json xml generic)) {
    is(parse_style("# header\n# syntax_style: $v\ntransport ssh\n"), $v, "declared: $v");
}

# placement / spacing tolerance
is(parse_style("#syntax_style:cisco-ios\n"),        'cisco-ios', 'no spaces');
is(parse_style("#   syntax_style  :  procurve\n"),  'procurve',  'extra spaces');
is(parse_style("# SYNTAX_STYLE: json\n"),           'json',      'case-insensitive key');
is(parse_style("transport ssh\n# syntax_style: xml\n"), 'xml',   'not required to be first line');

# absent / malformed -> undef
is(parse_style("transport ssh\nprompt_tail '#'\n"), undef, 'absent -> undef');
is(parse_style("# just a comment\n"),               undef, 'unrelated comment -> undef');
is(parse_style("# syntax_style:\n"),                undef, 'empty value -> undef');
is(parse_style("# syntax_style: has spaces\n"),     'has', 'value stops at first non-token char');

# first match wins
is(parse_style("# syntax_style: cisco-ios\n# syntax_style: json\n"), 'cisco-ios', 'first match wins');

done_testing();
