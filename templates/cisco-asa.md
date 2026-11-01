# cisco-asa template -- state machine

State machine of the `cisco-asa` generic-model template (selected with
`model=cisco-asa`), parsed from `templates/cisco-asa.tmpl`. Cisco ASA, telnet and SSH. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `ssh telnet`
- prompt: head `''`, tail `'# ?$'` (the bareword `prompt` = head + learned hostname + tail)
- show command: `more system:running-config`
- saved file starts at: `capture_from /^:/`
- volatile lines ignored in the compare: `/^: Written by \S+ at /`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport ssh    -> state_login_ssh
    transport telnet -> state_login_telnet

  state_login_ssh
      /(\S+)[>#] ?$/     -> send enable            -> enable
  state_login_telnet
      username           -> send user              -> state_password_telnet
      password           -> send password          -> after_login
  state_password_telnet
      password           -> send password          -> after_login
  after_login
      /(\S+)[>#] ?$/     -> send enable            -> enable
  enable
      password           -> send enable secret     -> pager
      at prompt          -> send term pager 0      -> show
  pager
      at prompt          -> send term pager 0      -> show
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
    [*] --> state_login_telnet: transport telnet
    state_login_ssh --> enable: send enable
    state_login_telnet --> state_password_telnet: username, send user
    state_login_telnet --> after_login: password, send password
    state_password_telnet --> after_login: password, send password
    after_login --> enable: send enable
    enable --> pager: password, send enable secret
    enable --> show: at prompt, send term pager 0
    pager --> show: at prompt, send term pager 0
    show --> capture: at prompt, send show command
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_ssh` | `/(\S+)[>#] ?$/` | `send "enable"` | `enable` |
| `state_login_telnet` | `/Username: ?$/` | `send user` | `state_password_telnet` |
|  | `/Password: ?$/` | `send_secret pass` | `after_login` |
| `state_password_telnet` | `/Password: ?$/` | `send_secret pass` | `after_login` |
| `after_login` | `/(\S+)[>#] ?$/` | `send "enable"` | `enable` |
| `enable` | `/Password: ?$/` | `send_secret enable` | `pager` |
|  | `prompt` | `send "term pager 0"` | `show` |
| `pager` | `prompt` | `send "term pager 0"` | `show` |
| `show` | `prompt` | `send show_cmd` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins.

## Template source

Full source of `templates/cisco-asa.tmpl`:

```
# cisco-asa.tmpl - Cisco ASA, telnet and SSH (covers models cisco-asa and
# cisco-asa-ssh).
#
# syntax_style: cisco-ios
#
# Derived from fetchconfig::model::CiscoASA / CiscoASASSH. SSH lands already
# authenticated at the prompt; telnet logs in interactively. Both converge on
# "enable".
# Note: DRAFT - please verify on real hardware.

transport      ssh telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

prompt_head    ''
prompt_tail    '# ?$'

# show "more system:running-config"; override per device with show_cmd=
# (show_cmd=wrterm -> "write term").
show_cmd       'more system:running-config'

# the ": Written by <user> at <time>" header line is rewritten every read
ignore  /^: Written by \S+ at /

# ASA config starts at the ": Saved" / ": ..." header (keeps "ASA Version")
capture_from  /^:/

# ---- SSH entry: authenticated; at the prompt, send enable ----
state state_login_ssh
    expect /(\S+)[>#] ?$/  -> send "enable"   -> goto enable

# ---- telnet entry: interactive login ----
state state_login_telnet
    expect /Username: ?$/  -> send user        -> goto state_password_telnet
    expect /Password: ?$/  -> send_secret pass  -> goto after_login

state state_password_telnet
    expect /Password: ?$/  -> send_secret pass  -> goto after_login

state after_login
    expect /(\S+)[>#] ?$/  -> send "enable"   -> goto enable

# response to "enable": an enable-password prompt, or - if already enabled -
# the prompt. Either way, disable the pager next.
state enable
    expect /Password: ?$/  -> send_secret enable -> goto pager
    expect prompt          -> send "term pager 0" -> goto show

state pager
    expect prompt          -> send "term pager 0" -> goto show

state show
    expect prompt          -> send show_cmd      -> goto capture

state capture
    capture_start
    expect prompt          -> capture_stop       -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/cisco-asa.tmpl` by `tools/gen-template-docs.pl`._
