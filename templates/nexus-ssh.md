# nexus-ssh template -- state machine

State machine of the `nexus-ssh` generic-model template (selected with
`model=nexus-ssh`), parsed from `templates/nexus-ssh.tmpl`. Cisco Nexus. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: DRAFT - please verify on real hardware.
- transport: `ssh`
- prompt: head `''`, tail `'# ?$'` (the bareword `prompt` = head + learned hostname + tail)
- show command: `show running-config`
- saved file starts at: `capture_from /^!Command:/`
- timing: prompt_settle_ms 150
- volatile lines ignored in the compare: `/^!Time:/`
- timeouts: banner 30s, fetch 120s, max_visits 8

## State machine

```text
  entry:
    transport ssh    -> state_login_ssh

  state_login_ssh
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
    state_login_ssh --> show: at prompt, send terminal length 0
    show --> capture: at prompt, send show command
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_ssh` | `prompt` | `send "terminal length 0"` | `show` |
| `show` | `prompt` | `send show_cmd` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

## Template source

Full source of `templates/nexus-ssh.tmpl`:

```
# nexus-ssh.tmpl - Cisco Nexus (NX-OS) over SSH.
#
# syntax_style: nexus
#
# Derived from fetchconfig::model::NexusSSH. SSH lands authenticated at "#"
# (no enable). prompt_settle_ms lets the MOTD/copyright banner finish before
# the prompt is matched.
# Note: DRAFT - please verify on real hardware.

transport        ssh
banner_timeout   30
fetch_timeout    120
max_visits       8
prompt_settle_ms 150

prompt_head      ''
prompt_tail      '# ?$'

# show "show running-config"; override per device with show_cmd=.
show_cmd         'show running-config'

# NX-OS keeps the "!Command:" / "!Running configuration last done at:" headers;
# only "!Time:" is rewritten every read.
ignore  /^!Time:/
capture_from     /^!Command:/

# ---- SSH entry: authenticated; disable paging ----
state state_login_ssh
    expect prompt  -> send "terminal length 0" -> goto show

state show
    expect prompt  -> send show_cmd            -> goto capture

state capture
    capture_start
    expect prompt  -> capture_stop             -> goto logout

state logout
    send "exit" -> done
```

_Generated from `templates/nexus-ssh.tmpl` by `tools/gen-template-docs.pl`._
