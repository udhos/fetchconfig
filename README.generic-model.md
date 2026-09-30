# The template-driven "generic" model

## What it is

The "generic" model lets a device be backed up from a TEMPLATE file instead of a
hand-written Perl model. The template describes the login/enable/show/logout
interaction as a small state machine; the generic model interprets it. For a
clean-CLI device (Cisco IOS and similar) a template is a short data file rather
than ~200 lines of Perl.

STATUS: the template parser/validator is production-ready and unit tested. The
execution engine has been verified against a real Cisco IOS-XE over both telnet
and SSH. Menu/VT100 devices (ProCurve) are supported by the format
(`strip_ansi`, interrupt screens, multi-expect branches) but need their own
template and real-device testing.

For the full engineering reference (architecture, execution semantics, writing
and generating templates) see `README.template_engine`. This file is the quick
reference.

## Selecting it in the device table

```
generic  <dev_id>  <host>  model=<name>,transport=ssh|telnet,<options>
```

- `model=<name>` is MANDATORY: it loads `templates/<name>.tmpl`.
- `transport` is ssh or telnet (auto is not yet supported); if omitted, the
  template's first-listed transport is used.
- A device-table option OVERRIDES the same-named value in the template (e.g.
  `banner_timeout=60` on the device line beats the template's).

Standard options work as for any model: `user`, `pass`, `enable`, `repository`,
`timeout`, `keep`, `changes_only`, `on_fetch_run`, `on_fetch_cat`, `timezone`,
`filename_append_suffix`, `comment`, `debug`.

## Template grammar

Lines: `#` begins a comment (except inside a `/regex/` or a `"string"` or
`'string'`); blank lines are ignored.

Top-of-file directives (all optional; defaults in parentheses):

| Directive | Meaning |
|---|---|
| `transport ssh telnet` | allowed transports, in preference order |
| `banner_timeout N` | wait for the first prompt, seconds (30) |
| `fetch_timeout N` | wait for the show output, seconds (base) |
| `fetch_delay N` | pause after connect, seconds (0) |
| `prompt_settle N` | prompt settle time, ms (Abstract default) |
| `max_visits N` | global self-loop cap (8) |
| `strip_ansi yes\|no` | strip VT100 escapes from output (no) |
| `prompt_head 'REGEX'` | matched before the learned hostname (empty) |
| `prompt_tail 'REGEX'` | matched after it (`#`) |
| `ssh_extra_opts 'STRING'` | extra ssh options (legacy crypto) |
| `capture_from /REGEX/` | start the saved config at the first matching line |
| `skip_first N` | drop the first N captured lines |

Global (checked in every state):

- `interrupt /REGEX/ -> <action>` - a screen that can appear anywhere (menu,
  "Press any key", "[y/n]?").
- `ignore /REGEX/` - a volatile config line to ignore when comparing backups.

States. Every state is declared with the `state` keyword:
`state <name> [max_visits N]`. The engine starts at the reserved entry state
for the chosen transport:

- `state state_login_ssh` / `state state_password_ssh` - SSH is already
  authenticated, so these usually just match the prompt.
- `state state_login_telnet` / `state state_password_telnet` - telnet does
  interactive login here.

At least one of `state_login_ssh` / `state_login_telnet` must be present.

Inside a state:

- `expect PATTERN -> ACTION [-> goto STATE | -> done]` - `PATTERN` is `/regex/`
  or the bareword `prompt` (the learned prompt: `prompt_head` + quoted hostname
  + `prompt_tail`). Multiple expects in one state are tried in order, FIRST
  MATCH WINS - order the most specific first. A self-loop (goto the same state)
  must be bounded by `max_visits`.
- `send "text"` | `send user|pass|enable` - send WITH newline. As a standalone
  step (no preceding expect) it sends immediately, without waiting for a prompt
  - used after capture to send `exit`.
- `send_secret pass|enable` - send, masked in the debug log.
- `send_nolf "text"` - send WITHOUT newline (pager space, menu key).
- `send_match` - send the captured group `$1` from the expect regex, as a
  keystroke (pick a menu item by its shown number).
- `nop` - do nothing.
- `capture_start` / `capture_stop` - bracket the config; capture is the text
  between the show-command send and the next prompt.

A transition is `-> goto <state>`, `-> done`, or `-> stay` (re-enter the same
state, bounded by `max_visits`). An `expect` with no explicit transition
defaults to `stay`.

`-> stay` is for a state that must repeat until something changes - e.g.
draining a pager on a device that cannot disable it. The state loops on
itself sending a keystroke for each page, and leaves when the prompt appears
instead (the shipped templates do not need this because they disable the
pager with `term len 0` / `no page`):

```
state drain_pager
    expect /--More--/  -> send_nolf " "  -> stay   # space for each page, repeat
    expect prompt      -> nop             -> goto show
```

`max_visits` caps the loop so a device stuck on `--More--` cannot loop
forever.

Lexical conventions: `/regex/` is a regular expression (in `expect`,
`ignore`, `interrupt`); `"text"` is a literal string to send; a directive
value is bare or single-quoted (e.g. `strip_ansi no`, `prompt_tail '#'`).

A template must contain exactly one `capture_start` and one `capture_stop`. The
validator (run at load time) rejects: an unbounded self-loop, a goto to an
unknown state, a missing/duplicate capture marker, an unreachable state, a
missing transport entry state, a bad transport.

## Example

See `templates/cisco-ios.tmpl` (telnet + SSH) and, for a menu/VT100 device,
`templates/procurve.tmpl`.

## Security

With `debug=on` the session debug log masks the passwords sent via `send_secret`
(the shared `print_secret` helper turns `dump_log` off around the send). Masking
of secrets the DEVICE prints (config hashes, SNMP communities) relies on
`ignore`/`-m` as usual - review a debug log before sharing it. The debug file is
0600.

Note that the debug-log masking does NOT make a backup safe to share: the SAVED
CONFIG itself contains the device's credentials - and not always hashed. SNMP
communities and some routing/VPN keys (BGP, OSPF, RADIUS/TACACS, IPsec
pre-shared keys) are stored in cleartext, and Cisco "type 7" passwords are
trivially reversible. Treat every backup as sensitive and restrict the
repository directory, regardless of the debug setting.

## Limitations

- `transport=auto` is not implemented (use ssh or telnet).
- There is no escape-hatch to a named Perl helper yet: a device whose behaviour
  the state machine cannot express still needs a Perl model.
- `generate_template.pl` scaffolds a template from a captured `.hex` but its
  output is a DRAFT to review, not a finished model.


## Upgrading from 9.64

The state-declaration syntax changed in 9.65: every state, including the
per-transport entry states, is now declared with the `state` keyword. A
template written for 9.64 or earlier must be migrated by prefixing each bare
entry-state header with `state`:

```
state_login_ssh        ->  state state_login_ssh
state_password_ssh     ->  state state_password_ssh
state_login_telnet     ->  state state_login_telnet
state_password_telnet  ->  state state_password_telnet
```

`goto` targets and other states are unchanged. Verify with
`fetchconfig.pl --check-template PATH`.
