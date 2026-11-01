# planet-ssh template -- state machine

State machine of the `planet-ssh` generic-model template (selected with
`model=planet-ssh`), parsed from `templates/planet-ssh.tmpl`. PLANET switches over SSH. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: Verified on real hardware.
- transport: `ssh`
- prompt: head `''`, tail `'# ?$'` (the bareword `prompt` = head + learned hostname + tail)
- show command: `show running-config`
- saved file starts at: `capture_from /(?i)^(?!building configuration)(?!\s*$)\S/`
- `skip_first 1` (drop leading echoed line(s))
- timing: type_delay_ms 100
- volatile lines ignored in the compare: `/^! System Up Time:/`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport ssh    -> state_login_ssh

  state_login_ssh
      at prompt          -> send key               -> state_login_ssh (loop)
      username           -> send user              -> state_login_ssh (loop)
      password           -> send password          -> state_login_ssh (loop)
      at prompt          -> send enable            -> enable
      at prompt          -> send terminal length 0 -> show
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
    [*] --> state_login_ssh: transport ssh
    state_login_ssh --> state_login_ssh: at prompt, send key
    state_login_ssh --> state_login_ssh: username, send user
    state_login_ssh --> state_login_ssh: password, send password
    state_login_ssh --> enable: at prompt, send enable
    state_login_ssh --> show: at prompt, send terminal length 0
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
| `state_login_ssh` | `/Press <Enter>/` | `send ""` | `state_login_ssh` (loop) |
|  | `/Username: ?$/` | `send user` | `state_login_ssh` (loop) |
|  | `/Password: ?$/` | `send_secret pass` | `state_login_ssh` (loop) |
|  | `/(\S+)> ?$/` | `send "enable"` | `enable` |
|  | `prompt` | `send "terminal length 0"` | `show` |
| `enable` | `/Password: ?$/` | `send_secret enable` | `pager` |
|  | `prompt` | `send "terminal length 0"` | `show` |
| `pager` | `prompt` | `send "terminal length 0"` | `show` |
| `show` | `prompt` | `send show_cmd` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins. A self-loop (a state that targets itself) is bounded by `max_visits`.

## Template source

Full source of `templates/planet-ssh.tmpl`:

```
# planet-ssh.tmpl - PLANET switches over SSH.
#
# syntax_style: planet-ssh
#
# Derived from fetchconfig::model::PLANET. These devices drop fast input, so
# every keystroke is paced with type_delay_ms (the model types char-by-char).
# After the SSH channel opens the switch presents its own banner/login again.
# The enable password uses the "enable=" option; set it equal to the login
# password if the device uses the same.
# Note: Verified on real hardware.

transport      ssh
banner_timeout 30
fetch_timeout  120
max_visits     8
type_delay_ms  100

prompt_head    ''
prompt_tail    '# ?$'

# show "show running-config"; override per device with show_cmd=.
show_cmd       'show running-config'

# the "! System Up Time:" line is rewritten every read
ignore  /^! System Up Time:/
# Drop the echoed command, then start at the first real line - some firmware
# leads with "SYSTEM CONFIG FILE ::= BEGIN" (no "!"), so do NOT anchor on "!".
skip_first     1
capture_from   /(?i)^(?!building configuration)(?!\s*$)\S/

# ---- SSH entry: dismiss banner, log in, reach the prompt ----
state state_login_ssh
    expect /Press <Enter>/  -> send ""          -> goto state_login_ssh
    expect /Username: ?$/   -> send user         -> goto state_login_ssh
    expect /Password: ?$/   -> send_secret pass   -> goto state_login_ssh
    expect /(\S+)> ?$/      -> send "enable"    -> goto enable
    expect prompt           -> send "terminal length 0" -> goto show

state enable
    expect /Password: ?$/   -> send_secret enable -> goto pager
    expect prompt           -> send "terminal length 0" -> goto show

state pager
    expect prompt           -> send "terminal length 0" -> goto show

state show
    expect prompt           -> send show_cmd      -> goto capture

state capture
    capture_start
    expect prompt           -> capture_stop       -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/planet-ssh.tmpl` by `tools/gen-template-docs.pl`._
