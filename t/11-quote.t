#!/usr/bin/perl
#
# 11-quote.t - regexp_quote_keep_bytes(), escape_brackets(), dequote_value()
#
# regexp_quote_keep_bytes is the byte-safe prompt quoter that replaced
# quotemeta throughout the models: it escapes regex metacharacters but,
# crucially, leaves non-ASCII bytes untouched (quotemeta backslash-escapes
# every byte >= 0x80, which corrupts a UTF-8 hostname and was the cause of
# the "\<c3>\<bc>" prompt-match bug). These tests lock the escape set, the
# byte preservation, and the property that ultimately matters: the result,
# used as a pattern, matches the exact string it was built from and treats
# "." as a literal.
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::Abstract');

sub q_bytes { fetchconfig::model::Abstract::regexp_quote_keep_bytes($_[0]) }
sub esc_br  { fetchconfig::model::Abstract::escape_brackets($_[0]) }
sub dequote { fetchconfig::model::Abstract::dequote_value($_[0]) }

# --- regexp_quote_keep_bytes: metacharacters escaped -------------------
is(q_bytes('a.b'),   'a\.b',      'dot escaped');
is(q_bytes('host-01'),'host\-01', 'hyphen escaped');
is(q_bytes('a(b)c'), 'a\(b\)c',   'parentheses escaped');
is(q_bytes('x+y'),   'x\+y',      'plus escaped');
is(q_bytes('x[0]'),  'x\[0\]',    'square brackets escaped');
is(q_bytes('a b'),   'a\ b',      'space escaped (prompts can contain spaces)');
is(q_bytes('p#1'),   'p\#1',      'hash escaped');
is(q_bytes('k=v'),   'k\=v',      'equals escaped');
is(q_bytes('a>b'),   'a\>b',      'angle bracket escaped');
is(q_bytes('plain'), 'plain',     'nothing to escape');
is(q_bytes(''),      '',          'empty string');

# --- the property that matters: the pattern matches its own source -----
for my $host ('sw.a-1', 'apgmg01 UG-IT', 'core(1)', 'a+b=c') {
    my $re = q_bytes($host);
    like($host, qr/^$re$/, "quoted [$host] matches itself literally");
}
# and "." is a literal, not "any character"
{
    my $re = q_bytes('sw.a1');
    unlike('swXa1', qr/^$re$/, 'dot in the quoted pattern is literal, not wildcard');
}

# --- byte preservation: non-ASCII bytes are NOT escaped ----------------
{
    # "Büro" as UTF-8 bytes: 42 C3 BC 72 6F. The two high bytes must pass
    # through unescaped (quotemeta would backslash them - the old bug).
    my $utf8 = "B\xc3\xbcro";
    my $re   = q_bytes($utf8);
    is($re, "B\xc3\xbcro", 'UTF-8 bytes preserved unescaped (no quotemeta mangling)');
    like($utf8, qr/^$re$/, 'quoted UTF-8 prompt matches itself');
}

# --- escape_brackets: the legacy subset (@ [ ] only) -------------------
is(esc_br('a[b]'), 'a\[b\]', 'escape_brackets: square brackets');
is(esc_br('x@y'),  'x\@y',   'escape_brackets: at-sign');
is(esc_br('a.b'),  'a.b',    'escape_brackets: dot NOT escaped (weaker than quote)');
is(esc_br('plain'),'plain',  'escape_brackets: nothing to do');

# --- dequote_value: unwrap one layer of double quotes ------------------
is(dequote('"a,b"'),           'a,b',           'quoted value with a comma');
is(dequote('plain'),           'plain',          'unquoted value unchanged');
is(dequote('""'),              '',               'empty quoted value');
is(dequote('"he said \"hi\""'),'he said "hi"',   'escaped inner quotes unwrapped');
is(dequote('"a\\\\b"'),        'a\\b',           'escaped backslash unwrapped');
is(dequote('"unterminated'),   '"unterminated',  'a lone leading quote is not a quoted value');

done_testing();
