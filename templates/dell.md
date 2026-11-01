# dell template -- state machine

State machine of the `dell` generic-model template (selected with
`model=dell`), parsed from `templates/dell.tmpl`. Dell PowerConnect / N-series over telnet. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `telnet`
- prompt: head `''`, tail `'# ?$'` (the bareword `prompt` = head + learned hostname + tail)
- show command: `show run`
- saved file starts at: `capture_from /^(!|version )/`
- global interrupts (matched at any expect):
  - `/--More--/` -> `send_nolf " "`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      username           -> send user              -> pw
      username           -> send user              -> pw
      password           -> send password          -> after_login
  pw
      password           -> send password          -> after_login
  after_login
      /(\S+)[>#] ?$/     -> send enable            -> enable
  enable
      password           -> send enable secret     -> pager
      at prompt          -> send term datadump     -> show
  pager
      at prompt          -> send term datadump     -> show
  show
      at prompt          -> send show command      -> capture
  capture
      at prompt          -> capture_stop           -> logout
      (capture_start on entry)
  logout
      (send)             -> send exit              -> done

  (any expect may also match a global interrupt, handled automatically)
```
<!--MERMAID
stateDiagram-v2
    [*] --> state_login_telnet: transport telnet
    state_login_telnet --> pw: username, send user
    state_login_telnet --> pw: username, send user
    state_login_telnet --> after_login: password, send password
    pw --> after_login: password, send password
    after_login --> enable: send enable
    enable --> pager: password, send enable secret
    enable --> show: at prompt, send term datadump
    pager --> show: at prompt, send term datadump
    show --> capture: at prompt, send show command
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/User ?Name: ?$/` | `send user` | `pw` |
|  | `/User: ?$/` | `send user` | `pw` |
|  | `/Password: ?$/` | `send_secret pass` | `after_login` |
| `pw` | `/Password: ?$/` | `send_secret pass` | `after_login` |
| `after_login` | `/(\S+)[>#] ?$/` | `send "enable"` | `enable` |
| `enable` | `/Password: ?$/` | `send_secret enable` | `pager` |
|  | `prompt` | `send "term datadump"` | `show` |
| `pager` | `prompt` | `send "term datadump"` | `show` |
| `show` | `prompt` | `send show_cmd` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins. Global interrupt patterns can match at any expect (they are not shown as edges); each sends a keystroke and re-enters the state.

## Template source

Full source of `templates/dell.tmpl`:

```
# dell.tmpl - Dell PowerConnect / N-series over telnet.
#
# syntax_style: cisco-ios
#
# Derived from fetchconfig::model::Dell.
# Note: DRAFT - please verify on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

# show "show run"; override with show_cmd= (show_cmd=wrterm -> "write term").
show_cmd       'show run'

capture_from   /^(!|version )/
interrupt /--More--/ -> send_nolf " "

prompt_head    ''
prompt_tail    '# ?$'

# ---- telnet entry: interactive login ----
state state_login_telnet
    expect /User ?Name: ?$/ -> send user        -> goto pw
    expect /User: ?$/       -> send user        -> goto pw
    expect /Password: ?$/   -> send_secret pass   -> goto after_login

state pw
    expect /Password: ?$/   -> send_secret pass   -> goto after_login

state after_login
    expect /(\S+)[>#] ?$/   -> send "enable"    -> goto enable

state enable
    expect /Password: ?$/   -> send_secret enable -> goto pager
    expect prompt           -> send "term datadump" -> goto show

state pager
    expect prompt           -> send "term datadump" -> goto show

state show
    expect prompt           -> send show_cmd      -> goto capture

state capture
    capture_start
    expect prompt           -> capture_stop       -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/dell.tmpl` by `tools/gen-template-docs.pl`._
