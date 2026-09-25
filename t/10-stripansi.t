#!/usr/bin/perl
#
# 10-stripansi.t - fetchconfig::model::Abstract::stripansi()
#
# stripansi removes terminal control noise (ANSI/VT100 escape sequences,
# NUL and CR) from device output before a prompt or a configuration is
# read. It is a plain function, not a method. Every case below is drawn
# from a real regression or a real device capture (ProCurve 2610,
# Comware); the point of the suite is that a future change to the three
# substitutions cannot silently reintroduce one of those bugs.
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::Abstract');

# Call the function directly; it takes and returns a byte string.
sub strip { fetchconfig::model::Abstract::stripansi($_[0]) }

# --- CSI sequences (ESC [ ... letter), any number of parameters --------
is(strip("\x1b[2JX"),            'X',  'CSI erase-display');
is(strip("\x1b[24;1HX"),         'X',  'CSI cursor-position, two params');
is(strip("\x1b[1;37;40mX\x1b[0m"), 'X', 'SGR with THREE params (old rule allowed only two)');
is(strip("\x1b[mX"),             'X',  'CSI with no params');
is(strip("\x1b[1;2;3;4;5mX"),    'X',  'CSI with five params');

# --- DEC private-mode set/reset (ESC [ ? ... h|l) ----------------------
is(strip("\x1b[?25hX"),          'X',  'DEC private set   (?25h, show cursor)');
is(strip("\x1b[?25lX"),          'X',  'DEC private reset (?25l, hide cursor) - the swi11024 bug');
is(strip("\x1b[?7lX"),           'X',  'DEC private reset (?7l)');

# --- two-byte escapes (ESC E/M/D/7/8/=/>) ------------------------------
is(strip("a\x1bEb"),             'ab', 'ESC E (NEL) - "HP ProCurves use this"');
is(strip("a\x1bMb"),             'ab', 'ESC M (reverse index)');
is(strip("a\x1b7b\x1b8c"),       'abc','ESC 7 / ESC 8 (save/restore cursor)');

# --- NUL and CR --------------------------------------------------------
is(strip("x\x00y"),              'xy', 'NUL removed (Comware banner boundary)');
is(strip("a\r\nb"),              "a\nb",'CR removed, LF kept (SSH line ending)');
is(strip("a\r\r\nb"),            "a\nb",'double CR removed, LF kept (telnet line ending)');

# --- the swi11024 sequence verbatim (prompt learned clean) -------------
is(strip("\x1b[24;1H\x1b[2K\x1b[24;1Hswi11024_swi320059# "),
   'swi11024_swi320059# ',
   'real 2610 prompt sequence stripped to the bare prompt');

# --- negatives: configuration content must survive untouched -----------
is(strip('hostname "sw01"'),     'hostname "sw01"', 'plain config line unchanged');
is(strip('access-list [inbound]'),'access-list [inbound]',
   'brackets in a config line are NOT an escape and must be kept');
is(strip('value = a[0] + b'),    'value = a[0] + b', 'array subscript kept');
is(strip(''),                    '',   'empty string');
is(strip("no controls here"),    'no controls here', 'plain ASCII unchanged');

# --- idempotence: stripping twice equals stripping once ----------------
my $once = strip("\x1b[2Jhostname sw01\r\n\x1b[?25l");
is(strip($once), $once, 'stripansi is idempotent');

done_testing();
