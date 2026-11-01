# terayon-os template -- state machine

State machine of the `terayon-os` generic-model template (selected with
`model=terayon-os`), parsed from `templates/terayon-os.tmpl`. Terayon OS over telnet. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `telnet`
- prompt: head `''`, tail `'#'` (the bareword `prompt` = head + learned hostname + tail)
- show command: `show run`
- saved file starts at: `capture_from /^(!|version )/`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      login              -> send user              -> pw
      password           -> send password          -> after_login
  pw
      password           -> send password          -> after_login
  after_login
      /(\S+)[>#]$/       -> send enable            -> enable
  enable
      password           -> send enable secret     -> pager
      at prompt          -> send term len 0        -> show
  pager
      at prompt          -> send term len 0        -> show
  show
      at prompt          -> send show command      -> capture
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
    state_login_telnet --> after_login: password, send password
    pw --> after_login: password, send password
    after_login --> enable: send enable
    enable --> pager: password, send enable secret
    enable --> show: at prompt, send term len 0
    pager --> show: at prompt, send term len 0
    show --> capture: at prompt, send show command
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/Login:$/` | `send user` | `pw` |
|  | `/Password:$/` | `send_secret pass` | `after_login` |
| `pw` | `/Password:$/` | `send_secret pass` | `after_login` |
| `after_login` | `/(\S+)[>#]$/` | `send "enable"` | `enable` |
| `enable` | `/Password:$/` | `send_secret enable` | `pager` |
|  | `prompt` | `send "term len 0"` | `show` |
| `pager` | `prompt` | `send "term len 0"` | `show` |
| `show` | `prompt` | `send show_cmd` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins.

## Template source

Full source of `templates/terayon-os.tmpl`:

```
# terayon-os.tmpl - Terayon OS over telnet.
#
# syntax_style: cisco-ios
#
# Derived from fetchconfig::model::Terayon. The prompt ends with "#" and has no
# trailing space.
# Note: DRAFT - please verify on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

# show "show run"; override with show_cmd= (show_cmd=wrterm -> "write term").
show_cmd       'show run'

capture_from   /^(!|version )/

prompt_head    ''
prompt_tail    '#'

# ---- telnet entry: interactive login ----
state state_login_telnet
    expect /Login:$/    -> send user        -> goto pw
    expect /Password:$/ -> send_secret pass   -> goto after_login

state pw
    expect /Password:$/ -> send_secret pass   -> goto after_login

state after_login
    expect /(\S+)[>#]$/ -> send "enable"    -> goto enable

state enable
    expect /Password:$/ -> send_secret enable -> goto pager
    expect prompt       -> send "term len 0"  -> goto show

state pager
    expect prompt       -> send "term len 0"  -> goto show

state show
    expect prompt       -> send show_cmd      -> goto capture

state capture
    capture_start
    expect prompt       -> capture_stop       -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/terayon-os.tmpl` by `tools/gen-template-docs.pl`._
