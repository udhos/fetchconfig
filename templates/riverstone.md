# riverstone template -- state machine

State machine of the `riverstone` generic-model template (selected with
`model=riverstone`), parsed from `templates/riverstone.tmpl`. Riverstone RS over telnet. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `telnet`
- prompt: head (default), tail (default) (the bareword `prompt` = head + learned hostname + tail)
- show command: sent as a literal in the show state (see the table)
- `skip_first 1` (drop leading echoed line(s))
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport telnet -> state_login_telnet

  state_login_telnet
      /Press RETURN to activate console/ -> send key               -> state_login_telnet (loop)
      username           -> send user              -> state_login_telnet (loop)
      password           -> send password          -> state_login_telnet (loop)
      /\S+>\s*$/         -> send enable            -> enable
      /\S+#\s*$/         -> nop                    -> pager_conf
  enable
      password           -> send enable secret     -> pager_conf
      /\S+#\s*$/         -> nop                    -> pager_conf
  pager_conf
      /\S+#\s*$/         -> send conf              -> pager_set
  pager_set
      at prompt          -> send system set terminal rows 0 -> pager_exit
  pager_exit
      at prompt          -> send exit              -> show
  show
      /\S+#\s*$/         -> send system show active-config -> capture
  capture
      /\S+#\s*$/         -> capture_stop           -> logout
      (capture_start on entry)
  logout
      (send)             -> send exit              -> done
```
<!--MERMAID
stateDiagram-v2
    [*] --> state_login_telnet: transport telnet
    state_login_telnet --> state_login_telnet: send key
    state_login_telnet --> state_login_telnet: username, send user
    state_login_telnet --> state_login_telnet: password, send password
    state_login_telnet --> enable: send enable
    state_login_telnet --> pager_conf: nop
    enable --> pager_conf: password, send enable secret
    enable --> pager_conf: nop
    pager_conf --> pager_set: send conf
    pager_set --> pager_exit: at prompt, send system set terminal rows 0
    pager_exit --> show: at prompt, send exit
    show --> capture: send system show active-config
    capture --> logout: capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_telnet` | `/Press RETURN to activate console/` | `send ""` | `state_login_telnet` (loop) |
|  | `/Username:\s*$/` | `send user` | `state_login_telnet` (loop) |
|  | `/Password:\s*$/` | `send_secret pass` | `state_login_telnet` (loop) |
|  | `/\S+>\s*$/` | `send "enable"` | `enable` |
|  | `/\S+#\s*$/` | `nop` | `pager_conf` |
| `enable` | `/Password:\s*$/` | `send_secret enable` | `pager_conf` |
|  | `/\S+#\s*$/` | `nop` | `pager_conf` |
| `pager_conf` | `/\S+#\s*$/` | `send "conf"` | `pager_set` |
| `pager_set` | `/\S+\(config\)#\s*$/` | `send "system set terminal rows 0"` | `pager_exit` |
| `pager_exit` | `/\S+\(config\)#\s*$/` | `send "exit"` | `show` |
| `show` | `/\S+#\s*$/` | `send "system show active-config"` | `capture` |
| `capture` | `/\S+#\s*$/` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins. A self-loop (a state that targets itself) is bounded by `max_visits`.

## Template source

Full source of `templates/riverstone.tmpl`:

```
# riverstone.tmpl - Riverstone RS over telnet.
#
# syntax_style: generic
#
# Derived from fetchconfig::model::Riverstone. The console must be activated
# with a RETURN first; paging is disabled from configuration mode. The show
# command is fixed ("system show active-config"). The Perl model restores paging
# afterwards (omitted here, cosmetic).
# Note: DRAFT - please verify on real hardware.

transport      telnet
banner_timeout 30
fetch_timeout  120
max_visits     8

# drop the echoed "system show active-config" command line
skip_first     1

# ---- telnet entry: activate console, then interactive login ----
state state_login_telnet
    expect /Press RETURN to activate console/ -> send ""          -> goto state_login_telnet
    expect /Username:\s*$/ -> send user         -> goto state_login_telnet
    expect /Password:\s*$/ -> send_secret pass    -> goto state_login_telnet
    expect /\S+>\s*$/      -> send "enable"     -> goto enable
    expect /\S+#\s*$/      -> nop                -> goto pager_conf

state enable
    expect /Password:\s*$/ -> send_secret enable -> goto pager_conf
    expect /\S+#\s*$/      -> nop                -> goto pager_conf

# enter configuration mode to disable paging
state pager_conf
    expect /\S+#\s*$/          -> send "conf"                        -> goto pager_set

state pager_set
    expect /\S+\(config\)#\s*$/ -> send "system set terminal rows 0" -> goto pager_exit

state pager_exit
    expect /\S+\(config\)#\s*$/ -> send "exit"                       -> goto show

state show
    expect /\S+#\s*$/          -> send "system show active-config"   -> goto capture

state capture
    capture_start
    expect /\S+#\s*$/          -> capture_stop                       -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/riverstone.tmpl` by `tools/gen-template-docs.pl`._
