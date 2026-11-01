# procurve template -- state machine

State machine of the `procurve` generic-model template (selected with
`model=procurve`), parsed from `templates/procurve.tmpl`. HP ProCurve. See
[README.template_engine.html](../README.template_engine.html) for the engine
and grammar and [README.generic-model.html](../README.generic-model.html) for
selecting the model in the device table.

## Template settings

- status: Verified on real hardware.
- transport: `ssh telnet`
- prompt: head `'(?:\x1b\[[\d;?]*[A-Za-z])*'`, tail `'# ?'` (the bareword `prompt` = head + learned hostname + tail)
- show command: sent as a literal in the show state (see the table)
- saved file starts at: `capture_from /^;/`
- `strip_ansi yes`
- legacy SSH options: `ssh_extra_opts` set (old kex/cipher)
- global interrupts (matched at any expect):
  - `/Press any key to continue/` -> `send_nolf " "`
  - `/Do you want to log out \[y\/n\]/` -> `send_nolf "y"`
  - `/Do you want to save current config/` -> `send_nolf "y"`
- timeouts: banner 45s, fetch 180s, max_visits 8

## State machine

```text
  entry:
    transport ssh    -> state_login_ssh
    transport telnet -> state_login_telnet

  state_login_ssh
      at prompt          -> send no page           -> show
      menu               -> send_match             -> state_login_ssh (loop)
  state_login_telnet
      username           -> send user              -> state_password_telnet
      password           -> send password          -> reach_cli
  state_password_telnet
      password           -> send password          -> reach_cli
  reach_cli
      at prompt          -> send no page           -> show
      menu               -> send_match             -> reach_cli (loop)
  show
      at prompt          -> send show running-config -> capture
  capture
      at prompt          -> capture_stop           -> logout
      (capture_start on entry)
  logout
      (send)             -> send exit              -> done

  (any expect may also match a global interrupt, handled automatically)
```
<!--MERMAID
stateDiagram-v2
    [*] --> state_login_ssh: transport ssh
    [*] --> state_login_telnet: transport telnet
    state_login_ssh --> show: at prompt, send no page
    state_login_ssh --> state_login_ssh: menu, send_match
    state_login_telnet --> state_password_telnet: username, send user
    state_login_telnet --> reach_cli: password, send password
    state_password_telnet --> reach_cli: password, send password
    reach_cli --> show: at prompt, send no page
    reach_cli --> reach_cli: menu, send_match
    show --> capture: at prompt, send show running-config
    capture --> logout: at prompt, capture_stop
    logout --> [*]: send exit
MERMAID-->

## States

| State | Waits for (expect) | Action | Next |
|-------|--------------------|--------|------|
| `state_login_ssh` | `prompt` | `send "no page"` | `show` |
|  | `/(\d+)\. Command Line \(CLI\)/` | `send_match` | `state_login_ssh` (loop) |
| `state_login_telnet` | `/Username:/` | `send user` | `state_password_telnet` |
|  | `/Password:/` | `send_secret pass` | `reach_cli` |
| `state_password_telnet` | `/Password:/` | `send_secret pass` | `reach_cli` |
| `reach_cli` | `prompt` | `send "no page"` | `show` |
|  | `/(\d+)\. Command Line \(CLI\)/` | `send_match` | `reach_cli` (loop) |
| `show` | `prompt` | `send "show running-config"` | `capture` |
| `capture` | `prompt` | `capture_start` on entry, then `capture_stop` | `logout` |
| `logout` | (standalone send) | `send "exit"` | `done` |

States with more than one expect try them in order; the first match wins. A self-loop (a state that targets itself) is bounded by `max_visits`. Global interrupt patterns can match at any expect (they are not shown as edges); each sends a keystroke and re-enters the state.

## Template source

Full source of `templates/procurve.tmpl`:

```
# procurve.tmpl - HP ProCurve (menu/VT100 firmware) over telnet or SSH.
#
# syntax_style: procurve
#
# The hard case: a full-screen VT100 CLI. The switch prints "Press any key
# to continue", may drop into an ASCII menu, and cursor-addresses its
# prompt (ESC sequences around the hostname). strip_ansi makes the output
# readable; prompt_head consumes the leading escapes; the interrupt screens
# dismiss the banners/menus wherever they appear.
#
# Validated over telnet on two firmware families: R.11 (2610 series - banner,
# "Press any key", then the MANAGER-mode menu) and K.15 (banner straight to
# Username/Password, then the CLI prompt). Both converge on reach_cli, which
# takes the prompt directly or picks "Command Line (CLI)" from the menu.
# Other firmware may differ - confirm the pager command ("no page"), the menu
# keystrokes and the volatile ignore lines against your own switch. See
# README.generic-model.
#
# Note: Verified on real hardware.

transport      ssh telnet
banner_timeout 45
fetch_timeout  180
max_visits     8
strip_ansi     yes

# old switches need legacy kex/cipher (matches the ProCurveSSH model)
ssh_extra_opts '-o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc,3des-cbc'

# the hostname is cursor-drawn; head consumes leading VT100 escapes,
# tail is the "# " (or "> ") the CLI ends with.
prompt_head    '(?:\x1b\[[\d;?]*[A-Za-z])*'
prompt_tail    '# ?'

# screens that can appear at ANY expect while we wait for the prompt
interrupt /Press any key to continue/          -> send_nolf " "
interrupt /Do you want to log out \[y\/n\]/    -> send_nolf "y"
interrupt /Do you want to save current config/ -> send_nolf "y"

# NOTE: the "; J... Configuration Editor" / "; Ver #..." header lines are
# STATIC (they change only on a firmware upgrade), so they are deliberately
# NOT ignored - an upgrade is a real change a backup should record. Add an
# ignore rule only for a line the switch rewrites on its own every read
# (confirm against your firmware); there may be none.

# ProCurve config starts at the "; ... Configuration Editor" comment (which
# must be KEPT). This drops only the echoed "show running-config" command and
# the "Running configuration:" preamble that precede it.
capture_from  /^;/     # ProCurve config starts at the "; Configuration Editor" line

# ---- SSH entry: authenticated; reach the CLI prompt (may pass a menu) ----
state state_login_ssh
    expect prompt          -> send "no page"       -> goto show   # already at CLI
    expect /(\d+)\. Command Line \(CLI\)/ -> send_match -> goto state_login_ssh  # pick CLI by its shown number
    # (Press any key handled by the global interrupt)

# ---- telnet entry: interactive login, then reach the CLI ----
state state_login_telnet
    expect /Username:/        -> send user            -> goto state_password_telnet
    expect /Password:/        -> send_secret pass      -> goto reach_cli

state state_password_telnet
    expect /Password:/        -> send_secret pass      -> goto reach_cli

# after telnet login: land on the CLI, or escape the menu (bounded loop)
state reach_cli
    expect prompt          -> send "no page"       -> goto show   # at CLI
    expect /(\d+)\. Command Line \(CLI\)/ -> send_match -> goto reach_cli  # pick CLI by its shown number

# response to "no page" (pager off) is the prompt; send the show command
state show
    expect prompt          -> send "show running-config" -> goto capture

# capture everything until the prompt returns
state capture
    capture_start
    expect prompt          -> capture_stop           -> goto logout

# already at the prompt - send exit without waiting (standalone send)
state logout
    send "exit" -> done
```

_Generated from `templates/procurve.tmpl` by `tools/gen-template-docs.pl`._
