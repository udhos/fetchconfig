# fortigate template -- state machine

State machine of the `fortigate` generic-model template (selected with
`model=fortigate`), parsed from `templates/fortigate.tmpl`. Fortinet FortiGate over telnet. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `telnet`
- prompt: head `''`, tail `' ?[#$] ?$'` (the bareword `prompt` = head + learned hostname + tail)
- show command: sent as a literal in the show state (see the table)
- `skip_first 1` (drop leading echoed line(s))
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      login              -> send user              -> pw
      password           -> send password          -> pager_open
  pw
      password           -> send password          -> pager_open
  pager_open
      at prompt          -> send config system console -> pager_set
  pager_set
      at prompt          -> send set output standard -> pager_end
  pager_end
      at prompt          -> send end               -> show
  show
      at prompt          -> send show              -> capture
  capture
      at prompt          -> capture_stop           -> logout
      (capture_start on entry)
  logout
      (send)             -> send exit              -> done
```
<!--MERMAID
stateDiagram-v2
    [*] --> state_login_telnet: transport telnet
    state_login_telnet --> pw: login, send user
    state_login_telnet --> pager_open: password, send password
    pw --> pager_open: password, send password
    pager_open --> pager_set: at prompt, send config system console
    pager_set --> pager_end: at prompt, send set output standard
    pager_end --> show: at prompt, send end
    show --> capture: at prompt, send show
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/login: $/` | `send user` | `pw` |
|  | `/Password: $/` | `send_secret pass` | `pager_open` |
| `pw` | `/Password: $/` | `send_secret pass` | `pager_open` |
| `pager_open` | `prompt` | `send "config system console"` | `pager_set` |
| `pager_set` | `prompt` | `send "set output standard"` | `pager_end` |
| `pager_end` | `prompt` | `send "end"` | `show` |
| `show` | `prompt` | `send "show"` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins.

## Template source

Full source of `templates/fortigate.tmpl`:

```
# fortigate.tmpl - Fortinet FortiGate over telnet.
#
# syntax_style: generic
#
# Derived from fetchconfig::model::FortiGate. No enable. The pager is disabled
# with a three-command sequence; the whole config comes from one "show". The
# Perl model restores the pager afterwards (omitted here, cosmetic).
# Note: DRAFT - please verify on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

# drop the echoed "show" command line
skip_first     1

prompt_head    ''
prompt_tail    ' ?[#$] ?$'

# ---- telnet entry: interactive login (no enable) ----
state state_login_telnet
    expect /login: $/    -> send user        -> goto pw
    expect /Password: $/ -> send_secret pass   -> goto pager_open

state pw
    expect /Password: $/ -> send_secret pass   -> goto pager_open

# disable the pager: config system console / set output standard / end
state pager_open
    expect prompt -> send "config system console" -> goto pager_set

state pager_set
    expect prompt -> send "set output standard"   -> goto pager_end

state pager_end
    expect prompt -> send "end"                   -> goto show

state show
    expect prompt -> send "show"                  -> goto capture

state capture
    capture_start
    expect prompt -> capture_stop                 -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/fortigate.tmpl` by `tools/gen-template-docs.pl`._
