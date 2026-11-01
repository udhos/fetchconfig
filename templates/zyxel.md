# zyxel template -- state machine

State machine of the `zyxel` generic-model template (selected with
`model=zyxel`), parsed from `templates/zyxel.tmpl`. Zyxel switch over telnet. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: Verified on real hardware.
- transport: `telnet`
- prompt: head `''`, tail `'# ?$'` (the bareword `prompt` = head + learned hostname + tail)
- show command: `show running-config`
- saved file starts at: `capture_from /(?i)^(?!building configuration)(?!\s*$)\S/`
- `skip_first 1` (drop leading echoed line(s))
- `strip_ansi yes`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      username           -> send user              -> pw
      password           -> send password          -> after_login
  pw
      password           -> send password          -> after_login
  after_login
      /(\S+)[>#] ?$/     -> send enable            -> enable
  enable
      password           -> send enable secret     -> pager
      at prompt          -> send terminal length 0 -> show
  pager
      at prompt          -> send terminal length 0 -> show
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
    state_login_telnet --> pw: username, send user
    state_login_telnet --> after_login: password, send password
    pw --> after_login: password, send password
    after_login --> enable: send enable
    enable --> pager: password, send enable secret
    enable --> show: at prompt, send terminal length 0
    pager --> show: at prompt, send terminal length 0
    show --> capture: at prompt, send show command
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/Username: ?$/` | `send user` | `pw` |
|  | `/Password: ?$/` | `send_secret pass` | `after_login` |
| `pw` | `/Password: ?$/` | `send_secret pass` | `after_login` |
| `after_login` | `/(\S+)[>#] ?$/` | `send "enable"` | `enable` |
| `enable` | `/Password: ?$/` | `send_secret enable` | `pager` |
|  | `prompt` | `send "terminal length 0"` | `show` |
| `pager` | `prompt` | `send "terminal length 0"` | `show` |
| `show` | `prompt` | `send show_cmd` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins.

## Template source

Full source of `templates/zyxel.tmpl`:

```
# zyxel.tmpl - Zyxel switch over telnet.
#
# syntax_style: zyxel
#
# Derived from fetchconfig::model::Zyxel. These switches emit reversed "\n\r"
# line endings; strip_ansi cleans the stray CR/NUL. The Perl model also removes
# all blank lines from the saved file - the template keeps them (cosmetic).
# Note: Verified on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8
strip_ansi     yes

# show "show running-config"; override per device with show_cmd=.
show_cmd       'show running-config'

# Zyxel echoes the command and prints "Building configuration..." before the
# config, which itself has NO leading "!" (it starts at e.g. "hostname ...").
# Drop the echoed command (skip_first), then start the saved config at the
# first real line - anything that is not blank and not the "Building
# configuration..." banner - whatever the first keyword is.
skip_first     1
capture_from   /(?i)^(?!building configuration)(?!\s*$)\S/

prompt_head    ''
prompt_tail    '# ?$'

# ---- telnet entry: interactive login ----
state state_login_telnet
    expect /Username: ?$/  -> send user        -> goto pw
    expect /Password: ?$/  -> send_secret pass   -> goto after_login

state pw
    expect /Password: ?$/  -> send_secret pass   -> goto after_login

state after_login
    expect /(\S+)[>#] ?$/  -> send "enable"    -> goto enable

state enable
    expect /Password: ?$/  -> send_secret enable -> goto pager
    expect prompt          -> send "terminal length 0" -> goto show

state pager
    expect prompt          -> send "terminal length 0" -> goto show

state show
    expect prompt          -> send show_cmd      -> goto capture

state capture
    capture_start
    expect prompt          -> capture_stop       -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/zyxel.tmpl` by `tools/gen-template-docs.pl`._
