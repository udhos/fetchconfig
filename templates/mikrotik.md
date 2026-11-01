# mikrotik template -- state machine

State machine of the `mikrotik` generic-model template (selected with
`model=mikrotik`), parsed from `templates/mikrotik.tmpl`. MikroTik RouterOS over telnet. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `telnet`
- prompt: head (default), tail (default) (the bareword `prompt` = head + learned hostname + tail)
- show command: `export`
- `skip_first 1` (drop leading echoed line(s))
- volatile lines ignored in the compare: `/^# .* by RouterOS/`
- global interrupts (matched at any expect):
  - `/--More--/` -> `send_nolf " "`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      login              -> send user              -> pw
      password           -> send password          -> show
  pw
      password           -> send password          -> show
  show
      /\[[^\]]+\] ?> ?$/ -> send show command      -> capture
  capture
      /\[[^\]]+\] ?> ?$/ -> capture_stop           -> logout
      (capture_start on entry)
  logout
      (send)             -> send quit              -> done

  (any expect may also match a global interrupt, handled automatically)
```
<!--MERMAID
stateDiagram-v2
    [*] --> state_login_telnet: transport telnet
    state_login_telnet --> pw: login, send user
    state_login_telnet --> show: password, send password
    pw --> show: password, send password
    show --> capture: send show command
    capture --> logout: capture_stop
    logout --> [*]: send quit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/Login: ?$/` | `send user` | `pw` |
|  | `/Password: ?$/` | `send_secret pass` | `show` |
| `pw` | `/Password: ?$/` | `send_secret pass` | `show` |
| `show` | `/\[[^\]]+\] ?> ?$/` | `send show_cmd` | `capture` |
| `capture` | `/\[[^\]]+\] ?> ?$/` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "quit"` | `done` |

States with more than one expect try them in order; the first match wins. Global interrupt patterns can match at any expect (they are not shown as edges); each sends a keystroke and re-enters the state.

## Template source

Full source of `templates/mikrotik.tmpl`:

```
# mikrotik.tmpl - MikroTik RouterOS over telnet.
#
# syntax_style: generic
#
# Derived from fetchconfig::model::MikroTik. IMPORTANT: the Perl model appends
# "+ct" to the username (disable colour, auto-detect terminal); a template
# cannot, so set the device option user=<name>+ct (e.g. user=admin+ct). The
# prompt is "[user@name] > ". No enable.
# Note: DRAFT - please verify on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

# RouterOS config dump "export"; override per device with show_cmd=.
show_cmd       'export'

# drop the echoed "export"; the "# <date> by RouterOS ..." line is volatile
skip_first     1
ignore  /^# .* by RouterOS/
interrupt /--More--/ -> send_nolf " "

# ---- telnet entry: interactive login (no enable) ----
state state_login_telnet
    expect /Login: ?$/    -> send user        -> goto pw
    expect /Password: ?$/ -> send_secret pass   -> goto show

state pw
    expect /Password: ?$/ -> send_secret pass   -> goto show

# prompt "[user@name] > "
state show
    expect /\[[^\]]+\] ?> ?$/ -> send show_cmd  -> goto capture

state capture
    capture_start
    expect /\[[^\]]+\] ?> ?$/ -> capture_stop   -> goto logout

state logout
    send "quit" -> done
```

_Generated from `templates/mikrotik.tmpl` by `tools/gen-template-docs.pl`._
