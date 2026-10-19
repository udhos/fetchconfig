#!/usr/bin/perl
#
# record-session.pl - part of fetchconfig
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# fetchconfig is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fetchconfig; see the file COPYING. If not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
# record-session.pl - capture a telnet or SSH session with a network device
# as a byte-accurate log, for writing a new fetchconfig model and for unit
# test fixtures.
#
# It connects the way a fetchconfig model does (Net::Telnet directly, or
# Net::OpenSSH wrapped in Net::Telnet), then hands you a live interactive
# session and tees everything both directions to two files:
#
#   <output>.txt   a HUMAN-READABLE render. The device output is replayed
#                  through a small ANSI/VT100 screen emulator, so a
#                  menu-driven / cursor-addressed device (e.g. HP ProCurve,
#                  which prints "Press any key" at row 24 over the banner and
#                  redraws screens) is shown as the SCREENS the operator saw,
#                  not as an unreadable escape-code stream. A screen snapshot
#                  is written whenever the device clears the screen and at the
#                  end; typed input appears as "> ..." lines. A line-oriented
#                  device (Cisco IOS) renders as a normal scrolling transcript.
#   <output>.hex   an offset + hex + ASCII dump of the EXACT bytes received,
#                  in the PuTTY "all session output" style this project parses.
#                  This is the authoritative record for building a model; the
#                  .txt is a readability aid.
#
# CREDENTIALS
#   ssh     : -u/--user and -p/--password provide the login (SSH
#             authenticates before the shell starts). If -p is omitted it
#             is prompted for, without echo.
#   telnet  : the username and password are typed interactively at the
#             device's own prompts.
#   enable  : always typed interactively during the session, at the
#             device's "Password:" prompt.
#
# MASKING (same length, so byte offsets and line lengths are preserved and
# the .hex stays a faithful fixture):
#   - the ssh -u/-p values, which the tool knows, are masked automatically;
#   - every -m/--mask string is masked on an exact byte match in either
#     direction (repeatable; a value may itself contain commas/semicolons,
#     it is matched literally) - use this for the enable password, telnet
#     credentials, SNMP communities and any other known secret;
#   - a best-effort set of patterns masks well-known secrets the DEVICE
#     prints (Cisco "password 7 ...", "secret 5 ...", "snmp-server
#     community X", keys), replaced with same-length "x".
#
# Masking is finalized ONCE at the end of the session, on COMPLETE lines, so a
# secret (or a -m token, or a typed password) split across two network reads is
# still masked as a whole. Because every mask is same-length, the .hex keeps the
# original per-read framing.
#
# Masking of hashes/communities/keys in device output is BEST EFFORT and
# WILL MISS THINGS. Review both files before sharing them. The tool prints
# this reminder when it finishes.
#
# TELNET NEGOTIATION
#   Over telnet the tool answers the device's option negotiation (accepts the
#   device's ECHO and SGA, offers TTYPE and NAWS) so the session behaves like a
#   real client. The raw IAC (0xff) bytes are still recorded in the .hex so
#   generate_template can detect a telnet capture; they are kept out of the
#   live view and the .txt.
#
# Usage:
#   record-session.pl -h HOST [-t ssh|telnet] [-u USER] [-p PASS]
#                     [-o BASE] [-m SECRET]... [--no-auto-secrets]
#                     [--timeout N]
#
# Requires Net::Telnet (both transports); Net::OpenSSH and the ssh client
# for ssh. No other non-core modules.
#

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case bundling);
use IO::Handle;
use POSIX qw(strftime);

my %opt = (transport => 'ssh', timeout => 30, auto_secrets => 1);
my @mask_tokens;
my $show_help;
my $show_version;

# Kept in step with fetchconfig's version by hand. NOT imported from
# fetchconfig::Constants, so this tool is self-contained and can be copied
# and run on its own.
my $VERSION = '9.72';

# Password-prompt masking state. Declared here (before the relay runs) so
# the value exists when record_raw is first called - a "my" initialiser
# further down the file would not have executed yet.
my $pw_mode = 0;
my $pw_raw = "";   # rolling raw device tail, for split-safe prompt detection

# Modulino guard: when this file is require()d (by the test suite) rather than
# run directly, define the subs but do not open a session. caller() is true
# only under require/do, and the "if caller" keeps this from being an illegal
# top-level return when the script is run normally.
return 1 if caller;

GetOptions(
    'h|host=s'        => \$opt{host},
    't|transport=s'   => \$opt{transport},
    'u|user=s'        => \$opt{user},
    'p|password=s'    => \$opt{password},
    'o|output=s'      => \$opt{output},
    'm|mask=s'        => \@mask_tokens,
    'no-auto-secrets' => sub { $opt{auto_secrets} = 0 },
    'timeout=i'       => \$opt{timeout},
    'help'            => \$show_help,
    'V|version'       => \$show_version,
) or usage(2);

if ($show_version) {
    print "record-session.pl (fetchconfig) $VERSION\n",
          "Copyright (c) 2026 Rainer Tammer\n",
          "License GPL-2.0-or-later: GNU GPL version 2 or later.\n",
          "This is free software; see the source for copying conditions. There is NO\n",
          "warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n";
    exit 0;
}
usage(0) if $show_help;
usage(2) unless defined $opt{host};

$opt{transport} = lc $opt{transport};
die "transport must be 'ssh' or 'telnet'\n" unless $opt{transport} =~ /^(ssh|telnet)$/;

my ($host, $port) = ($opt{host}, undef);
($host, $port) = ($1, $2) if $opt{host} =~ /^(.+):(\d+)$/;

# --- credentials ---------------------------------------------------------
my ($user, $pass);
if ($opt{transport} eq 'ssh') {
    $user = defined $opt{user}     ? $opt{user}     : prompt_plain("SSH username: ");
    $pass = defined $opt{password} ? $opt{password} : prompt_noecho("SSH password: ");
    die "ssh needs a username (use -u)\n" unless defined $user && length $user;
}
# telnet: login typed live at the device prompts; nothing collected here.

# Secrets the tool knows and can mask automatically (ssh credentials).
# The enable password and telnet credentials are only masked if named with
# -m, or if caught by the built-in patterns. Longest first so a longer
# secret masks before a shorter substring of it.
my @secrets = grep { defined && length }
              ( ($opt{transport} eq 'ssh' ? ($pass, $user) : ()), @mask_tokens );
@secrets = sort { length($b) <=> length($a) } uniq(@secrets);

# --- output files --------------------------------------------------------
my $base = defined $opt{output} ? $opt{output}
         : sprintf('session-%s-%s', safe($opt{host}), strftime('%Y%m%d-%H%M%S', localtime));
open(my $TXT, '>', "$base.txt") or die "cannot write $base.txt: $!\n";
open(my $HEX, '>', "$base.hex") or die "cannot write $base.hex: $!\n";
binmode $TXT; binmode $HEX;
$TXT->autoflush(1); $HEX->autoflush(1);

my $stamp  = strftime('%Y-%m-%d %H:%M:%S %Z', localtime);
my $header = "# record-session.pl  host=$opt{host}  transport=$opt{transport}  $stamp\n"
           . "# masking (same length): "
           . ($opt{transport} eq 'ssh' ? "ssh user/pass" : "none automatic (telnet)")
           . (@mask_tokens ? " + ".scalar(@mask_tokens)." -m token(s)" : "")
           . ($opt{auto_secrets} ? " + built-in output patterns" : "")
           . "\n# BEST EFFORT - review before sharing\n";
print $TXT $header;
print $HEX $header;

# --- connect -------------------------------------------------------------
require Net::Telnet;
my ($t, $ssh, $pid);

if ($opt{transport} eq 'telnet') {
    $t = Net::Telnet->new(Errmode => 'return', Timeout => $opt{timeout}, Telnetmode => 1);
    $t->open(Host => $host, Port => (defined $port ? $port : 23))
        or die "could not connect (telnet): " . $t->errmsg . "\n";
}
else {
    require Net::OpenSSH;
    $ssh = Net::OpenSSH->new($host, user => $user, password => $pass,
                             (defined $port ? (port => $port) : ()),
                             timeout => $opt{timeout},
                             master_opts => [ -o => "StrictHostKeyChecking=no",
                                              -o => "UserKnownHostsFile=/dev/null",
                                              -o => "LogLevel=ERROR" ]);
    die "could not connect (ssh): " . $ssh->error . "\n" if $ssh->error;
    # Size the pty to the local terminal (falling back to 80x40) so a
    # full-screen, cursor-addressed device (HP ProCurve drives a 40-row
    # VT100 screen) draws WITHIN your terminal during the live session
    # instead of overflowing it. Without this, the default pty size can
    # mismatch the device's assumed geometry and the live output looks
    # broken. The .txt emulation is unaffected either way.
    my ($pty, $child) = $ssh->open2pty;
    die "could not start remote shell: " . $ssh->error . "\n" unless defined $pty;
    if (ref($pty) && $pty->can('set_winsize')) {
        my ($cols, $rows) = term_size();
        eval { $pty->set_winsize($rows, $cols) };   # ($rows,$cols) order
    }
    $pid = $child;
    $t = Net::Telnet->new(Errmode => 'return', Timeout => $opt{timeout},
                          Telnetmode => 0, Fhopen => $pty);
}

my $devfh = device_handle($t);
die "internal: could not obtain the device filehandle\n" unless defined $devfh;

print STDERR "Connected to $opt{host} ($opt{transport}).\n",
    ($opt{transport} eq 'telnet' ? "Log in at the prompts below. " : ""),
    "Type commands; end with 'exit'/'logout' or Ctrl-] .\n",
    "Enter the enable password at the device's own prompt when needed.\n\n";

# --- interactive relay, line-buffered recording --------------------------
my $done = 0;
$SIG{INT} = $SIG{TERM} = sub { $done = 1 };

my $tn_carry = '';                       # partial telnet IAC sequence across reads
my ($tn_cols, $tn_rows) = term_size();   # advertised to the device via NAWS

raw_mode_on();
eval {
    require IO::Select;
    my $sel = IO::Select->new(\*STDIN, $devfh);
    while (!$done) {
        for my $fh ($sel->can_read(0.25)) {
            if ($fh == \*STDIN) {
                my $n = sysread(\*STDIN, my $in, 4096);
                if (!$n) {
                    # local input closed (EOF / redirected input exhausted):
                    # stop watching it, but keep draining the device so the
                    # rest of the session is still captured.
                    $sel->remove(\*STDIN);
                    next;
                }
                if ((my $i = index($in, "\x1d")) >= 0) { $in = substr($in, 0, $i); $done = 1; }
                if (length $in) { syswrite($devfh, $in); record_raw('>', $in); }
            }
            else {
                my $n = sysread($fh, my $out, 4096);
                unless (defined $n && $n) { $done = 1; last; }   # device closed -> end
                # Telnet: answer the device's option negotiation (DO/WILL) that a
                # raw sysread relay would otherwise never reply to, and keep the
                # IAC bytes out of the live view. record_raw still stores $out
                # RAW, so the 0xff bytes stay in the .hex for generate_template.
                my $shown = $out;
                if ($opt{transport} eq 'telnet') {
                    my $resp;
                    ($resp, $shown) = telnet_negotiation($out, \$tn_carry, $tn_cols, $tn_rows);
                    syswrite($devfh, $resp) if length $resp;
                }
                syswrite(\*STDOUT, mask_live($shown, \@secrets, $opt{auto_secrets}));
                record_raw('<', $out);
            }
        }
    }
    1;
} or do { my $e = $@; raw_mode_off(); warn "session error: $e\n"; };

finalize();      # mask the whole captured session (line-accurate) + write .hex
render_txt();    # human-readable .txt from the masked transcript
raw_mode_off();

$t->close if $t;
waitpid($pid, 0) if defined $pid;
close $TXT; close $HEX;

print STDERR "\n\nSaved:\n  $base.txt\n  $base.hex\n\n",
    "NOTE: masking is BEST EFFORT. The ssh -u/-p values and your -m tokens\n",
    "are masked exactly; secrets the DEVICE prints (config hashes, SNMP\n",
    "communities, keys) are only caught by a small pattern set and MAY REMAIN.\n",
    "Review both files before sharing them or committing them as fixtures.\n";
exit 0;

# =========================================================================

my @xcript;   # ordered [dir, raw-bytes] chunks of the whole session. Masking
              # and the .hex/.txt are produced from this at finalize() time, so
              # a secret split across reads is still masked as one unit.

sub record_raw {
    my ($dir, $bytes) = @_;
    push @xcript, [ $dir, $bytes ];   # RAW; masked once, line-accurate, at finalize()
}

# finalize - mask the whole captured session and write the masked .hex.
#
# Masking happens here, after the session, so it sees COMPLETE lines regardless
# of how the network split the bytes into reads: a secret (a -m token, a typed
# password, or a pattern-matched value) spanning two reads is masked as a whole,
# which per-read masking could not do. Every mask is same-length, so the masked
# stream stays byte-aligned with the raw one and is re-sliced back to the
# ORIGINAL read lengths - the .hex therefore keeps the original read boundaries.
sub finalize {
    pw_pass(\@xcript);                                    # prompt-driven password masking
    secret_pass(\@xcript, \@secrets, $opt{auto_secrets}); # known secrets + output patterns
    hexdump($HEX, $_->[0], $_->[1]) for @xcript;          # masked, original read framing
}

# pw_pass - prompt-driven password masking over the chronological transcript.
#
# When the DEVICE prints a "Password:"-style prompt, the NEXT thing typed (and
# any echo of it) is a secret the tool cannot know in advance, so mask every
# printable byte - in both directions - until Enter ends the entry. Walking the
# transcript in order keeps the cross-direction state (prompt in '<', the typed
# secret in '>') correct. The per-byte loop re-checks $pw so masking stops at
# the Enter even when more text (the next command) arrives in the same read.
# Detection tolerates the prompt and its trailing escapes being split across
# reads via a rolling, escape-stripped tail.
sub pw_pass {
    my ($chunks) = @_;
    my $pw  = 0;    # masking currently active
    my $raw = '';   # rolling device tail for split-safe prompt detection
    for my $c (@$chunks) {
        my ($dir, $bytes) = @$c;

        if ($pw) {
            my $out = '';
            for my $ch (split //, $bytes) {
                if (!$pw) { $out .= $ch; next; }          # entry already ended in this read
                if ($ch eq "\r" || $ch eq "\n") { $pw = 0; $out .= $ch; }
                elsif (ord($ch) >= 0x20 && ord($ch) < 0x7f) { $out .= 'x'; }
                else { $out .= $ch; }
            }
            $bytes = $out;
            $c->[1] = $bytes;
        }

        next unless $dir eq '<';
        # arm masking for the NEXT entry if the device output now ends in a prompt
        $raw .= $bytes;
        $raw = substr($raw, -200) if length($raw) > 200;
        my $vis = $raw;
        $vis =~ s/\xff(?:[\xfb-\xfe].|[\xf0-\xfa])//g;    # telnet IAC commands
        $vis =~ s/\x1b\[[0-9;?]*[A-Za-z]//g;              # CSI sequences
        $vis =~ s/\x1b[()][A-Za-z0-9]//g;                 # charset selects
        $vis =~ s/\x1b[A-Za-z0-9=>]//g;                   # other 2-byte escapes
        $vis =~ s/[\x00-\x08\x0b-\x1f\x7f]//g;            # remaining control bytes
        $vis =~ s/[\s\r\n]+$//;
        $pw = 1 if $vis =~ /password\s*[:#>]$/i;
    }
}

# secret_pass - same-length masking of known secrets (ssh creds, -m tokens) and
# well-known output patterns, applied to each direction's COMPLETE stream (so a
# secret split across reads is caught), then re-sliced back to the original read
# lengths. Patterns are applied per line so a greedy match cannot span lines.
sub secret_pass {
    my ($chunks, $secrets, $auto) = @_;
    for my $dir ('<', '>') {
        my @idx = grep { $chunks->[$_][0] eq $dir } 0 .. $#$chunks;
        next unless @idx;
        my $stream = join '', map { $chunks->[$_][1] } @idx;
        $stream = mask_literal($stream, $secrets);
        $stream = mask_patterns_perline($stream) if $auto;
        my $pos = 0;
        for my $i (@idx) {
            my $len = length $chunks->[$i][1];
            $chunks->[$i][1] = substr($stream, $pos, $len);   # same length -> aligned
            $pos += $len;
        }
    }
}

# telnet_negotiation - reply to the device's telnet option negotiation that a
# raw sysread relay would otherwise never answer, and return the data with all
# IAC sequences removed (for the live view). The caller records the RAW bytes,
# so the .hex keeps the 0xff negotiation for generate_template to detect telnet.
# $carry (scalar ref) holds a partial IAC sequence split across reads. Policy:
# accept the device's ECHO and SGA, offer TTYPE and NAWS, refuse the rest.
# Returns ($response_to_send, $clean_data).
sub telnet_negotiation {
    my ($data, $carry, $cols, $rows) = @_;
    $data = $$carry . $data; $$carry = '';
    my ($resp, $clean) = ('', '');
    my $len = length $data;
    my $i = 0;
    while ($i < $len) {
        my $b = ord substr($data, $i, 1);
        if ($b != 0xff) { $clean .= substr($data, $i, 1); $i++; next; }
        if ($i + 1 >= $len) { $$carry = substr($data, $i); last; }      # partial IAC
        my $cmd = ord substr($data, $i + 1, 1);
        if ($cmd == 0xff) { $clean .= chr(0xff); $i += 2; next; }       # escaped 0xff
        if ($cmd == 0xfa) {                                             # SB ... IAC SE
            my $se = index($data, chr(0xff) . chr(0xf0), $i + 2);
            if ($se < 0) { $$carry = substr($data, $i); last; }         # incomplete subneg
            my $sub = substr($data, $i + 2, $se - ($i + 2));
            if (length($sub) >= 2 && ord(substr($sub, 0, 1)) == 24
                                  && ord(substr($sub, 1, 1)) == 1) {    # TTYPE SEND
                $resp .= chr(0xff).chr(0xfa).chr(24).chr(0)."XTERM".chr(0xff).chr(0xf0);
            }
            $i = $se + 2; next;
        }
        if ($cmd >= 0xfb && $cmd <= 0xfe) {                             # WILL/WONT/DO/DONT opt
            if ($i + 2 >= $len) { $$carry = substr($data, $i); last; }
            my $opt = ord substr($data, $i + 2, 1);
            $resp .= telnet_reply($cmd, $opt, $cols, $rows);
            $i += 3; next;
        }
        $i += 2; next;                                                  # other 2-byte command
    }
    return ($resp, $clean);
}

sub telnet_reply {
    my ($cmd, $opt, $cols, $rows) = @_;
    my ($WILL, $WONT, $DO, $DONT)  = (0xfb, 0xfc, 0xfd, 0xfe);
    my ($ECHO, $SGA, $TTYPE, $NAWS) = (1, 3, 24, 31);
    my $IAC = chr(0xff);
    if ($cmd == $WILL) {                           # device offers to do $opt
        return $IAC.chr($DO).chr($opt) if $opt == $ECHO || $opt == $SGA;
        return $IAC.chr($DONT).chr($opt);
    }
    if ($cmd == $DO) {                             # device asks us to do $opt
        return $IAC.chr($WILL).chr($TTYPE) if $opt == $TTYPE;
        if ($opt == $NAWS) {
            my $size = pack('n', $cols) . pack('n', $rows);
            $size =~ s/\xff/\xff\xff/g;            # IAC-escape inside subnegotiation
            return $IAC.chr($WILL).chr($NAWS)
                 . $IAC.chr(0xfa).chr($NAWS).$size.$IAC.chr(0xf0);
        }
        return $IAC.chr($WONT).chr($opt);
    }
    return $IAC.chr($DONT).chr($opt) if $cmd == $WONT;
    return $IAC.chr($WONT).chr($opt) if $cmd == $DONT;
    return '';
}

# ---------------------------------------------------------------------------
# render_txt - write the human-readable .txt from the whole session.
#
# The device stream is replayed through a small VT100/ANSI screen emulator
# (a 2D character grid + cursor). This is essential for menu-driven /
# full-screen devices such as HP ProCurve, whose output is cursor-addressed
# ("Press any key" printed at row 24 over the banner, screens redrawn with
# ESC[2J): the raw stream is unreadable, but the emulated SCREEN is what the
# operator actually saw. A snapshot of the screen is written whenever the
# device clears it (ESC[2J) and at the end, so the sequence of screens is
# preserved rather than collapsed into one final image. Typed input is
# shown as "> <command>" lines in the order it was sent.
#
# For a line-oriented device (Cisco IOS etc.) there are no cursor moves, so
# the emulator degenerates to a normal line-by-line transcript.
#
# The .hex is the authoritative byte record; this .txt is a readability aid,
# and its header says so.
sub render_txt {
    print $TXT "\n# The screens below are an ANSI/VT100 emulation of the device output,\n",
               "# for readability (menu-driven devices are cursor-addressed). The .hex\n",
               "# file holds the exact bytes. Typed input is shown as \"> ...\" lines.\n";
    print $TXT render_txt_body(\@xcript);
}

# render_txt_body - build the human-readable transcript from the masked chunks
# and return it. Pure (no globals), so it is unit-tested directly. Fixes over
# the first version: a charset-select (ESC ( B) is consumed rather than printed
# as "(B"; an escape or telnet IAC sequence split across two reads is
# reassembled via $carry instead of leaking as literal text; and telnet
# negotiation bytes (IAC, 0xff) are consumed, not shown.
sub render_txt_body {
    my ($chunks) = @_;
    my $COLS = 200;
    my @grid; my ($cr, $cc, $maxrow);
    my $reset = sub { @grid = (); ($cr,$cc,$maxrow)=(1,1,1); };
    $reset->();
    my $out   = '';
    my $inbuf = '';   # accumulates typed input across reads
    my $carry = '';   # incomplete device escape / IAC tail carried across reads

    my $need_row = sub {
        my ($r) = @_;
        while (@grid < $r) { push @grid, [ (' ') x $COLS ]; }
    };

    my $snap_no = 0;
    my $last_snap = '';
    my $dump_screen = sub {
        my @rows;
        for my $r (0 .. $maxrow - 1) {
            my $ref = $grid[$r];
            (my $l = defined $ref ? join('', @$ref) : '') =~ s/\s+$//;
            push @rows, $l;
        }
        pop @rows while @rows && $rows[-1] eq '';
        return unless @rows;
        # collapse an interior run of >1 blank line to a single blank line
        my @o; my $blank = 0;
        for my $l (@rows) {
            if ($l eq '') { $blank++; push @o, '' if $blank == 1; }
            else          { $blank = 0; push @o, $l; }
        }
        shift @o while @o && $o[0] eq '';   # no leading blank
        my $joined = join("\n", @o);
        return if $joined eq $last_snap;    # skip if nothing changed
        $last_snap = $joined;
        $snap_no++;
        $out .= "\n----- screen $snap_no -----\n";
        $out .= "$_\n" for @o;
    };

    my $put = sub {
        my ($ch) = @_;
        return if $cr < 1;
        $need_row->($cr);
        $grid[$cr-1][$cc-1] = $ch if $cc >= 1 && $cc <= $COLS;
        $cc++;
        $maxrow = $cr if $cr > $maxrow;
    };

    for my $chunk (@$chunks) {
        my ($dir, $data) = @$chunk;

        if ($dir eq '>') {
            # Accumulate typed input across reads and emit whole commands split
            # on the Enter actually pressed. The terminal's cursor-position
            # auto-replies (ESC[<row>;<col>R) travel up this channel too; drop
            # them from the input view (the .hex keeps them).
            $inbuf .= $data;
            while ($inbuf =~ /(.*?)(?:\r\n|\r|\n)/s) {
                my $cmd = $1; my $whole = $&;
                substr($inbuf, 0, length $whole, '');
                $cmd =~ s/\x1b\[[0-9;]*R//g;            # drop cursor-position reports
                next if $cmd eq '';                      # a bare Enter / report-only line
                $dump_screen->();                        # capture the prompt state replied to
                (my $vis = $cmd) =~ s/([^\x20-\x7e])/sprintf('<%02x>', ord $1)/ge;
                $out .= "> $vis\n";
            }
            next;
        }

        # device output: prepend any carried partial escape/IAC, then emulate
        $data = $carry . $data; $carry = '';
        my $i = 0; my $len = length $data;
        while ($i < $len) {
            my $o = ord substr($data, $i, 1);
            if ($o == 0x1b) {                              # ESC
                my $rest = substr($data, $i + 1);
                if ($rest eq '') { $carry = substr($data, $i); last; }          # bare ESC -> carry
                if ($rest =~ /^\[([0-9;?]*)([A-Za-z])/) {                       # complete CSI
                    my ($p, $cmd) = ($1, $2);
                    my @n = split /;/, $p;
                    if    ($cmd eq 'H' || $cmd eq 'f') { $cr = $n[0] || 1; $cc = $n[1] || 1; $need_row->($cr); }
                    elsif ($cmd eq 'J') { if ($p eq '2' || $p eq '') { $dump_screen->(); $reset->(); } }
                    elsif ($cmd eq 'K') { $need_row->($cr); for my $x ($cc .. $COLS) { $grid[$cr-1][$x-1] = ' ' } }
                    elsif ($cmd eq 'A') { $cr -= ($n[0] || 1); $cr = 1 if $cr < 1 }
                    elsif ($cmd eq 'B') { $cr += ($n[0] || 1) }
                    elsif ($cmd eq 'C') { $cc += ($n[0] || 1) }
                    elsif ($cmd eq 'D') { $cc -= ($n[0] || 1); $cc = 1 if $cc < 1 }
                    # r (scroll region), m (SGR colour), h/l (?25 etc) - ignore
                    $i += 1 + 1 + length($p) + 1;
                    next;
                }
                if ($rest =~ /^\[[0-9;?]*$/) { $carry = substr($data, $i); last; } # incomplete CSI -> carry
                if ($rest =~ /^[()][A-Za-z0-9]/) { $i += 3; next; }             # charset select -> skip (4a)
                if ($rest =~ /^[()]$/) { $carry = substr($data, $i); last; }    # incomplete charset -> carry
                if ($rest =~ /^E/) { $cr++; $cc = 1; $need_row->($cr); $maxrow = $cr if $cr > $maxrow; $i += 2; next; }
                if ($rest =~ /^[0-9=>]/) { $i += 2; next; }                     # keypad / other 2-byte
                $i += 2; next;                                                  # unknown ESC x -> skip both
            }
            elsif ($o == 0xff) {                           # telnet IAC -> consume (4c)
                my $rest = substr($data, $i + 1);
                if ($rest eq '') { $carry = substr($data, $i); last; }
                my $cmd = ord substr($rest, 0, 1);
                if ($cmd == 0xfa) {                        # SB ... IAC SE
                    my $se = index($data, chr(0xff) . chr(0xf0), $i + 2);
                    if ($se < 0) { $carry = substr($data, $i); last; }
                    $i = $se + 2; next;
                }
                if ($cmd >= 0xfb && $cmd <= 0xfe) {        # WILL/WONT/DO/DONT opt
                    if (length($rest) < 2) { $carry = substr($data, $i); last; }
                    $i += 3; next;
                }
                $i += 2; next;                             # other 2-byte command
            }
            elsif ($o == 0x0d) { $cc = 1; $i++; next; }               # CR
            elsif ($o == 0x0a) { $cr++; $cc = 1; $need_row->($cr); $maxrow = $cr if $cr > $maxrow; $i++; next; }  # LF
            elsif ($o == 0x08) { $cc-- if $cc > 1; $i++; next; }      # BS
            elsif ($o >= 0x20 && $o < 0x7f) { $put->(substr($data, $i, 1)); $i++; next; }
            else { $i++; next; }                                     # other control: not on screen
        }
    }
    if (length $inbuf) {   # trailing input with no final Enter
        (my $c = $inbuf) =~ s/\x1b\[[0-9;]*R//g;
        if ($c ne '') { $c =~ s/([^\x20-\x7e])/sprintf('<%02x>', ord $1)/ge; $out .= "> $c\n"; }
    }
    $dump_screen->();   # final screen
    return $out;
}

sub hexdump {
    my ($fh, $dir, $data) = @_;
    my $len = length $data;
    for (my $off = 0; $off < $len; $off += 16) {
        my $row = substr($data, $off, 16);
        my @b = map { ord } split //, $row;
        my $hex = join ' ', map { sprintf '%02x', $_ } @b;
        $hex .= '   ' x (16 - @b);
        (my $asc = $row) =~ s/[^\x20-\x7e]/./g;
        printf $fh "%s 0x%05x: %-47s  %s\n", $dir, $off, $hex, $asc;
    }
    print $fh "\n";
}

# mask_literal - same-length masking of known secrets (ssh creds, -m tokens).
# Longest-first is handled by the caller's @secrets ordering.
sub mask_literal {
    my ($s, $secrets) = @_;
    for my $sec (@$secrets) {
        next unless defined $sec && length $sec;
        my $q = quotemeta $sec;
        my $m = 'x' x length $sec;
        $s =~ s/$q/$m/g;
    }
    return $s;
}

# mask_patterns_perline - apply the output-pattern masking one line at a time so
# a greedy \S+ cannot run across a newline, while a secret split across network
# reads (but within one line) is still caught because the caller passes the
# whole reconstructed stream. Same length, line terminators preserved exactly.
sub mask_patterns_perline {
    my ($s) = @_;
    my @parts = split /(\r\n|\n|\r)/, $s, -1;   # even: line content, odd: terminators
    for (my $i = 0; $i < @parts; $i += 2) {
        $parts[$i] = mask_patterns($parts[$i]);
    }
    return join '', @parts;
}

# mask_live - best-effort per-read masking for the LIVE on-screen view only
# (the operator's own session). The saved files are masked line-accurately in
# finalize(); a cross-read leak here affects only the live terminal echo.
sub mask_live {
    my ($s, $secrets, $auto) = @_;
    $s = mask_literal($s, $secrets);
    $s = mask_patterns($s) if $auto;
    return $s;
}

# Best-effort masking of well-known secrets in device OUTPUT; only the
# secret sub-string is replaced, preserving overall length.
sub mask_patterns {
    my ($s) = @_;
    $s =~ s/((?:password|secret)\s+\d+\s+)(\S+)/$1 . ('x' x length $2)/ge;
    $s =~ s/(snmp-server\s+community\s+)(\S+)/$1 . ('x' x length $2)/ge;
    $s =~ s/((?:community|community-string)\s+)(\S+)/$1 . ('x' x length $2)/gei;
    $s =~ s/((?:authentication-key|pre-shared-key|key)\s+["']?)([^"'\s]{4,})/$1 . ('x' x length $2)/gei;
    $s =~ s/((?:\w*-?password|passwd|\w*-?secret)\s+["']?)([^"'\s]{3,})/$1 . ('x' x length $2)/gei;
    $s =~ s/((?:encrypted|hash)\s+)(\S{8,})/$1 . ('x' x length $2)/gei;
    return $s;
}

# Net::Telnet objects are themselves usable filehandles: IO::Select and
# sysread work on the object directly (verified against Net::Telnet 3.x).
sub device_handle {
    my ($t) = @_;
    return $t;
}

my $raw_on = 0;
sub raw_mode_on  { return unless -t STDIN; $raw_on = 1 if system('stty','raw','-echo') == 0; }
sub raw_mode_off { return unless $raw_on; system('stty','sane'); $raw_on = 0; }

sub prompt_plain {
    my ($p) = @_; print STDERR $p; my $v = <STDIN>;
    chomp $v if defined $v; return defined $v ? $v : '';
}
sub prompt_noecho {
    my ($p) = @_; print STDERR $p;
    my $off = (-t STDIN) && system('stty','-echo') == 0;
    my $v = <STDIN>;
    if ($off) { system('stty','echo'); print STDERR "\n"; }
    chomp $v if defined $v; return defined $v ? $v : '';
}

sub uniq { my %s; grep { !$s{$_}++ } @_ }
sub safe { my $x = shift; $x =~ s/[^\w.-]/_/g; $x }

# Local terminal size (cols, rows) for the pty, so a full-screen device
# draws within it. "stty size" prints "rows cols"; fall back to 80x40
# (many menu-driven switches, incl. the ProCurve 8212zl, assume 40 rows).
sub term_size {
    if (-t STDIN) {
        my $s = `stty size 2>/dev/null`;
        if ($s && $s =~ /^\s*(\d+)\s+(\d+)/) {
            my ($rows, $cols) = ($1, $2);
            return ($cols, $rows) if $cols > 0 && $rows > 0;
        }
    }
    return (80, 40);
}

sub usage {
    my ($rc) = @_;
    print STDERR <<'USAGE';
record-session.pl - capture a telnet/SSH device session as a byte-accurate
log for writing a fetchconfig model and unit-test fixtures.

  record-session.pl -h HOST [-t ssh|telnet] [-u USER] [-p PASS] [-o BASE]
                    [-m SECRET]... [--no-auto-secrets] [--timeout N]

  -h, --host HOST       device hostname or IP (HOST:PORT allowed)
  -t, --transport T     ssh (default) or telnet
  -u, --user USER       ssh login username (ssh only; telnet logs in live)
  -p, --password PASS   ssh login password (ssh only; prompted if omitted)
  -o, --output BASE     output basename -> BASE.txt and BASE.hex
  -m, --mask SECRET     exact string to mask, same length; repeatable
                        (use for the enable password, telnet creds,
                        SNMP communities, and any other known secret)
      --no-auto-secrets do not apply the built-in output secret patterns
      --timeout N        per-read timeout, seconds (default 30)
      --help            this help
  -V, --version        print version and copyright, then exit

Enter the enable password at the device's own prompt during the session.
Masking of secrets the DEVICE prints is best effort; review the output.
USAGE
    exit $rc;
}

1;   # modulino: require() returns true (see the "return 1 if caller" guard)
