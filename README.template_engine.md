# fetchconfig Generic Template Engine

This document describes the template-driven **generic model** for fetchconfig:
its architecture, the template grammar, the execution semantics, and how to
write, test and generate templates. It is written for a software engineer who
will author templates or work on the engine itself.

## 1. Why it exists

Historically each device family in fetchconfig is a Perl module under
`fetchconfig/model/` (about 150-300 lines) implementing a fixed interaction:
log in, enter enable mode, disable the pager, send a show command, capture the
output, log out. The models differ mostly in *data* - prompt strings, the
show command, which lines are volatile - not in *logic*.

The generic model factors that interaction out as **data**. A device is
described by a template (`templates/<name>.tmpl`); the model
`fetchconfig::model::GenericTemplate` interprets it. For a clean-CLI device a
template is a short file instead of a Perl module, and a family of similar
devices can share or clone one.

The engine has been verified against Cisco IOS-XE over both telnet and SSH and
against an HP ProCurve menu/VT100 switch. It is not a full terminal emulator
and does not aim to replace every hand-written model; a device whose behaviour
the state machine cannot express still needs Perl (see *Limitations*).

## 2. Architecture

Three pieces:

- **`GenericTemplateParser`** - pure function: parse template text into a
  structure, validate it, return `{ directives, states, interrupts, ignores,
  errors }`. No I/O, no device. Fully unit-tested (`t/40-template-parser.t`).
- **`GenericTemplate`** (the engine) - a `fetchconfig::model::Abstract`
  subclass registered as the model `generic`. It loads the template for a
  device, opens the transport (reusing `Abstract::ssh_open` for SSH), runs the
  state machine, captures the config, trims it, and hands it to
  `Abstract::dump_config`. The fetch pipeline (compare, discard-if-unchanged,
  expire, record) is inherited unchanged.
- **`tools/generate_template.pl`** - scaffolds a template *draft* from a
  session captured with `tools/record-session.pl` (see *Generating*).

The engine reuses the shared machinery in `Abstract`: `ssh_open`,
`wait_for_command_prompt`, `stripansi`, `regexp_quote_keep_bytes`,
`print_secret`, `dump_config`, `config_equal_ignoring_lines`. It adds only the
template interpreter.

## 3. Selecting the model

In the device table:

```
generic  <dev_id>  <host>  model=<name>,transport=ssh|telnet,<options>
```

- `model=<name>` is **mandatory**; it loads `templates/<name>.tmpl`.
- `transport` is `ssh` or `telnet` (there is no `auto` yet). If omitted, the
  template's first-listed transport is used.
- A device-table option **overrides** the same-named template value. This is
  the standard two-layer resolution (`Abstract::dev_option`): the template is
  the model default, the device line is the per-device override.

All standard options apply: `user`, `pass`, `enable`, `repository`,
`timeout`, `keep`, `changes_only`, `on_fetch_run`, `on_fetch_cat`,
`timezone`, `filename_append_suffix`, `comment`, `debug`.

## 4. Template grammar

A template is line-oriented. `#` begins a comment **except** inside a
`/regex/`, a `"double-quoted"` or a `'single-quoted'` string. Blank lines are
ignored.

### 4.1 Directives (top of file)

All optional; defaults in parentheses.

| Directive | Meaning |
|---|---|
| `transport ssh telnet` | allowed transports, in preference order |
| `banner_timeout N` | seconds to wait for the first prompt (30) |
| `fetch_timeout N` | seconds to wait for the show output (base `timeout`) |
| `fetch_delay N` | seconds to pause after connect (0) |
| `prompt_settle N` | prompt settle time, ms (Abstract default) |
| `max_visits N` | global cap on self-loops (8) |
| `strip_ansi yes\|no` | strip VT100/ANSI escapes from device output (no) |
| `prompt_head 'REGEX'` | matched before the learned hostname (empty) |
| `prompt_tail 'REGEX'` | matched after it (`#`) |
| `ssh_extra_opts 'STRING'` | extra ssh client options (legacy crypto) |

### 4.2 Trimming the saved config

The capture is the text between the show-command send and the next prompt; it
begins with the device echoing the command and any preamble ("Building
configuration...", "Running configuration:"). Trim it with one of:

| Directive | Meaning |
|---|---|
| `capture_from /regex/` | start the saved file at the first line matching the regex (keeps that line). Self-adjusting. |
| `skip_first N` | drop exactly the first N captured lines (fixed count). |

If both are given, `skip_first` is applied first, then `capture_from`. The
engine logs `dropped N leading noise line(s)...` and `fetched: N lines` (the
count actually saved).

Example (Cisco, matches a TFTP export):

```
capture_from  /^!/
```

### 4.3 Global lists

Checked/applied regardless of state:

- `interrupt /REGEX/ -> ACTION` - a screen that may appear at any prompt wait
  (a menu, "Press any key", a "[y/n]?" confirmation). Handled by
  `wait_for_command_prompt`.
- `ignore /REGEX/` - a line the device rewrites on its own every read
  (a timestamp, a re-salted hash). It is removed from **both** files before a
  `changes_only` comparison, so it does not cause a spurious backup. Do **not**
  ignore a line that reflects a real change (e.g. a firmware-version header
  that changes only on upgrade).

### 4.4 States

The engine starts at the reserved entry state for the chosen transport:

- `state_login_ssh` / `state_password_ssh`
- `state_login_telnet` / `state_password_telnet`

At least one of `state_login_ssh` / `state_login_telnet` must exist. SSH is
already authenticated when the session opens, so its entry state typically just
matches the prompt; telnet does interactive login. The two paths converge (via
`goto`) on the shared states.

Other states: `state <name> [max_visits N]`.

Inside a state:

```
expect PATTERN -> ACTION [-> goto STATE | -> done]
send "text" | send user|pass|enable [-> goto STATE | -> done]
send_secret pass|enable
send_nolf "text"
send_match
nop
capture_start
capture_stop
```

- `expect PATTERN` waits for `PATTERN` (a `/regex/` or the bareword `prompt`)
  then performs `ACTION`. **Multiple `expect`s in one state are tried in
  order, first match wins** - order the most specific first.
- `PATTERN = prompt` is the learned prompt:
  `prompt_head` + the byte-quoted hostname + `prompt_tail`, tolerating trailing
  VT100 escapes. The hostname is learned the first time a `prompt` expect
  matches, using a generic `(\S+)` capture.
- A **standalone `send`** (no preceding `expect`) sends immediately without
  waiting for a prompt - used after capture to send `exit` (the device is
  already at the prompt).
- `send_secret` sends a password, masked in the debug log (`print_secret`).
- `send_nolf` sends without a trailing newline (a pager space, a menu key).
- `send_match` sends the captured group `$1` from the state's matching
  `expect` regex, as a keystroke - e.g. pick a menu item by its shown number:
  `expect /(\d+)\. Command Line \(CLI\)/ -> send_match`. This survives a menu
  that renumbers its items.
- `capture_start` / `capture_stop` bracket the config: the saved config is the
  text captured between the show-command send and the closing prompt.

A transition is `-> goto STATE`, `-> done`, or (for a plain `expect` with no
arrow) an implicit re-entry of the same state ("stay"). A state that can
re-enter itself must be bounded by `max_visits`.

### 4.5 Validation

The parser rejects a template that could hang or misbehave, at load time:

- an unbounded self-loop (a state that can `goto` itself with no `max_visits`)
- a `goto` to an unknown state
- a missing or duplicated `capture_start` / `capture_stop`
- an unreachable state (from any transport entry state)
- no transport entry state
- a bad `transport` value

## 5. Execution semantics

For each state the engine:

1. Applies any `capture_start` in the state (turns capturing on).
2. If the state has a standalone `send`, performs it and transitions - no wait.
3. Otherwise builds one combined `waitfor` from the state's `expect` patterns
   (in order) plus the global `interrupt` patterns, with the state's timeout
   (`banner_timeout`, or `fetch_timeout` while capturing).
4. On a match, classifies which pattern matched (first wins). An `interrupt`
   sends its keystroke and re-enters the state. A `prompt` learns the hostname
   on first match. The matched `expect`'s `ACTION` runs, then its transition.
5. While capturing, the text before each matched prompt (the `prematch`) is
   accumulated, ANSI-stripped if `strip_ansi yes`.
6. On `capture_stop`, capturing ends and `capture_done` is set.

A state that times out logs which patterns it was waiting for. Self-loops are
bounded by `max_visits`; there is also an absolute per-fetch step budget.

**Saving.** If capture completed, the config is saved even if a later step
(e.g. logout) fails - a clean logout is cosmetic, the config is the
deliverable. After capture, `skip_first` then `capture_from` trim the leading
noise, the dropped and saved counts are logged, and `dump_config` writes the
file.

**Security.** With `debug=on` the telnet session log (`dump_log`) is written
0600, and passwords sent via `send_secret` are kept out of it (`print_secret`
disables logging around the send and writes a marker). Masking of secrets the
*device* prints (config hashes, SNMP communities) is the operator's job via
`ignore` or by reviewing the file. This is best effort.

## 6. Writing a template

1. Capture a real session with `tools/record-session.pl` - it produces a
   byte-accurate `.hex` and a readable `.txt` (see `README.record-session`).
2. Either write the template by hand from the `.txt`/`.hex`, or scaffold a
   draft with `generate_template.pl` (below) and edit it.
3. Set `transport`, the login states, the prompt (`prompt_head`/`prompt_tail`),
   the show command, and the capture markers.
4. Add `capture_from` (or `skip_first`) so the saved file starts at the real
   config.
5. Add `interrupt` lines for any menu/banner/confirmation screens, and
   `ignore` lines for genuinely volatile config lines (needs two captures
   minutes apart to identify).
6. Test against the device with the generic model; check the saved file and
   the `dropped`/`fetched` log lines.

See `templates/cisco-ios.tmpl` (telnet + SSH, clean CLI) and
`templates/procurve.tmpl` (menu/VT100, with `strip_ansi`, interrupts, a
menu-or-shell branch and `send_match`) for worked examples.

## 7. Generating a template

```
tools/generate_template.pl -f SESSION.hex [-t ssh|telnet] [-o OUT.tmpl]
```

It reconstructs the device and input streams from the `.hex`, infers the
transport, the prompt (host and tail), whether the device is VT100 (->
`strip_ansi` and an escape-consuming `prompt_head`), and the show command that
was typed. It emits an annotated template with `# TODO` markers for the
judgment calls a single capture cannot reveal: which lines are volatile, the
pager command, menu handling. **The output is a draft to review and test, not
a finished template.**

## 8. Limitations

- `transport=auto` is not implemented.
- There is no escape-hatch to a named Perl helper: a device whose behaviour
  the state machine cannot express still needs a Perl model.
- The prompt learner assumes the prompt is a hostname token followed by
  `prompt_tail`; a device with a radically different prompt needs custom
  `prompt_head`/`prompt_tail`.
- `skip_first` is a fixed count; prefer `capture_from` when the preamble
  length varies between firmware versions.
- Everything device-facing must be verified on real hardware; a capture shows
  one session, not every path a device can take.
