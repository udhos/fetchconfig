# fetchconfig -- Windows Ports

Windows ports of record-session.pl and generate_template.pl.

```
record_session.py     Python port of record-session.pl (telnet + SSH)
generate_template.py  Python port of generate_template.pl
build.cmd             builds record_session.exe and generate_template.exe
requirements.txt      pinned build dependencies
ver-*.txt             PyInstaller version resources (9.73)
```

Same command line, same .hex/.txt formats as the Perl tools. The .exe files
are PyInstaller onefile builds and need nothing else installed (no Perl,
PuTTY or OpenSSH). The .py files also run on POSIX (tested: Python 3.12,
3.13; paramiko needed for ssh only).


## Build

Windows, Python 3.12 x64 with the py launcher:

```
build.cmd
```

Output: dist\record_session.exe, dist\generate_template.exe

paramiko is pinned to 3.5.1: 4.x/5.x removed diffie-hellman-group1-sha1,
diffie-hellman-group14-sha1 and ssh-rsa, which older Cisco IOS and ProCurve
SSH servers still require.

This deliberately keeps SHA-1 RSA signatures (ssh-rsa), which CVE-2026-44405
(Low; CVSS 3.4, adjacent-network, integrity-only) flags in paramiko up to fix
commit a448945. It does not apply in practice here: record_session.py is an
operator-run capture tool that already does not verify the host key (see
Transports), and these legacy algorithms are required by the old devices
above. Do not unpin to "fix" it - 4.x/5.x remove those algorithms and break
SSH to that gear.


## Transports

- ssh - paramiko, interactive pty (TERM=xterm) sized to the console;
  password and keyboard-interactive auth, no keys/agent, host key not
  checked (as StrictHostKeyChecking=no in the Perl tool).
- telnet - built-in client (telnetlib was removed in Python 3.13). Accepts
  remote ECHO/SGA, offers TTYPE/NAWS, refuses everything else. The .hex
  keeps the raw IAC bytes, so generate_template still detects telnet
  captures. record-session.pl did not answer negotiation.


## Console (Windows)

Raw input via ReadConsoleInputW: Ctrl-C goes to the device as 0x03,
Backspace is sent as 0x7f, arrows/Home/End/PgUp/PgDn/F1-F12 as xterm
sequences, left Alt as ESC prefix (AltGr unaffected). Device output is
rendered by the console's VT engine (Windows 10 1607+). End the session with
exit/logout on the device, Ctrl-] (German keyboard: Strg-+) or Ctrl-Break.
Redirected stdin is supported. The header timestamp uses a numeric UTC
offset (+0200) on Windows.


## Differences to the Perl tools (fixes)

1. Masking is applied on line boundaries as documented: reads are held until
   one ends a line, the direction changes or 2 s pass, masked as one buffer
   and dumped with the original read boundaries. The Perl tool masked each
   read separately, so a secret split across two reads ("snmp-server
   community pub" | "lic RO") stayed partly in clear.
2. -m tokens typed over several reads (one per keystroke) are masked.
3. Password-prompt masking stops at Enter within the same read; a pasted
   "secret\rshow run\r" no longer masks the following command.
4. .txt render: consecutive device reads are joined before emulation (an
   escape sequence split across reads was printed as text), ESC ( / ESC )
   charset selects are skipped (were printed as "(B"), telnet IAC sequences
   are removed.
5. generate_template: identical output apart from the tool name in the first
   comment line.
