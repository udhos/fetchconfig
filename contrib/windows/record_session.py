#!/usr/bin/env python3
#
# record_session.py - part of fetchconfig
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
# record_session.py - capture a telnet or SSH session with a network device
# as a byte-accurate log, for writing a new fetchconfig model and for unit
# test fixtures. Python port of record-session.pl; runs on Windows (native
# console, no PuTTY/OpenSSH needed) and POSIX. Same CLI, same file formats.
#
# Transports: telnet is a built-in minimal client (RFC 854 option handling:
# accepts remote ECHO/SGA, offers TTYPE/NAWS, refuses the rest); ssh uses
# paramiko with an interactive pty sized to the local console. The tool
# hands you a live interactive session and tees both directions to:
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
#   <output>.hex   an offset + hex + ASCII dump of the EXACT bytes received
#                  (telnet: including IAC negotiation), in the PuTTY "all
#                  session output" style this project parses. One dump block
#                  per network read. This is the authoritative record for
#                  building a model; the .txt is a readability aid.
#
# CREDENTIALS
#   ssh     : -u/--user and -p/--password provide the login (SSH
#             authenticates before the shell starts). If -p is omitted it
#             is prompted for, without echo. password and keyboard-
#             interactive auth are tried; keys and agents are not used.
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
#   - after the device prints a "Password:"-style prompt, every printable
#     byte in both directions is masked until Enter;
#   - a best-effort set of patterns masks well-known secrets the DEVICE
#     prints (Cisco "password 7 ...", "secret 5 ...", "snmp-server
#     community X", keys), replaced with same-length "x".
#
# Masking is applied on LINE boundaries: reads are held back until a read
# ends a line, the direction changes, or the stream is idle for 2 s,
# then masked as one buffer and written back with the original read
# boundaries. A secret split across two network reads is masked as a whole.
#
# Masking of hashes/communities/keys in device output is BEST EFFORT and
# WILL MISS THINGS. Review both files before sharing them. The tool prints
# this reminder when it finishes.
#
# Usage:
#   record-session -h HOST [-t ssh|telnet] [-u USER] [-p PASS]
#                  [-o BASE] [-m SECRET]... [--no-auto-secrets]
#                  [--timeout N]
#
# Requires paramiko (ssh only). Standard library otherwise.
#

import argparse
import os
import re
import select
import signal
import socket
import sys
import time

VERSION = '9.73'
PROG = 'record-session'
IS_WIN = (os.name == 'nt')
TERM_TYPE = 'xterm'
IDLE_FLUSH = 2.0           # seconds idle before an unterminated read is recorded
POLL = 0.01                # console poll interval, seconds


def die(msg, rc=255):
    sys.stderr.write(msg)
    sys.exit(rc)


def to_bytes(s):
    """Command-line / prompted text -> the bytes it travels as."""
    return s.encode('utf-8') if IS_WIN else os.fsencode(s)


# =========================================================================
# masking

_MASK_PATTERNS = [
    re.compile(rb'((?:password|secret)\s+\d+\s+)(\S+)'),
    re.compile(rb'(snmp-server\s+community\s+)(\S+)'),
    re.compile(rb'((?:community|community-string)\s+)(\S+)', re.I),
    re.compile(rb'((?:authentication-key|pre-shared-key|key)\s+["\']?)([^"\'\s]{4,})', re.I),
    re.compile(rb'((?:\w*-?password|passwd|\w*-?secret)\s+["\']?)([^"\'\s]{3,})', re.I),
    re.compile(rb'((?:encrypted|hash)\s+)(\S{8,})', re.I),
]


def _x_group2(m):
    return m.group(1) + b'x' * len(m.group(2))


class Masker:
    def __init__(self, secrets, auto):
        self.secrets = secrets          # bytes, longest first
        self.auto = auto

    def mask(self, data):
        """Same-length masking of known secrets and built-in output patterns."""
        for s in self.secrets:
            data = data.replace(s, b'x' * len(s))
        if self.auto:
            for pat in _MASK_PATTERNS:
                data = pat.sub(_x_group2, data)
        return data


# =========================================================================
# recording: line-buffered, read boundaries preserved

_PW_STRIP = [
    re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]'),     # CSI sequences
    re.compile(rb'\x1b[()][A-Za-z0-9]'),        # charset selects
    re.compile(rb'\x1b[A-Za-z0-9=>]'),          # other 2-byte escapes
    re.compile(rb'[\x00-\x08\x0b-\x1f\x7f]'),   # remaining control bytes
]
_PW_PROMPT = re.compile(rb'password\s*[:#>]$', re.I)


def hexdump(fh, d, data):
    for off in range(0, len(data), 16):
        row = data[off:off + 16]
        hx = ' '.join('%02x' % b for b in row) + '   ' * (16 - len(row))
        asc = bytes(b if 0x20 <= b <= 0x7e else 0x2e for b in row)
        fh.write(b'%s 0x%05x: %-47s  %s\n' % (d, off, hx.encode('ascii'), asc))
    fh.write(b'\n')
    fh.flush()


class Recorder:
    """Writes the .hex live and keeps the ordered transcript for the .txt.

    Reads are queued per direction and released as a group when a read ends
    a line, the direction changes, or the stream goes idle. The group is
    masked as one buffer (so split secrets are caught) and dumped with the
    original read boundaries (same-length masking keeps them aligned).
    """

    def __init__(self, hexfh, masker):
        self.hex = hexfh
        self.masker = masker
        self.xcript = []        # ordered (dir, bytes) chunks
        self.pw_mode = False
        self.pw_raw = b''       # rolling raw device tail, split-safe prompt detection
        self._dir = None
        self._pend = []
        self._t = 0.0

    def add(self, d, data):
        if self._pend and self._dir != d:
            self.flush()
        self._dir = d
        self._pend.append(data)
        self._t = time.monotonic()
        if data[-1:] in (b'\n', b'\r'):
            self.flush()

    def tick(self):
        if self._pend and time.monotonic() - self._t >= IDLE_FLUSH:
            self.flush()

    def flush(self):
        if not self._pend:
            return
        d, chunks = self._dir, self._pend
        self._pend = []
        work = []
        for c in chunks:
            if self.pw_mode:
                c = self._pw_mask(c)
            work.append(c)
            if d == b'<':
                self._pw_detect(c)
        masked = self.masker.mask(b''.join(work))
        pos = 0
        for c in work:
            piece = masked[pos:pos + len(c)]
            pos += len(c)
            hexdump(self.hex, d, piece)
            self.xcript.append((d, piece))

    # Password prompt masking. When the device output ends with a
    # "Password:"-style prompt, the NEXT thing typed is a secret the tool has
    # no other way to know (telnet login / enable passwords are typed live):
    # mask every printable byte - input and any echo of it - until Enter.
    def _pw_mask(self, data):
        out = bytearray(data)
        for i, b in enumerate(out):
            if b in (0x0d, 0x0a):
                self.pw_mode = False
                break
            if 0x20 <= b < 0x7f:
                out[i] = 0x78                   # 'x', same length
        return bytes(out)

    # Arm password mode on the visible tail of the device stream. Escapes
    # split across reads are completed once their other half arrives.
    def _pw_detect(self, data):
        self.pw_raw = (self.pw_raw + data)[-200:]
        vis = self.pw_raw
        for pat in _PW_STRIP:
            vis = pat.sub(b'', vis)
        vis = vis.rstrip(b' \t\r\n\x0b\x0c')
        if _PW_PROMPT.search(vis):
            self.pw_mode = True


# =========================================================================
# telnet

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
OPT_ECHO, OPT_SGA, OPT_TTYPE, OPT_NAWS = 1, 3, 24, 31


class TelnetParser:
    """Stateful RFC 854 decoder. feed() returns the data bytes; option
    requests are answered through reply() when one is given."""

    def __init__(self, reply=None, term=TERM_TYPE, size=(80, 24)):
        self.reply = reply
        self.term = term.upper().encode('ascii')
        self.size = size
        self.st = 0             # 0 data, 1 IAC, 2 option, 3 SB, 4 SB+IAC
        self.cmd = 0
        self.sb = bytearray()
        self.him = {}           # remote options enabled
        self.us = {}            # local options enabled

    def feed(self, data):
        out = bytearray()
        for b in data:
            st = self.st
            if st == 0:
                if b == IAC:
                    self.st = 1
                else:
                    out.append(b)
            elif st == 1:
                if b == IAC:
                    out.append(IAC)
                    self.st = 0
                elif b in (WILL, WONT, DO, DONT):
                    self.cmd = b
                    self.st = 2
                elif b == SB:
                    self.sb = bytearray()
                    self.st = 3
                else:
                    self.st = 0     # NOP, GA, DM, ... : no data
            elif st == 2:
                self._option(self.cmd, b)
                self.st = 0
            elif st == 3:
                if b == IAC:
                    self.st = 4
                else:
                    self.sb.append(b)
            else:
                if b == SE:
                    self._subneg(bytes(self.sb))
                    self.st = 0
                elif b == IAC:
                    self.sb.append(IAC)
                    self.st = 3
                else:
                    self.st = 0
        return bytes(out)

    def _send(self, data):
        if self.reply:
            self.reply(data)

    def _option(self, cmd, opt):
        if cmd == WILL:
            if opt in (OPT_ECHO, OPT_SGA):
                if not self.him.get(opt):
                    self.him[opt] = True
                    self._send(bytes((IAC, DO, opt)))
            else:
                self._send(bytes((IAC, DONT, opt)))
        elif cmd == WONT:
            if self.him.get(opt):
                self.him[opt] = False
                self._send(bytes((IAC, DONT, opt)))
        elif cmd == DO:
            if opt in (OPT_TTYPE, OPT_NAWS, OPT_SGA):
                if not self.us.get(opt):
                    self.us[opt] = True
                    self._send(bytes((IAC, WILL, opt)))
                if opt == OPT_NAWS:
                    self._naws()
            else:
                self._send(bytes((IAC, WONT, opt)))
        elif cmd == DONT:
            if self.us.get(opt):
                self.us[opt] = False
                self._send(bytes((IAC, WONT, opt)))

    def _subneg(self, sb):
        if sb[:2] == bytes((OPT_TTYPE, 1)) and self.us.get(OPT_TTYPE):     # SEND
            self._send(bytes((IAC, SB, OPT_TTYPE, 0)) + self.term + bytes((IAC, SE)))

    def _naws(self):
        cols, rows = self.size
        p = bytes((cols >> 8 & 255, cols & 255, rows >> 8 & 255, rows & 255))
        p = p.replace(b'\xff', b'\xff\xff')
        self._send(bytes((IAC, SB, OPT_NAWS)) + p + bytes((IAC, SE)))


class TelnetConn:
    def __init__(self, host, port, timeout, size):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(None)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.parser = TelnetParser(reply=self.sock.sendall, size=size)

    def read(self):
        """(raw, display) if data, None if nothing pending, (b'', b'') at EOF."""
        r, _, _ = select.select([self.sock], [], [], 0)
        if not r:
            return None
        try:
            raw = self.sock.recv(4096)
        except OSError:
            raw = b''
        if not raw:
            return b'', b''
        return raw, self.parser.feed(raw)

    def write(self, data):
        self.sock.sendall(data.replace(b'\xff', b'\xff\xff'))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# =========================================================================
# ssh

class SSHConn:
    def __init__(self, host, port, user, password, timeout, size):
        import logging
        import warnings
        warnings.filterwarnings('ignore')          # cryptography deprecations (3DES, SHA1)
        logging.getLogger('paramiko').setLevel(logging.CRITICAL + 1)
        import paramiko
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            self.client.connect(host, port=port, username=user, password=password,
                                timeout=timeout, banner_timeout=timeout,
                                auth_timeout=timeout, look_for_keys=False,
                                allow_agent=False)
        except paramiko.AuthenticationException as e:
            raise ConnectionError(f"authentication failed ({e})") from None
        except paramiko.SSHException as e:
            raise ConnectionError(str(e)) from None
        cols, rows = size
        self.chan = self.client.invoke_shell(term=TERM_TYPE, width=cols, height=rows)
        self.chan.settimeout(0.0)

    def read(self):
        if self.chan.recv_ready():
            try:
                raw = self.chan.recv(4096)
            except OSError:
                raw = b''
            return raw, raw
        if self.chan.closed or self.chan.eof_received or self.chan.exit_status_ready():
            return b'', b''
        return None

    def write(self, data):
        self.chan.settimeout(None)
        try:
            self.chan.sendall(data)
        finally:
            self.chan.settimeout(0.0)

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass


# =========================================================================
# local console

def term_size():
    """Local console (cols, rows) for the pty/NAWS; 80x40 fallback
    (many menu-driven switches, incl. the ProCurve 8212zl, assume 40 rows)."""
    for f in (sys.stdout, sys.stdin, sys.stderr):
        try:
            c, r = os.get_terminal_size(f.fileno())
            if c > 0 and r > 0:
                return c, r
        except (OSError, ValueError, AttributeError):
            pass
    return 80, 40


class _StdoutWriter:
    """Device output to the local screen, without newline translation."""

    def __init__(self):
        self.out = sys.stdout.buffer
        self.utf8 = IS_WIN and sys.stdout.isatty()
        if self.utf8:
            import codecs
            self.dec = codecs.getincrementaldecoder('utf-8')('replace')

    def write(self, data):
        if not data:
            return
        if self.utf8:           # console wants complete UTF-8 sequences
            data = self.dec.decode(data).encode('utf-8')
            if not data:
                return
        self.out.write(data)
        self.out.flush()


class PosixConsole:
    def __init__(self):
        self.fd = sys.stdin.fileno()
        self.tty = os.isatty(self.fd)
        self.saved = None
        self.screen = _StdoutWriter()

    def raw_on(self):
        if self.tty:
            import termios
            import tty
            self.saved = termios.tcgetattr(self.fd)
            tty.setraw(self.fd)

    def raw_off(self):
        if self.saved is not None:
            import termios
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)
            self.saved = None

    def read(self, timeout):
        """bytes typed (b'' if none), None at EOF."""
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return b''
        data = os.read(self.fd, 4096)
        return data if data else None


class _PipeReader:
    """stdin that is not a console (redirected): blocking reads in a thread."""

    def __init__(self):
        import queue
        import threading
        self.q = queue.Queue()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        src = sys.stdin.buffer.raw if hasattr(sys.stdin.buffer, 'raw') else sys.stdin.buffer
        while True:
            try:
                d = src.read(4096)
            except OSError:
                d = b''
            self.q.put(d if d else None)
            if not d:
                return

    def read(self, timeout):
        import queue
        try:
            d = self.q.get(timeout=timeout)
        except queue.Empty:
            return b''
        if d is None:
            return None
        out = [d]
        while True:                     # coalesce what is already queued
            try:
                d = self.q.get_nowait()
            except queue.Empty:
                break
            if d is None:
                self.q.put(None)
                break
            out.append(d)
        return b''.join(out)


if IS_WIN:
    import ctypes
    from ctypes import wintypes

    _k32 = ctypes.WinDLL('kernel32', use_last_error=True)

    class _KEY_EVENT_RECORD(ctypes.Structure):
        _fields_ = [('bKeyDown', wintypes.BOOL),
                    ('wRepeatCount', wintypes.WORD),
                    ('wVirtualKeyCode', wintypes.WORD),
                    ('wVirtualScanCode', wintypes.WORD),
                    ('UnicodeChar', wintypes.WORD),
                    ('dwControlKeyState', wintypes.DWORD)]

    class _EVENT(ctypes.Union):
        _fields_ = [('KeyEvent', _KEY_EVENT_RECORD), ('_pad', ctypes.c_byte * 16)]

    class _INPUT_RECORD(ctypes.Structure):
        _fields_ = [('EventType', wintypes.WORD), ('Event', _EVENT)]

    _k32.GetStdHandle.restype = wintypes.HANDLE
    _k32.GetStdHandle.argtypes = [wintypes.DWORD]
    _k32.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    _k32.SetConsoleMode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    _k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    _k32.WaitForSingleObject.restype = wintypes.DWORD
    _k32.GetNumberOfConsoleInputEvents.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    _k32.ReadConsoleInputW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_INPUT_RECORD),
                                       wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]

    _STD_INPUT, _STD_OUTPUT = wintypes.DWORD(-10 & 0xFFFFFFFF), wintypes.DWORD(-11 & 0xFFFFFFFF)
    _KEY_EVENT = 0x0001
    _IN_PROCESSED, _IN_LINE, _IN_ECHO, _IN_VT = 0x0001, 0x0002, 0x0004, 0x0200
    _OUT_PROCESSED, _OUT_VT, _OUT_NO_AUTO_CR = 0x0001, 0x0004, 0x0008
    _RIGHT_ALT, _LEFT_ALT, _RIGHT_CTRL, _LEFT_CTRL = 0x01, 0x02, 0x04, 0x08

    # special keys -> xterm sequences (normal cursor-key mode)
    _VK_SEQ = {
        0x26: b'\x1b[A', 0x28: b'\x1b[B', 0x27: b'\x1b[C', 0x25: b'\x1b[D',   # arrows
        0x24: b'\x1b[H', 0x23: b'\x1b[F',                                     # Home End
        0x2D: b'\x1b[2~', 0x2E: b'\x1b[3~', 0x21: b'\x1b[5~', 0x22: b'\x1b[6~',
        0x70: b'\x1bOP', 0x71: b'\x1bOQ', 0x72: b'\x1bOR', 0x73: b'\x1bOS',   # F1-F4
        0x74: b'\x1b[15~', 0x75: b'\x1b[17~', 0x76: b'\x1b[18~', 0x77: b'\x1b[19~',
        0x78: b'\x1b[20~', 0x79: b'\x1b[21~', 0x7A: b'\x1b[23~', 0x7B: b'\x1b[24~',
    }
    _VK_BACK = 0x08

    class WinConsole:
        """Raw keyboard input via ReadConsoleInputW, VT output via the
        console's own VT100 engine. Falls back to a pipe reader when stdin
        is redirected."""

        def __init__(self):
            self.hin = _k32.GetStdHandle(_STD_INPUT)
            self.hout = _k32.GetStdHandle(_STD_OUTPUT)
            m = wintypes.DWORD()
            self.is_console = bool(_k32.GetConsoleMode(self.hin, ctypes.byref(m)))
            self.in_mode = m.value if self.is_console else None
            m2 = wintypes.DWORD()
            self.out_mode = m2.value if _k32.GetConsoleMode(self.hout, ctypes.byref(m2)) else None
            self.pipe = None if self.is_console else _PipeReader()
            self.screen = _StdoutWriter()
            self.buf = (_INPUT_RECORD * 256)()
            self.hi_surrogate = None
            self.raw = False

        def raw_on(self):
            if self.out_mode is not None:
                want = self.out_mode | _OUT_PROCESSED | _OUT_VT | _OUT_NO_AUTO_CR
                if not _k32.SetConsoleMode(self.hout, want):
                    _k32.SetConsoleMode(self.hout, self.out_mode | _OUT_PROCESSED | _OUT_VT)
            if self.is_console:
                want = self.in_mode & ~(_IN_PROCESSED | _IN_LINE | _IN_ECHO | _IN_VT)
                _k32.SetConsoleMode(self.hin, want)
            self.raw = True

        def raw_off(self):
            if not self.raw:
                return
            if self.out_mode is not None:
                _k32.SetConsoleMode(self.hout, self.out_mode)
            if self.is_console:
                _k32.SetConsoleMode(self.hin, self.in_mode)
            self.raw = False

        def read(self, timeout):
            if self.pipe:
                return self.pipe.read(timeout)
            if _k32.WaitForSingleObject(self.hin, int(timeout * 1000)) != 0:
                return b''
            n = wintypes.DWORD()
            if not _k32.GetNumberOfConsoleInputEvents(self.hin, ctypes.byref(n)) or not n.value:
                return b''
            got = wintypes.DWORD()
            if not _k32.ReadConsoleInputW(self.hin, self.buf, min(n.value, 256), ctypes.byref(got)):
                return None
            out = bytearray()
            for i in range(got.value):
                rec = self.buf[i]
                if rec.EventType != _KEY_EVENT:
                    continue
                k = rec.Event.KeyEvent
                if not k.bKeyDown:
                    continue
                out += self._key(k) * max(1, k.wRepeatCount)
            return bytes(out)

        def _key(self, k):
            vk, ch, st = k.wVirtualKeyCode, k.UnicodeChar, k.dwControlKeyState
            if vk in _VK_SEQ:
                return _VK_SEQ[vk]
            if vk == _VK_BACK:
                return b'\x7f'                  # like a Linux terminal / PuTTY
            if not ch:
                return b''                      # bare modifier etc.
            if 0xD800 <= ch <= 0xDBFF:          # surrogate pair, first half
                self.hi_surrogate = ch
                return b''
            if 0xDC00 <= ch <= 0xDFFF and self.hi_surrogate is not None:
                s = chr(0x10000 + ((self.hi_surrogate - 0xD800) << 10) + (ch - 0xDC00))
                self.hi_surrogate = None
            else:
                s = chr(ch)
            b = s.encode('utf-8', 'replace')
            # Left Alt alone = Meta (ESC prefix); AltGr reports Ctrl+Alt and is left alone
            if st & _LEFT_ALT and not st & (_RIGHT_ALT | _LEFT_CTRL | _RIGHT_CTRL):
                b = b'\x1b' + b
            return b

    Console = WinConsole
else:
    Console = PosixConsole


def prompt_plain(p):
    sys.stderr.write(p)
    sys.stderr.flush()
    v = sys.stdin.readline()
    return v.rstrip('\r\n')


def prompt_noecho(p):
    import getpass
    try:
        return getpass.getpass(p, stream=sys.stderr)
    except EOFError:
        return ''


# =========================================================================
# .txt render

def _perl_arg(n, i, default):
    """Perl "$n[i] || default" followed by numeric use."""
    s = n[i] if i < len(n) else ''
    if s in (b'', b'0'):
        return default
    m = re.match(rb'\s*([+-]?\d+)', s)
    return int(m.group(1)) if m else 0


_CSI = re.compile(rb'\[([0-9;?]*)([A-Za-z])')
_CHARSET = re.compile(rb'[()][A-Za-z0-9]')
_EOL = re.compile(rb'(.*?)(?:\r\n|\r|\n)', re.S)
_CPR = re.compile(rb'\x1b\[[0-9;]*R')
_NONPRINT = re.compile(rb'[^\x20-\x7e]')


def _vis(b):
    return _NONPRINT.sub(lambda m: b'<%02x>' % m.group(0)[0], b)


def render_txt(txt, xcript, telnet):
    """Write the human-readable .txt from the whole session.

    The device stream is replayed through a small VT100/ANSI screen emulator
    (a 2D character grid + cursor). A snapshot of the screen is written
    whenever the device clears it (ESC[2J) and at the end, so the sequence of
    screens is preserved. Typed input is shown as "> <command>" lines in the
    order it was sent. A line-oriented device (Cisco IOS etc.) has no cursor
    moves, so the emulator degenerates to a line-by-line transcript.
    Consecutive device reads are joined first so an escape sequence split
    across reads is parsed whole; telnet IAC negotiation is removed.
    """
    COLS = 200
    grid = []
    st = {'cr': 1, 'cc': 1, 'max': 1, 'snap': 0, 'last': None}

    def reset():
        grid.clear()
        st['cr'], st['cc'], st['max'] = 1, 1, 1

    def need_row(r):
        while len(grid) < r:
            grid.append(bytearray(b' ' * COLS))

    def dump_screen():
        rows = []
        for r in range(st['max']):
            rows.append(bytes(grid[r]).rstrip() if r < len(grid) else b'')
        while rows and rows[-1] == b'':
            rows.pop()
        if not rows:
            return
        # collapse an interior run of >1 blank line to a single blank line
        out, blank = [], 0
        for line in rows:
            if line == b'':
                blank += 1
                if blank == 1:
                    out.append(b'')
            else:
                blank = 0
                out.append(line)
        while out and out[0] == b'':
            out.pop(0)
        joined = b'\n'.join(out)
        if joined == st['last']:
            return
        st['last'] = joined
        st['snap'] += 1
        txt.write(b'\n----- screen %d -----\n' % st['snap'])
        for line in out:
            txt.write(line + b'\n')

    def put(ch):
        cr, cc = st['cr'], st['cc']
        if cr < 1:
            return
        need_row(cr)
        if 1 <= cc <= COLS:
            grid[cr - 1][cc - 1] = ch
        st['cc'] = cc + 1
        if cr > st['max']:
            st['max'] = cr

    def newline_down():
        st['cr'] += 1
        st['cc'] = 1
        need_row(st['cr'])
        if st['cr'] > st['max']:
            st['max'] = st['cr']

    txt.write(b'\n# The screens below are an ANSI/VT100 emulation of the device output,\n'
              b'# for readability (menu-driven devices are cursor-addressed). The .hex\n'
              b'# file holds the exact bytes. Typed input is shown as "> ..." lines.\n')

    # join consecutive device reads
    segs = []
    for d, data in xcript:
        if d == b'<' and segs and segs[-1][0] == b'<':
            segs[-1][1].extend(data)
        else:
            segs.append([d, bytearray(data)])

    tp = TelnetParser() if telnet else None
    reset()
    inbuf = b''
    for d, data in segs:
        data = bytes(data)
        if d == b'>':
            # Emit whole commands split on the Enter actually pressed. Cursor
            # position reports (ESC[<row>;<col>R) the terminal sends back are
            # dropped here (the .hex keeps them); other escapes are shown.
            inbuf += data
            while True:
                m = _EOL.match(inbuf)
                if not m:
                    break
                cmd = m.group(1)
                inbuf = inbuf[m.end():]
                cmd = _CPR.sub(b'', cmd)
                if cmd == b'':
                    continue
                dump_screen()               # the prompt state you replied to
                txt.write(b'> ' + _vis(cmd) + b'\n')
            continue

        if tp:
            data = tp.feed(data)
        i, n = 0, len(data)
        while i < n:
            o = data[i]
            if o == 0x1b:
                m = _CSI.match(data, i + 1)
                if m:
                    p, cmd = m.group(1), m.group(2)
                    a = p.split(b';') if p else []
                    while a and a[-1] == b'':       # Perl split drops trailing empties
                        a.pop()
                    if cmd in (b'H', b'f'):
                        st['cr'] = _perl_arg(a, 0, 1)
                        st['cc'] = _perl_arg(a, 1, 1)
                        need_row(st['cr'])
                    elif cmd == b'J':
                        if p in (b'2', b''):
                            dump_screen()
                            reset()
                    elif cmd == b'K':
                        if st['cr'] >= 1:
                            need_row(st['cr'])
                            row = grid[st['cr'] - 1]
                            for x in range(max(st['cc'], 1), COLS + 1):
                                row[x - 1] = 0x20
                    elif cmd == b'A':
                        st['cr'] = max(1, st['cr'] - _perl_arg(a, 0, 1))
                    elif cmd == b'B':
                        st['cr'] += _perl_arg(a, 0, 1)
                    elif cmd == b'C':
                        st['cc'] += _perl_arg(a, 0, 1)
                    elif cmd == b'D':
                        st['cc'] = max(1, st['cc'] - _perl_arg(a, 0, 1))
                    # r (scroll region), m (SGR colour), h/l (?25 etc) - ignore
                    i = m.end()
                    continue
                nxt = data[i + 1:i + 2]
                if nxt == b'E':
                    newline_down()
                    i += 2
                elif nxt and nxt in b'0123456789=>':
                    i += 2
                elif _CHARSET.match(data, i + 1):
                    i += 3
                else:
                    i += 1
            elif o == 0x0d:
                st['cc'] = 1
                i += 1
            elif o == 0x0a:
                newline_down()
                i += 1
            elif o == 0x08:
                if st['cc'] > 1:
                    st['cc'] -= 1
                i += 1
            elif 0x20 <= o < 0x7f:
                put(o)
                i += 1
            else:
                i += 1                              # other control: not on screen
    if inbuf:                                       # trailing input with no final Enter
        c = _CPR.sub(b'', inbuf)
        if c != b'':
            txt.write(b'> ' + _vis(c) + b'\n')
    dump_screen()                                   # final screen
    txt.flush()


# =========================================================================
# main

def usage(rc):
    end_key = "Ctrl-] (German keyboard: Strg-+) or Ctrl-Break" if IS_WIN else "Ctrl-]"
    sys.stderr.write(
        f"{PROG} - capture a telnet/SSH device session as a byte-accurate\n"
        "log for writing a fetchconfig model and unit-test fixtures.\n"
        "\n"
        f"  {PROG} -h HOST [-t ssh|telnet] [-u USER] [-p PASS] [-o BASE]\n"
        "                 [-m SECRET]... [--no-auto-secrets] [--timeout N]\n"
        "\n"
        "  -h, --host HOST       device hostname or IP (HOST:PORT allowed)\n"
        "  -t, --transport T     ssh (default) or telnet\n"
        "  -u, --user USER       ssh login username (ssh only; telnet logs in live)\n"
        "  -p, --password PASS   ssh login password (ssh only; prompted if omitted)\n"
        "  -o, --output BASE     output basename -> BASE.txt and BASE.hex\n"
        "  -m, --mask SECRET     exact string to mask, same length; repeatable\n"
        "                        (use for the enable password, telnet creds,\n"
        "                        SNMP communities, and any other known secret)\n"
        "      --no-auto-secrets do not apply the built-in output secret patterns\n"
        "      --timeout N       connect timeout, seconds (default 30)\n"
        "      --help            this help\n"
        "  -V, --version         print version and copyright, then exit\n"
        "\n"
        f"End the session with exit/logout on the device, or {end_key}.\n"
        "Enter the enable password at the device's own prompt during the session.\n"
        "Masking of secrets the DEVICE prints is best effort; review the output.\n")
    sys.exit(rc)


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        sys.stderr.write(f"{self.prog}: {message}\n")
        usage(2)


def _safe(x):
    return re.sub(r'[^\w.-]', '_', x, flags=re.ASCII)


def _stamp():
    import datetime
    now = datetime.datetime.now().astimezone()
    tz = now.strftime('%Z')
    if IS_WIN or not tz or not tz.isascii() or ' ' in tz:
        tz = now.strftime('%z')         # Windows zone names are long and localised
    return now.strftime('%Y-%m-%d %H:%M:%S ') + tz


def main(argv=None):
    p = _Parser(prog=PROG, add_help=False)
    p.add_argument('-h', '--host')
    p.add_argument('-t', '--transport', default='ssh')
    p.add_argument('-u', '--user')
    p.add_argument('-p', '--password')
    p.add_argument('-o', '--output')
    p.add_argument('-m', '--mask', action='append', default=[])
    p.add_argument('--no-auto-secrets', dest='auto_secrets', action='store_false')
    p.add_argument('--timeout', type=int, default=30)
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
        return 0
    if opt.help:
        usage(0)
    if opt.host is None:
        usage(2)

    transport = opt.transport.lower()
    if transport not in ('ssh', 'telnet'):
        die("transport must be 'ssh' or 'telnet'\n")

    host, port = opt.host, None
    m = re.match(r'^(.+):(\d+)$', opt.host, re.S)
    if m:
        host, port = m.group(1), int(m.group(2))

    # --- credentials -----------------------------------------------------
    user = password = None
    if transport == 'ssh':
        user = opt.user if opt.user is not None else prompt_plain("SSH username: ")
        password = opt.password if opt.password is not None else prompt_noecho("SSH password: ")
        if not user:
            die("ssh needs a username (use -u)\n")
    # telnet: login typed live at the device prompts; nothing collected here.

    # Secrets the tool knows and can mask automatically (ssh credentials) +
    # -m tokens. Longest first so a longer secret masks before a shorter
    # substring of it.
    sec = ([password, user] if transport == 'ssh' else []) + list(opt.mask)
    seen, secrets = set(), []
    for s in sec:
        if s:
            b = to_bytes(s)
            if b not in seen:
                seen.add(b)
                secrets.append(b)
    secrets.sort(key=len, reverse=True)
    masker = Masker(secrets, opt.auto_secrets)

    # --- output files ----------------------------------------------------
    base = opt.output if opt.output is not None else \
        'session-%s-%s' % (_safe(opt.host), time.strftime('%Y%m%d-%H%M%S'))
    try:
        TXT = open(f"{base}.txt", 'wb')
    except OSError as e:
        die(f"cannot write {base}.txt: {e.strerror}\n")
    try:
        HEX = open(f"{base}.hex", 'wb')
    except OSError as e:
        die(f"cannot write {base}.hex: {e.strerror}\n")

    header = (f"# {PROG}  host={opt.host}  transport={transport}  {_stamp()}\n"
              "# masking (same length): "
              + ("ssh user/pass" if transport == 'ssh' else "none automatic (telnet)")
              + (f" + {len(opt.mask)} -m token(s)" if opt.mask else "")
              + (" + built-in output patterns" if opt.auto_secrets else "")
              + "\n# BEST EFFORT - review before sharing\n").encode('utf-8', 'replace')
    TXT.write(header)
    TXT.flush()
    HEX.write(header)
    HEX.flush()

    # --- connect ---------------------------------------------------------
    con = Console()
    size = term_size()
    try:
        if transport == 'telnet':
            dev = TelnetConn(host, port if port is not None else 23, opt.timeout, size)
        else:
            dev = SSHConn(host, port if port is not None else 22, user, password,
                          opt.timeout, size)
    except (OSError, ConnectionError, EOFError) as e:
        die(f"could not connect ({transport}): {e}\n")

    end_key = "Ctrl-] (Strg-+ on a German keyboard)" if IS_WIN else "Ctrl-]"
    sys.stderr.write(
        f"Connected to {opt.host} ({transport}).\n"
        + ("Log in at the prompts below. " if transport == 'telnet' else "")
        + f"Type commands; end with 'exit'/'logout' or {end_key}.\n"
        "Enter the enable password at the device's own prompt when needed.\n\n")
    sys.stderr.flush()

    # --- interactive relay, line-buffered recording ----------------------
    rec = Recorder(HEX, masker)
    state = {'done': False}

    def _stop(*_):
        state['done'] = True
    for sig in ('SIGINT', 'SIGTERM', 'SIGBREAK'):
        if hasattr(signal, sig):
            try:
                signal.signal(getattr(signal, sig), _stop)
            except (OSError, ValueError):
                pass

    con.raw_on()
    try:
        stdin_open = True
        while not state['done']:
            if stdin_open:
                data = con.read(POLL)
                if data is None:
                    # local input closed (EOF / redirected input exhausted):
                    # stop watching it, keep draining the device.
                    stdin_open = False
                elif data:
                    i = data.find(b'\x1d')          # Ctrl-]
                    if i >= 0:
                        data = data[:i]
                        state['done'] = True
                    if data:
                        dev.write(data)
                        rec.add(b'>', data)
            else:
                time.sleep(POLL)
            for _ in range(64):
                r = dev.read()
                if r is None:
                    break
                raw, shown = r
                if not raw:                         # device closed -> end
                    state['done'] = True
                    break
                con.screen.write(masker.mask(shown))
                rec.add(b'<', raw)
            rec.tick()
    except Exception as e:
        con.raw_off()
        sys.stderr.write(f"session error: {e}\n")

    rec.flush()
    render_txt(TXT, rec.xcript, transport == 'telnet')
    con.raw_off()

    dev.close()
    TXT.close()
    HEX.close()

    sys.stderr.write(
        f"\n\nSaved:\n  {base}.txt\n  {base}.hex\n\n"
        "NOTE: masking is BEST EFFORT. The ssh -u/-p values and your -m tokens\n"
        "are masked exactly; secrets the DEVICE prints (config hashes, SNMP\n"
        "communities, keys) are only caught by a small pattern set and MAY REMAIN.\n"
        "Review both files before sharing them or committing them as fixtures.\n")
    return 0


if __name__ == '__main__':
    sys.exit(main())
