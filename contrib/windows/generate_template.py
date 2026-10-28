#!/usr/bin/env python3
#
# generate_template.py - part of fetchconfig
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; see the GNU General Public License v2+.
#
# generate_template.py - scaffold a generic-model template (see
# README.generic-model) from a session captured with record-session.
# Python port of generate_template.pl; output is byte-identical apart from
# the tool name in the first comment line.
#
# It reads the .hex file (the byte-accurate record of a real login + show +
# logout), reconstructs the device (<) and input (>) streams in order, and
# proposes a template: the transport-specific login sequence, the learned
# prompt, the show command, and the capture boundaries. It CANNOT know the
# judgment calls a single capture does not reveal (which lines are volatile,
# whether a pager command is needed, menu handling), so it marks those with
# "# TODO" for a human to complete.
#
# THE OUTPUT IS A DRAFT, NOT A FINISHED TEMPLATE. Review it, run it against
# the device with the generic model, and adjust. See README.generic-model.
#
# Usage:
#   generate_template -f SESSION.hex [-t ssh|telnet] [-o OUT.tmpl]
#
#   -f, --hex FILE       the .hex capture from record-session (required)
#   -t, --transport T    ssh or telnet (default: guessed from the capture)
#   -o, --output FILE    write the template here (default: stdout)
#       --help
#   -V, --version        print version and copyright, then exit
#
# Standard library only.
#

import argparse
import re
import sys

# Kept in step with fetchconfig's version by hand, so this tool is
# self-contained and can be copied and run on its own.
VERSION = '9.73'
PROG = 'generate_template'

HEX_LINE = re.compile(rb'^([<>])\s+0x([0-9a-f]+):\s+((?:[0-9a-f]{2}\s?)+)')


def usage(rc):
    sys.stderr.write(
        f"{PROG} - scaffold a generic-model template from a\n"
        "record-session .hex capture. THE OUTPUT IS A DRAFT to review and test.\n"
        "\n"
        f"  {PROG} -f SESSION.hex [-t ssh|telnet] [-o OUT.tmpl]\n"
        "\n"
        "  -f, --hex FILE       the .hex capture (required)\n"
        "  -t, --transport T    ssh or telnet (default: guessed from the capture)\n"
        "  -o, --output FILE    write here (default: stdout)\n"
        "      --help           this help\n"
        "  -V, --version        print version and copyright, then exit\n"
        "\n"
        "See README.generic-model for the template grammar.\n")
    sys.exit(rc)


def die(msg, rc=255):
    sys.stderr.write(msg)
    sys.exit(rc)           # Perl die(): errno if set, else 255


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write(f"{self.prog}: {message}\n")
        usage(2)


def main(argv=None):
    p = _Parser(prog=PROG, add_help=False, allow_abbrev=True)
    p.add_argument('-f', '--hex')
    p.add_argument('-t', '--transport')
    p.add_argument('-o', '--output')
    p.add_argument('--help', action='store_true')
    p.add_argument('-V', '--version', action='store_true')
    opt = p.parse_args(argv)

    if opt.version:
        sys.stdout.write(
            f"{PROG} (fetchconfig) {VERSION}\n"
            "Copyright (c) 2026 Rainer Tammer\n"
            "License GPL-2.0-or-later: GNU GPL version 2 or later.\n"
            "This is free software; see the source for copying conditions. There is NO\n"
            "warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n")
        sys.exit(0)
    if opt.help:
        usage(0)
    if opt.hex is None:
        usage(2)

    # --- read the .hex and reconstruct the two streams ---------------------
    try:
        fh = open(opt.hex, 'rb')
    except OSError as e:
        die(f"cannot read {opt.hex}: {e.strerror}\n", e.errno or 255)
    chunks = []                 # ordered [dir, bytes]
    cur_dir, cur = None, bytearray()
    with fh:
        for line in fh:
            m = HEX_LINE.match(line)
            if not m:
                continue
            d, off = m.group(1), int(m.group(2), 16)
            data = bytes(int(h, 16) for h in re.findall(rb'[0-9a-f]{2}', m.group(3)))
            if off == 0:
                if cur_dir is not None:
                    chunks.append((cur_dir, bytes(cur)))
                cur_dir, cur = d, bytearray(data)
            else:
                cur += data
    if cur_dir is not None:
        chunks.append((cur_dir, bytes(cur)))
    if not chunks:
        die(f"no session data found in {opt.hex}\n")

    dev = b''.join(c for d, c in chunks if d == b'<')
    inp = b''.join(c for d, c in chunks if d == b'>')

    # --- infer the transport -----------------------------------------------
    # telnet capture usually starts with IAC negotiation (0xff) and shows a
    # "Username:"/"Password:" login; an SSH capture starts at the prompt.
    transport = opt.transport
    if transport is None:
        transport = 'telnet' if (b'\xff' in dev or
                                 re.search(rb'Username:|login:', dev, re.I)) else 'ssh'

    # --- infer the prompt --------------------------------------------------
    # The prompt is the token the device repeats before each command. The
    # most common trailing "<host><tail>" is the prompt.
    stripped = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]', b'', dev)   # CSI escapes
    stripped = re.sub(rb'[\x00-\x08\x0b-\x1f\x7f]', b'', stripped)

    prompt_host, prompt_tail = b'', b'#'
    m = re.search(rb'(\S+)([>#])\s*$', stripped)
    if m:
        prompt_host, prompt_tail = m.group(1), m.group(2)
    saw_ansi = b'\x1b[' in dev

    # --- infer the show command (the longest "show ..." the operator typed)
    show_cmd = b'show running-config'
    for line in re.findall(rb'((?:show|write)[^\r\n]*)', inp):
        if len(line) > len(show_cmd) - 4:      # prefer a real one seen
            show_cmd = line

    # bytes -> str 1:1 so the output is byte-identical to the Perl tool
    L = lambda b: b.decode('latin-1')
    host_s, tail_s, show_s = L(prompt_host), L(prompt_tail), L(show_cmd)
    hexname = opt.hex

    # --- emit the template -------------------------------------------------
    entry = f"state state_login_{transport}"
    ansi_word = 'PRESENT' if saw_ansi else 'none'
    strip_ansi = 'yes' if saw_ansi else 'no'
    prompt_head = "'(?:\\\\x1b\\\\[[\\\\d;?]*[A-Za-z])*'" if saw_ansi else "''"

    out = []
    out.append(f"""\
# Generated by {PROG} {VERSION} from {hexname}
# THIS IS A DRAFT - review every line, especially the "# TODO" items, and
# test it against the device with the generic model. See
# README.generic-model.
#
# Inferred: transport={transport}, prompt host="{host_s}" tail="{tail_s}",
#           ANSI/VT100 escapes {ansi_word}.

transport      {transport}
banner_timeout 30
fetch_timeout  120
max_visits     8
strip_ansi     {strip_ansi}

prompt_head    {prompt_head}
prompt_tail    '{tail_s}'

# TODO: add volatile lines to ignore when comparing backups. A single
# capture cannot reveal these - compare two captures taken minutes apart
# and ignore any line that changed on its own (timestamps, re-salted
# hashes). Example:
# ignore  /^! Last configuration change/
#
# ---------------------------------------------------------------------------
# TRIMMING THE TOP OF THE SAVED CONFIG
# The capture includes the echoed command and any preamble the device prints
# before the real config (e.g. "show running-config", "Building
# configuration...", "Running configuration:"). Trim it with:
#
#   capture_from /regex/     same idea but the start is a regex match.
#   skip_first N             drop exactly the first N lines (fixed count).
#
# The number of lines dropped and the final saved line count are logged.
# For Cisco IOS/IOS-XE the config starts at the first "!" line, matching a
# TFTP export:
capture_from  /^!/

""")

    if saw_ansi:
        out.append("""\
# TODO: this looks like a menu/VT100 device. Confirm the interrupt screens
# and their keystrokes from the capture, e.g.:
# interrupt /Press any key to continue/ -> send_nolf " "
# interrupt /Do you want to log out \\[y\\/n\\]/ -> send_nolf "y"

""")

    # login section
    if transport == 'telnet':
        out.append(f"""\
{entry}
    expect /Username: $/   -> send user            -> goto pw_telnet
    expect /Password: $/   -> send_secret pass      -> goto after_login

state pw_telnet
    expect /Password: $/   -> send_secret pass      -> goto after_login

# TODO: if this device drops you into a menu instead of the CLI, add a
# bounded branch here to escape it, e.g.:
#     expect /Main Menu/  -> send_nolf "5" -> goto after_login
state after_login
    expect /(\\S+)[>#]$/   -> send "enable"         -> goto enable
""")
    else:
        out.append(f"""\
# SSH is already authenticated; match the first prompt and send enable.
{entry}
    expect /(\\S+)[>#]$/   -> send "enable"         -> goto enable
""")

    out.append(f"""\

# response to "enable": a Password: prompt, or (already enabled) the prompt.
state enable
    expect /Password: $/   -> send_secret enable    -> goto pager
    expect prompt          -> send "term len 0"      -> goto show

# response to the enable password is the prompt; send the pager-off command.
# TODO: confirm the pager command for this device ("term len 0" is Cisco;
# ProCurve uses "no page"; others differ - or remove this state if none).
state pager
    expect prompt          -> send "term len 0"      -> goto show

# send the show command captured from the session
state show
    expect prompt          -> send "{show_s}" -> goto capture

# capture the configuration (text between the show command and the prompt)
state capture
    capture_start
    expect prompt          -> capture_stop           -> goto logout

# already at the prompt: send exit without waiting
state logout
    send "exit" -> done
""")

    data = ''.join(out).encode('latin-1', 'replace')
    if opt.output is not None:
        try:
            with open(opt.output, 'wb') as fo:
                fo.write(data)
        except OSError as e:
            die(f"cannot write {opt.output}: {e.strerror}\n")
        sys.stderr.write(f"Wrote {opt.output} (a DRAFT - review the TODO items and test it).\n")
    else:
        sys.stdout.flush()
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main())
