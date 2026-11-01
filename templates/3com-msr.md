# 3com-msr template -- state machine

State machine of the `3com-msr` generic-model template (selected with
`model=3com-msr`), parsed from `templates/3com-msr.tmpl`. 3Com/H3C MSR. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `telnet`
- prompt: head (default), tail (default) (the bareword `prompt` = head + learned hostname + tail)
- show command: `disp curr`
- saved file starts at: `capture_from /^#/`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      username           -> send user              -> pw
      password           -> send password          -> user_view
  pw
      password           -> send password          -> user_view
  user_view
      at prompt          -> send super             -> super_pw
  super_pw
      password           -> send enable secret     -> sys_enter
      at prompt          -> send sys               -> sys_view
  sys_enter
      at prompt          -> send sys               -> sys_view
  sys_view
      /\[[^\]]+\]$/      -> send user-interface vty 0 4 -> vty_line
  vty_line
      /\[[^\]]+\]$/      -> send screen-length 0   -> vty_quit
  vty_quit
      /\[[^\]]+\]$/      -> send quit              -> show
  show
      /\[[^\]]+\]$/      -> send show command      -> capture
  capture
      /\[[^\]]+\]$/      -> capture_stop           -> logout
      (capture_start on entry)
  logout
      (send)             -> send quit              -> done
```
<!--MERMAID
stateDiagram-v2
    [*] --> state_login_telnet: transport telnet
    state_login_telnet --> pw: username, send user
    state_login_telnet --> user_view: password, send password
    pw --> user_view: password, send password
    user_view --> super_pw: at prompt, send super
    super_pw --> sys_enter: password, send enable secret
    super_pw --> sys_view: at prompt, send sys
    sys_enter --> sys_view: at prompt, send sys
    sys_view --> vty_line: send user-interface vty 0 4
    vty_line --> vty_quit: send screen-length 0
    vty_quit --> show: send quit
    show --> capture: send show command
    capture --> logout: capture_stop
    logout --> [*]: send quit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/Username:$/` | `send user` | `pw` |
|  | `/Password:$/` | `send_secret pass` | `user_view` |
| `pw` | `/Password:$/` | `send_secret pass` | `user_view` |
| `user_view` | `/<[^>]+>$/` | `send "super"` | `super_pw` |
| `super_pw` | `/Password:$/` | `send_secret enable` | `sys_enter` |
|  | `/<[^>]+>$/` | `send "sys"` | `sys_view` |
| `sys_enter` | `/<[^>]+>$/` | `send "sys"` | `sys_view` |
| `sys_view` | `/\[[^\]]+\]$/` | `send "user-interface vty 0 4"` | `vty_line` |
| `vty_line` | `/\[[^\]]+\]$/` | `send "screen-length 0"` | `vty_quit` |
| `vty_quit` | `/\[[^\]]+\]$/` | `send "quit"` | `show` |
| `show` | `/\[[^\]]+\]$/` | `send show_cmd` | `capture` |
| `capture` | `/\[[^\]]+\]$/` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "quit"` | `done` |

States with more than one expect try them in order; the first match wins.

## Template source

Full source of `templates/3com-msr.tmpl`:

```
# 3com-msr.tmpl - 3Com/H3C MSR (Comware) over telnet.
#
# syntax_style: comware
#
# Derived from fetchconfig::model::3ComMSR. Log in to user-view "<host>",
# elevate with "super", enter system-view "[host]" with "sys", disable paging
# on the vty line, then "disp curr". The Perl model restores paging afterwards;
# that is omitted here (cosmetic for a backup).
# Note: DRAFT - please verify on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

show_cmd       'disp curr'

# Comware config starts at the first "#" section line (drops the echoed command)
capture_from   /^#/

# ---- telnet entry: interactive login ----
state state_login_telnet
    expect /Username:$/  -> send user        -> goto pw
    expect /Password:$/  -> send_secret pass   -> goto user_view

state pw
    expect /Password:$/  -> send_secret pass   -> goto user_view

# user-view "<host>": elevate with "super"
state user_view
    expect /<[^>]+>$/    -> send "super"      -> goto super_pw

# "super" may ask for a password, or return straight to user-view
state super_pw
    expect /Password:$/  -> send_secret enable -> goto sys_enter
    expect /<[^>]+>$/    -> send "sys"         -> goto sys_view

state sys_enter
    expect /<[^>]+>$/    -> send "sys"         -> goto sys_view

# system-view "[host]": disable paging on the vty line
state sys_view
    expect /\[[^\]]+\]$/ -> send "user-interface vty 0 4" -> goto vty_line

state vty_line
    expect /\[[^\]]+\]$/ -> send "screen-length 0"        -> goto vty_quit

state vty_quit
    expect /\[[^\]]+\]$/ -> send "quit"                   -> goto show

state show
    expect /\[[^\]]+\]$/ -> send show_cmd                 -> goto capture

state capture
    capture_start
    expect /\[[^\]]+\]$/ -> capture_stop                  -> goto logout

state logout
    send "quit" -> done
```

_Generated from `templates/3com-msr.tmpl` by `tools/gen-template-docs.pl`._
