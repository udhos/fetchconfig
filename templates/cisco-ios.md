# cisco-ios template -- state machine

State machine of the `cisco-ios` generic-model template (selected with
`model=cisco-ios`), parsed from `templates/cisco-ios.tmpl`. Generic-model template for Cisco IOS / IOS-XE. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: Verified on real hardware.
- transport: `ssh telnet`
- prompt: head `''`, tail `'#'` (the bareword `prompt` = head + learned hostname + tail)
- show command: sent as a literal in the show state (see the table)
- saved file starts at: `capture_from /^!/`
- `strip_ansi no`
- volatile lines ignored in the compare: `/^! Last configuration change/`, `/^! NVRAM config last updated/`, `/^ntp clock-period /`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport ssh    -> state_login_ssh
    transport telnet -> state_login_telnet

  state_login_ssh
      /(\S+)[>#]$/       -> send enable            -> enable
  state_login_telnet
      username           -> send user              -> state_password_telnet
      password           -> send password          -> after_login
  state_password_telnet
      password           -> send password          -> after_login
  after_login
      /(\S+)[>#]$/       -> send enable            -> enable
  enable
      password           -> send enable secret     -> pager
      at prompt          -> send term len 0        -> show
  pager
      at prompt          -> send term len 0        -> show
  show
      at prompt          -> send show running-config -> capture
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
    enable --> show: at prompt, send term len 0
    pager --> show: at prompt, send term len 0
    show --> capture: at prompt, send show running-config
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_ssh` | `/(\S+)[>#]$/` | `send "enable"` | `enable` |
| `state_login_telnet` | `/Username: $/` | `send user` | `state_password_telnet` |
|  | `/Password: $/` | `send_secret pass` | `after_login` |
| `state_password_telnet` | `/Password: $/` | `send_secret pass` | `after_login` |
| `after_login` | `/(\S+)[>#]$/` | `send "enable"` | `enable` |
| `enable` | `/Password: $/` | `send_secret enable` | `pager` |
|  | `prompt` | `send "term len 0"` | `show` |
| `pager` | `prompt` | `send "term len 0"` | `show` |
| `show` | `prompt` | `send "show running-config"` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins.

## Template source

Full source of `templates/cisco-ios.tmpl`:

```
# cisco-ios.tmpl - generic-model template for Cisco IOS / IOS-XE,
#
# syntax_style: cisco-ios
# telnet and SSH, via per-transport entry states.
#
# Lexical conventions:
#   /regex/        a regular expression (used in expect, ignore, interrupt)
#   "text"         a literal string to send
#   bare / 'quoted' a directive value (e.g. strip_ansi no, prompt_tail '#')
#
# Flow: each state waits (expect) for the response to the previous command,
# then sends the next. SSH is already authenticated and lands at the prompt;
# telnet logs in interactively. Both converge on "enable".
#
# Note: Verified on real hardware.

transport      ssh telnet
banner_timeout 30
fetch_timeout  120
max_visits     8
strip_ansi     no

prompt_head    ''
prompt_tail    '#'

# volatile lines ignored when comparing backups
ignore  /^! Last configuration change/
ignore  /^! NVRAM config last updated/
ignore  /^ntp clock-period /

# start the saved file at the first "!" line (matches a TFTP export)
capture_from  /^!/

# ---- SSH entry: already authenticated; match the prompt, send enable ----
state state_login_ssh
    expect /(\S+)[>#]$/    -> send "enable"         -> goto enable

# ---- telnet entry: interactive login ----
state state_login_telnet
    expect /Username: $/   -> send user             -> goto state_password_telnet
    expect /Password: $/   -> send_secret pass      -> goto after_login

state state_password_telnet
    expect /Password: $/   -> send_secret pass      -> goto after_login

# after telnet login: match the prompt, send enable
state after_login
    expect /(\S+)[>#]$/    -> send "enable"         -> goto enable

# response to "enable": a Password: prompt (send enable secret), or - if
# already enabled - the prompt. Either way the next step disables the pager.
state enable
    expect /Password: $/   -> send_secret enable    -> goto pager
    expect prompt          -> send "term len 0"     -> goto show

# response to the enable password is the prompt; disable the pager.
state pager
    expect prompt          -> send "term len 0"     -> goto show

# response to "term len 0" is the prompt; request the running config.
state show
    expect prompt          -> send "show running-config" -> goto capture

# capture everything until the prompt returns.
state capture
    capture_start
    expect prompt          -> capture_stop          -> goto logout

# already at the prompt: send exit without waiting.
state logout
    send "exit" -> done
```

_Generated from `templates/cisco-ios.tmpl` by `tools/gen-template-docs.pl`._
