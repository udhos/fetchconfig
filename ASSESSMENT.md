# fetchconfig 9.64 — Assessment Report

Scope: source-code logic, HTML documentation accuracy and structure, and the
generic-model template grammar. This is a review only; no code was changed.

## Summary

The codebase is in good shape overall: 43 modules and `fetchconfig.pl`
compile cleanly, the test suite (11 files) passes, and the version string is
consistent across `Constants.pm`, both tools, and the HTML pill (all `9.64`).
The documentation largely matches the code. However, the review found **one
security-relevant logic bug** (the directory allowlist can be bypassed via a
`default:` line), two minor compile warnings, several template-grammar
clarity issues, and some documentation-structure improvements worth making.

Severity legend: **[HIGH]** correctness/security, **[MED]** clarity/maintenance,
**[LOW]** polish.

---

## 1. Source code — logical errors and inconsistencies

### 1.1 [HIGH] Directory allowlist is bypassed by `default:` values

The allowlist enforcement in `Detector::fetch_device` reads the option
directly from the per-device hash:

```
my $val = $dev_opt_tab->{$opt};      # repository / template_dir
```

`$dev_opt_tab` holds only options written **on the device line**. A value
inherited from a `default:` line lives in the model's `default_options`, not
in `$dev_opt_tab`. Consequently, when `repository=` (or `template_dir=`, or
`on_fetch_run`) is set **only** via a `default:` line, the enforcement reads
`undef`, skips the check, and the value is never validated.

Reproduction (verified):

```
directory: repository $REPO1 /tmp/cfg
directory: template   $TPL1  /tmp/cfg
directory: fetch_run  none
default: cisco-ios repository=/etc/EVIL_OFF_LIST
cisco-ios sw1 10.0.0.1 user=a,pass=b
```

The device inherits `/etc/EVIL_OFF_LIST`, no "not allowed" error is emitted,
and fetchconfig proceeds to write under `/etc/EVIL_OFF_LIST`. The code comment
at that site explicitly claims the `default:` case is handled ("a value from a
default: line rejects every device that inherits it") — the behaviour does
not match the comment.

Impact: the allowlist — a security control specifically meant to stop a
less-trusted editor from redirecting paths — can be circumvented by placing
the off-list value on a `default:` line. Since `default:` lines are common
(the shipped device tables set `repository=`/`template_dir=` almost entirely
via `default:`), this is not an edge case.

Recommended fix: the enforcement must validate the **effective** value
(default + device merge), not the raw device-line value. This interacts with
item 1.2: `dev_option` now expands aliases, so the check needs the effective
**pre-expansion** value. Options: (a) add a `dev_option_raw` accessor that
merges default+device but does not expand, and check that; or (b) validate in
`dev_option` itself for the three directory options. Either restores the
intended guarantee for `default:`-inherited values.

### 1.2 [MED] Central alias expansion vs. enforcement — a design tension

Alias expansion was centralised in `Abstract::dev_option` (correct — it fixed
`-l`/`-g`/etc.). But this creates a subtlety: `dev_option` now returns
expanded paths, while the allowlist enforcement wants the raw value to
validate. Today they read from different places (`dev_option` vs. raw
`$dev_opt_tab`), which is why 1.1 slips through for `default:` values. The two
concerns — *expand for consumers* and *validate for security* — should be
reconciled deliberately (see 1.1 fix). As written, a reader has to trace two
code paths to understand what value a device actually uses.

### 1.3 [LOW] `_expand_dir_alias` passes an off-list value through unchanged

When a value is off the allowlist, `_expand_dir_alias` returns it verbatim.
For read-only commands (`-l`, `-o`, …) this means they operate on the literal
off-list path (typically finding nothing, which is harmless). It is not a
leak, but it means a read command gives no signal that the path is off-list —
it silently looks in the wrong place. Low risk; worth a one-line note in the
code that reads are not gated by the allowlist (only fetch is).

### 1.4 [LOW] Allowlist state is package-global with no reset

`%dir_allow_tag`, `%dir_allow_path`, `$dir_allow_present`, `@dir_allow_rows`,
`@dir_allow_errors` are file-scoped `my` variables populated by
`parse_directory_line`. They are never reset. In the normal one-shot CLI this
is fine (one parse per process). It would be a latent bug if the parser were
ever invoked twice in one process (e.g. a long-lived daemon, or a future test
that parses two tables): the second table would inherit the first's
allowlist. Recommend an explicit reset at the start of a device-table load,
or documenting the single-load assumption.

### 1.5 [LOW] Two "used only once" compile warnings

`perl -c` reports:

- `fetchconfig/Mailer.pm:616` — `IO::Socket::SSL::SSL_ERROR` used only once.
- `fetchconfig/model/GenericTemplate.pm:72` — `FindBin::Bin` used only once.

Both are harmless (the symbols are real), but they clutter `perl -c` /
`make test` output the way the `t/42` warnings did before they were fixed.
A `no warnings 'once';` at those sites, or referencing the symbol via a
fully-qualified `our`, would silence them.

---

## 2. HTML documentation — accuracy and structure

### 2.1 Accuracy: good, matches the code

Spot-checks confirm the HTML matches the implementation:

- Every CLI flag has a flag-card (`-g -l -n -m -z -Z -o -e -D -T -s -S -t
  --list-allowed-dirs --check-template -P -f -v -h`).
- The `-t` output format documented (`<id> <section> <full_path> <model>
  <template_dir>`) matches the five columns the code emits.
- The directory-allowlist section documents all three types and the `none`
  form, consistent with the parser.
- The version pill (`v9.64`) matches `Constants.pm`.

One documentation statement is now **incorrect because of bug 1.1**: the
directory-allowlist section implies a `default:`-inherited value is enforced.
Until 1.1 is fixed, the docs over-promise. (Fix the code, not the docs.)

### 2.2 [MED] Section order is not a natural reading flow

Current order:

```
... 5 Usage
    6 Parallel fetching        <- a niche feature, before the basics
    7 Device table
    8 Directory allowlist
    9 E-mail notifications
   10 Device table on the command line
   11 Retrieving a previously backed-up config
   12 Device support
   13 Template-driven model
   14 Troubleshooting
   15 Options reference
   16 Security notes ...
```

Problems:

- **Parallel fetching (6)** sits between Usage and Device table, ahead of the
  fundamentals a new reader needs. It reads like an advanced topic promoted
  too early.
- **Device table (7)** and **Device table on the command line (10)** are
  split by three unrelated sections; they belong together.
- **Retrieving (11)** and **Options reference (15)** are both reference
  material but are far apart, with feature sections in between.

Suggested flow (professional-doc shape: overview → setup → core config →
features → reference):

```
Introduction, License, Installation, Perl module requirements   (front matter)
Usage                                                            (getting started)
Device table, Device table on the command line, Directory allowlist  (configuration)
Template-driven model, Device support                           (what it supports)
Parallel fetching, E-mail notifications, Retrieving a config    (features)
Options reference, Troubleshooting, Security notes, Status file,
  ProCurve SNMP backups, Web UI backups                         (reference)
```

### 2.3 [LOW] "Options reference" vs. the README "COMMAND-LINE OPTIONS"

The README groups options (Retrieval / Housekeeping / Template / Fetching /
Output / Generic). The HTML flag-reference now uses the same `<h4>` groups —
good, they are consistent. No action needed; noted for completeness.

### 2.4 [LOW] Professional-doc polish

- Add a short **table of contents / on-page summary** at the top of the body
  (the nav sidebar exists, but a one-line "what this page covers" helps).
- The **Directory allowlist** subtitle was just corrected to mention
  `on_fetch_run=`; verify the same completeness in the Security notes section
  (it should cross-reference the allowlist as a mitigation).
- Consider a brief **"Concepts"** paragraph early on defining the three
  moving parts a new user meets: the *device table*, a *model*, and the
  *repository*. The docs currently assume these.

---

## 3. Template state-machine grammar

The grammar is expressive and the engine is proven on real devices, but the
surface syntax has inconsistencies that make templates harder to read and
write than they should be.

### 3.1 [MED] Two different state-declaration syntaxes

Entry states are barewords with no keyword:

```
state_login_ssh
    expect ...
```

Ordinary states use a `state` keyword:

```
state after_login
    expect ...
```

So `state_login_ssh` and `state after_login` are both "states" but declared
differently. A reader cannot tell from the first token whether a line starts
a state. Recommend one consistent form — either require the keyword for all
(`state state_login_ssh`), or, better, make the entry states a directive
(e.g. `entry ssh -> login_ssh`) so the reserved names are not magic barewords.

### 3.2 [MED] The `enable_pw` / `pager` redundancy in cisco-ios.tmpl

```
state enable_pw
    expect /Password: $/  -> send_secret enable -> goto pager
    expect prompt         -> send "term len 0"  -> goto show    # (A)

state pager
    expect prompt         -> send "term len 0"  -> goto show    # (B)
```

Lines (A) and (B) do the same thing. The "already enabled" branch of
`enable_pw` jumps straight to `show` after sending `term len 0`, so `pager`
is only reached from the enable-password branch. This works, but the two
identical `send "term len 0" -> goto show` steps are confusing and look like
a copy-paste artefact. The example template — which doubles as the grammar's
worked reference — should be tightened so newcomers do not copy the pattern.

### 3.3 [LOW] Implicit "stay" transition is undocumented in the template itself

An `expect` with no `-> goto`/`-> done` re-enters the same state (bounded by
`max_visits`). This is powerful but invisible in a template; nothing on the
line signals "loop here." Recommend either an explicit `-> stay` keyword or a
prominent note in the grammar docs, so a self-loop is not accidental.

### 3.4 [LOW] Mixed quoting conventions

Within one template: regexes are `/.../`, literals are `"..."`, and directive
values are sometimes bare (`strip_ansi no`), sometimes single-quoted
(`prompt_head ''`, `prompt_tail '#'`). The rules are learnable but not
obvious. A short "lexical conventions" table in README.template_engine would
help (regex = slashes, string = double quotes, directive value = bare or
single-quoted).

### 3.5 [LOW] `send_match` / `send_nolf` / `send_secret` naming

The action vocabulary is good but the `send_*` family mixes concerns:
`send_secret` (masking), `send_nolf` (no newline), `send_match` (send a
captured group). A one-line comment table at the top of each shipped template,
or a grammar quick-reference, would reduce lookups. Minor.

---

## 4. Positive findings (what is solid)

- Clean compile of the whole tree; consistent `9.64` version everywhere.
- Test suite passes; good coverage of the parser, tools, config-equality,
  the template parser, shipped-template validation, and the directory
  allowlist.
- The central alias expansion in `dev_option` is the right architectural
  choice (order-independent, covers all read paths) — modulo reconciling it
  with enforcement (1.1/1.2).
- `--check-template` and `--list-allowed-dirs` double as linters with clear
  exit codes.
- Documentation is generated from Markdown for the READMEs (single source),
  and the flag reference is grouped consistently between README and HTML.
- Security posture is thoughtfully considered (debug-log masking,
  0600 files, the allowlist concept) — the allowlist just needs the 1.1 fix
  to actually hold.

---

## 5. Recommended priority

| Priority | Item | Type |
|---|---|---|
| 1 | 1.1 Allowlist bypass via `default:` values | security bug |
| 2 | 1.2 Reconcile central expansion with enforcement | design |
| 3 | 3.1 / 3.2 Template grammar consistency + example cleanup | clarity |
| 4 | 2.2 HTML section reorder | docs |
| 5 | 1.4 Allowlist state reset; 1.5 compile warnings | hardening |
| 6 | 2.4 / 3.3–3.5 Doc and grammar polish | polish |

The single item that should be addressed before relying on the directory
allowlist in production is **1.1** — until then the control is incomplete.
