# fetchconfig — How to Add a Device Model

*Programming manual for writing a new configuration extractor. Applies to fetchconfig 9.60.*

---

## 1. Scope and Audience

This manual is for a software engineer who has to make fetchconfig back up a device family it does not yet support. It assumes working Perl, familiarity with `Net::Telnet`-style expect programming, and access to at least one device of the new family (or a byte-accurate capture of a session with it).

It covers: what a model is and what the core expects from it (§2–§3), the step-by-step procedure (§4), two annotated skeletons you can copy (§5), how to verify a model without hardware and then with it (§6), the integration checklist (§7), and a complete reference of the shared functions available to a model (§8). Conventions that experience has shown to matter are collected in §9.

## 2. Concepts

**Model.** One Perl class per device family, in `fetchconfig/model/<Name>.pm`, inheriting `fetchconfig::model::Abstract` (or `fetchconfig::model::AbstractHTTP` for web-UI devices). A model knows how to talk to one CLI dialect; it knows nothing about repositories, comparison, expiry, e-mail, or parallelism — the core does all of that, identically for every model.

**Label.** The short string that names the model in the device table (`cisco-ios`, `procurve-ssh`, `mediant-sbc`). Lower-case, hyphenated; use a `-ssh` suffix only if a telnet model of the same family exists, otherwise select the transport with an option (see `mediant-sbc`).

**Device table.** The operator's configuration. Three line kinds:

```
default: <label>  key=value,key=value,...     model-wide defaults (repeatable; later wins)
email:   from=...,to=...,smtp=...
<label>  <dev_id>  <host[:port]>  [key=value,...]  a device; per-device options override defaults
```

Values containing commas or spaces are double-quoted. Your model reads options with `dev_option()`; you decide which are mandatory and reject a device that lacks them.

**Fetch pipeline (owned by the core, `Detector::fetch_device`).** For each device: call `$model->fetch(...)` → if it returned a saved file, compare with the previous backup (`config_equal`, which your model may override) → discard if unchanged and `changes_only` → expire beyond `keep=N` → record the result for the status file and the summary mail. A model that fails returns an empty list; the core logs the failure, records it, and moves to the next device. **A model never terminates the run.**

**Repository.** `<repository>/YYYYMM/YYYYMMDD/<dev_id>/<dev_id>.run.<timestamp><tz><suffix>`. Your model never builds this path; `dump_config()` does.

## 3. The Model Contract

A model must provide:

| Method | Provided by | Notes |
|---|---|---|
| `label()` | you | Returns the label string. |
| `new($log)` | `Abstract` | Inherit it. It sets up `default_options`, which the `default:` lines fill. Do **not** override unless you add state — and then call the parent. |
| `fetch($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab)` | you | Connect, log in, retrieve, log out, save. Returns `($config_dir, $config_file)` from `dump_config()`, or an **empty list** on failure (already logged). |

A model may override:

| Hook | Default | Purpose |
|---|---|---|
| `prompt_tail()` | `'#$'` | Regex after the quoted hostname in the enable prompt. `'# ?$'`, `' > $'`, `'> \(enable\) $'`, `'# '` (unanchored)… |
| `prompt_head()` | `''` | Regex before the hostname: `'\('` for `(host) #`, `'\['` for `[host-view]`, the VT100 escape prefix for switches that emit cursor codes before the prompt. |
| `config_equal(...)` | byte compare | Ignore volatile lines; see §9.4. |
| `ssh_extra_opts()` | `()` | Legacy crypto an old switch needs (`-o => "KexAlgorithms=+…"`). |
| `interrupt_screens()` | `()` | Screens that interpose before the prompt (banner, menu, save question) and the keystroke that dismisses each. |

Everything else — options, repository I/O, comparison, expiry, logging, SSH transport, escape stripping, prompt matching, pager driving — is in `Abstract` and documented in §8. **Use it. Do not copy code from another model into yours;** every copy that ever existed diverged and each divergence became a bug report.

## 4. Procedure

1. **Capture a real session** before writing a line of Perl. Over telnet, a raw capture (PuTTY *Logging → All session output*, not "Printable output" — that drops the control bytes you need). Over SSH, run an existing SSH model with `debug=on` against the device; the `.debug` file is a raw dump. You need: the login prompts, the exact prompt strings (trailing space or not!), the enable dialogue, the pager marker and — critically — the bytes the device sends *after* you dismiss the pager, the show command's first and last lines, the logout.
2. **Create `fetchconfig/model/<Name>.pm`** from the matching skeleton in §5. Fill in: label, prompt hooks, login/enable/fetch/logout steps.
3. **Register it** in `fetchconfig/model/Detector.pm`: one `use fetchconfig::model::<Name>;` and one `$class->register(fetchconfig::model::<Name>->new($log));`. Order in the register list is the order models are listed at startup; append at the end.
4. **Build a replay mock** from the capture and run the model against it until the saved file is byte-identical to the config in the capture (§6.1).
5. **Document** (§7): README device list and options block, `device_table.example`, the HTML documentation's model table, CHANGES.
6. **Bump the version** in `fetchconfig/Constants.pm` (a new model is a minor release).
7. **Live-verify** on the device with `debug=on`, twice: the second run must log "discarding config unchanged since last run" (§6.2).

## 5. Skeletons

Both skeletons are complete, compile against 9.60, and follow the conventions of §9. Replace the parts marked `<<…>>`.

### 5.1 Telnet model

```perl
package fetchconfig::model::Acme;   # fetchconfig/model/Acme.pm

use strict;
use warnings;
use Net::Telnet;
use fetchconfig::model::Abstract;

@fetchconfig::model::Acme::ISA = qw(fetchconfig::model::Abstract);

sub label { 'acme-os' }

# Prompt "hostname# " with a trailing space; "hostname> " is unprivileged.
sub prompt_tail { '# $' }

# "sub new" inherited from Abstract.

sub fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    my $saved_prefix = $self->{log}->prefix;
    $self->{log}->prefix("$saved_prefix: dev=$dev_id host=$dev_host");
    my @conf = $self->do_fetch($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);
    $self->{log}->prefix($saved_prefix);
    return @conf;
}

sub chat_login {
    my ($self, $t, $dev_user, $dev_pass, $dev_opt_tab) = @_;

    # chat_banner honours banner_timeout for the first prompt only.
    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, '/<<Username: >>$/');
    if (!defined($prematch)) {
        $self->log_error("could not find login prompt");
        return undef;
    }
    $self->log_debug("found login prompt: [$match]");
    return undef unless $t->print($dev_user);

    ($prematch, $match) = $t->waitfor(Match => '/<<Password: >>$/');
    if (!defined($prematch)) {
        $self->log_error("could not find password prompt");
        return undef;
    }
    return undef unless $t->print($dev_pass);

    # Learn the hostname from the first prompt. Quote it later with
    # regexp_quote_keep_bytes (the shared expect_enable_prompt does).
    ($prematch, $match) = $t->waitfor(Match => '/([\w.-]+)# $/');
    if (!defined($prematch)) {
        $self->log_error("could not find command prompt");
        return undef;
    }
    my $prompt = fetchconfig::model::Abstract::stripansi($match);
    $prompt =~ s/# $//;
    $self->log_debug("logged in prompt=[$prompt]");
    $prompt;                                   # prompt string, or undef on failure
}

sub chat_fetch {
    my ($self, $t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, $conf_ref) = @_;

    # Pager off if the device has a SESSION-ONLY command for it. Never a
    # command that changes the device's configuration (see §9.2).
    # Otherwise drive the pager as MediantSBC.pm does.
    $t->print('<<terminal length 0>>') or return 1;
    my ($prematch, $match) = $self->expect_enable_prompt($t, $prompt, undef, 'pager-off');
    return 1 unless defined($prematch);

    return 1 if $self->chat_show_conf($t, '<<show running-config>>', $show_cmd);

    my $save_timeout;
    if (defined($fetch_timeout)) { $save_timeout = $t->timeout; $t->timeout($fetch_timeout); }
    ($prematch, $match) = $self->expect_enable_prompt($t, $prompt, undef, 'fetching-config');
    $t->timeout($save_timeout) if defined($fetch_timeout);
    return 1 unless defined($prematch);
    $self->log_debug("found end of configuration: [" . fetchconfig::model::Abstract::stripansi($match) . "]");

    # Lines: strip CR (and escapes), split, drop the echo of the show
    # command and anything before the first real configuration line.
    $prematch = fetchconfig::model::Abstract::stripansi($prematch);
    @$conf_ref = split /\n/, $prematch;
    while (@$conf_ref && $conf_ref->[0] !~ /^<<version |^!>>/) { shift @$conf_ref; }
    if (!@$conf_ref) {
        $self->log_error("could not find start of configuration");
        return 1;
    }
    while (@$conf_ref && $conf_ref->[-1] =~ /^\s*$/) { pop @$conf_ref; }

    $self->log_debug("fetched: " . scalar @$conf_ref . " lines");
    undef;                                     # undef = success, 1 = failure
}

sub chat_logout {
    my ($self, $t) = @_;
    $t->print('<<exit>>');
    $self->log_debug("logged out");
}

sub do_fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    $self->log_debug("trying");

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
    my $dev_user       = $self->dev_option($dev_opt_tab, "user");
    my $dev_pass       = $self->dev_option($dev_opt_tab, "pass");
    foreach my $need ([repository => $dev_repository], [user => $dev_user], [pass => $dev_pass]) {
        if (!defined($need->[1])) {
            $self->log_error("$need->[0] needed but not provided");
            return;
        }
    }
    my $dev_timeout   = $self->dev_option($dev_opt_tab, "timeout");   # 30 s default, logged
    my $fetch_timeout = $self->dev_option($dev_opt_tab, "fetch_timeout");
    my $show_cmd      = $self->dev_option($dev_opt_tab, "show_cmd");

    my @telnet_args = (Errmode => 'return', Timeout => $dev_timeout);
    if ($self->dev_option_flag($dev_opt_tab, "debug", 0)) {
        push @telnet_args, (dump_log => "$dev_repository/$dev_id.debug");
    }
    my $t = Net::Telnet->new(@telnet_args);
    $self->secure_debug_file("$dev_repository/$dev_id.debug")
        if $self->dev_option_flag($dev_opt_tab, "debug", 0);   # 0600: it holds passwords

    my ($host, $port) = ($dev_host, 23);
    ($host, $port) = ($1, $2) if $dev_host =~ /^(.+):(\d+)$/;
    if (!$t->open(Host => $host, Port => $port)) {
        $self->log_error("could not connect: " . $t->errmsg);
        return;
    }
    $self->log_debug("connected");

    my $prompt = $self->chat_login($t, $dev_user, $dev_pass, $dev_opt_tab);
    return unless defined($prompt);

    my @config;
    my $failed = $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, \@config);
    $self->chat_logout($t);
    $t->close;
    return if $failed;
    $self->log_debug("disconnected");

    $self->dump_config($dev_id, $dev_opt_tab, \@config);   # ($dir, $file) or undef
}

1;
```

### 5.2 SSH model

Identical to 5.1 except for the connection. Replace `do_fetch`'s connection block with the shared transport; there is no login chat — SSH authenticated the user, and the session lands on the prompt:

```perl
sub do_fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;
    $self->log_debug("trying");
    # ... option reads and mandatory checks as in 5.1 ...

    my $debug_fh = $self->open_ssh_debug_file($dev_opt_tab, $dev_repository, $dev_id, $dev_host);
    my ($t, $ssh, $pid, $warn_guard) = $self->ssh_open($dev_host, $dev_user, $dev_pass, $dev_timeout, $debug_fh);
    return unless defined($t);            # error already logged
    # $ssh and $warn_guard MUST stay in scope for the whole session.

    # First prompt: settle, then match. prompt_settle_ms (default 150) lets
    # a slow banner finish before the broad token below is applied.
    $self->drain_until_idle($t, $self->dev_option($dev_opt_tab, "prompt_settle_ms") // 150);
    my ($prematch, $match) = $self->chat_banner($t, $dev_opt_tab, '/([^\r\n]*[^\r\n\s>#])# ?$/');
    return unless defined($prematch);
    my $prompt = fetchconfig::model::Abstract::stripansi($match); $prompt =~ s/# ?$//;
    $self->log_debug("logged in prompt=[$prompt]");

    my @config;
    my $failed = $self->chat_fetch($t, $dev_id, $dev_host, $prompt, $fetch_timeout, $show_cmd, \@config);
    $self->chat_logout($t);
    $t->close;
    waitpid($pid, 0) if defined($pid);      # reap the ssh shell
    return if $failed;
    $self->log_debug("disconnected");
    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

# An old switch that needs SHA1 kex / ssh-rsa / CBC re-enabled:
sub ssh_extra_opts {
    (-o => "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1",
     -o => "HostKeyAlgorithms=+ssh-rsa",
     -o => "Ciphers=+aes128-cbc,3des-cbc");
}
```

`ssh_open` loads `Net::OpenSSH` on first use, so a telnet-only installation is not forced to install it.

### 5.3 Where to look for worked examples

| Need | Read |
|---|---|
| Plainest telnet model | `CiscoIOS.pm` |
| Plainest SSH model | `CiscoIOSSSH.pm` |
| Unprivileged → `enable` → privileged, with rejection text | `MediantSBC.pm::chat_enable` |
| Driving a `--MORE--` pager and stripping its erase bytes | `MediantSBC.pm::chat_fetch` |
| Transport selectable by option, with a safe SSH→telnet fallback | `MediantSBC.pm::do_fetch` |
| Full-screen TUI with menus/banners before the prompt | `ProCurve.pm` (`interrupt_screens`) |
| Non-ASCII hostnames, prompt settle | `ArubaCXSSH.pm` |
| Volatile line ignored in comparison | `CiscoASA.pm`, `NexusSSH.pm`, `PLANET.pm` |
| Web UI (HTTP) model, binary config stored uuencoded | `TPLinkWebSG105E.pm`, `AbstractHTTP.pm` |
| SNMP + TFTP, no CLI at all | `ProCurveSNMP.pm` |

## 6. Verification

### 6.1 Without the device: replay mock

Write a small server that replays the captured bytes and reacts to the model's commands. The pattern that has worked (see the SBC10, 2610 and Comware mocks in the CHANGES history):

- Split the capture into the server's chunks, keyed by the client command that preceded each.
- Serve login prompts and the config body **byte-exact**, including line endings (`\r\n` vs `\r\r\n`), NULs, escape sequences, pager markers and their erase bytes.
- Have the mock **react**: advance only on the correct keystroke, so a wrong key shows up as a hang, not a pass.
- Run fetchconfig against it with a device table (`-devices=`), not `-line=` — a shell may mangle `!` and quotes in `-line=` values.
- Compare the saved file with the configuration in the capture **byte for byte**. "Looks right" is not a result; identical or a diff is.

Test the failure paths too: wrong login password, wrong enable password, a rejected pager command, a connection refused. Each must produce one clear `error:` line and an empty return, never a hang or a die.

Sandbox note: the `Net::Telnet` module is pure Perl; if it is missing, `perl -I<dir-with-Net/Telnet.pm>` against a copy of the module is enough to run the mock tests.

### 6.2 With the device

Run twice with `debug=on`:

1. First run: expect `connected`, the learned prompt in brackets, `found end of configuration`, `fetched: N lines`, a saved file. Inspect the file: first line is real configuration, last line is real configuration, no prompt text, no pager fragments, no `\r` or escape bytes (`grep -c -P '[\x08\x1b\r]' file` → 0), indentation intact.
2. Second run with `changes_only=1`: expect **"discarding config unchanged since last run"**. If it reports a change instead, `fetchconfig.pl -g <dev> -n 1 -m 2` shows the diff: either the device embeds a volatile line (§9.4) or your extraction is not deterministic.

Keep the `.debug` file of a successful run with the model's source: it is the only precise record of what the device sends, and the seed of the next mock.

## 7. Integration Checklist

- [ ] `fetchconfig/model/<Name>.pm` — header comment states the device family, firmware observed, transport, the session dialogue, and every option (mandatory/optional).
- [ ] `fetchconfig/model/Detector.pm` — `use` line and `register` line.
- [ ] `README` — device list entry (transport, what was observed), options block ("The `<label>` module recognizes the following options:"), intro sentence if it lists device families.
- [ ] `device_table.example` — a `default:` block with every option and a sample device line.
- [ ] `fetchconfig-documentation.html` — a row in the model table; the `debug` heading if the model writes a debug file.
- [ ] `CHANGES` — what, why, how verified (mock, live), and any one-time effect on existing backups.
- [ ] `fetchconfig/Constants.pm` — version bump.
- [ ] `perl -I. -c` on every changed file; the whole tree compiles.
- [ ] The mock replay and both live runs of §6 pass.

## 8. Shared API Reference

All of these live in `fetchconfig::model::Abstract` unless noted. "Method" means `$self->name(...)`; "function" means a plain call `fetchconfig::model::Abstract::name(...)`. Return conventions vary — they are stated per entry; new code should follow §9.1.

### 8.1 Options

**`dev_option($dev_opt_tab, $opt_name)`** — method. The option's value: device line, else the model's `default:` value, else `undef`. Exception: `timeout` returns **30** when unset and logs `Using 30s fetch timeout because the timeout was not set for this model`. Values are returned as written (quotes already removed).

**`dev_option_flag($dev_opt_tab, $opt_name, $default)`** — method. Boolean option: `1` if the value is `on` (case-insensitive), `0` otherwise; `$default` (truthy → 1) when unset. Use for `debug`, `changes_only`-style switches.

**`opt_trim($opt)`** — function. Trims surrounding whitespace.

**`dequote_value($val)`** — function. Removes one pair of surrounding double quotes.

**`mask_secrets($line)`** — function. Returns the device-table line with `pass=`, `enable=`, `community=`, `password=` values replaced by `***`. Use it before logging any table line.

### 8.2 Logging

**`log_debug($msg)`, `log_info($msg)`, `log_error($msg)`** — methods. Emit `<label>: <msg>` at the given level through the run's logger, with the per-device prefix that `fetch()` installed. Conventions: `debug` for every chat step (`trying`, `connected`, `found command prompt: [...]`, `cmd: [...]`, `found end of configuration: [...]`, `fetched: N lines`, `logged out`, `disconnected`); `info` for operator-relevant decisions (a transport fallback); `error` once per failure, with the device's own text where available (`enable rejected by the device: [Access denied]`). There is no warning level; use `info` with a `warning:` prefix.

The logger itself (`$self->{log}`) has `prefix([$new])`, `info`, `debug`, `error`.

### 8.3 Transport

**`ssh_open($dev_host, $dev_user, $dev_pass, $dev_timeout, $debug_fh)`** — method. Opens the SSH connection (`Net::OpenSSH`, password authentication, `StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`, `LogLevel=DEBUG` into `$debug_fh` when given, else `ERROR`), allocates a pty (`open2pty`) and wraps it in `Net::Telnet` (`Errmode 'return'`, `Timeout $dev_timeout`, `Telnetmode 0`, `Cmd_remove_mode 1`, `Output_record_separator "\r"`, `dump_log => $debug_fh` when given). Installs the `setsid` warning filter. Returns `($t, $ssh, $pid, $guard)` or an **empty list** (error logged; the error text is in `$self->{last_ssh_error}`). Keep `$ssh` and `$guard` in scope for the session; `waitpid($pid, 0)` when done. Adds `$self->ssh_extra_opts` to the master options. Loads `Net::OpenSSH` lazily.

**`ssh_extra_opts()`** — hook, default `()`. Return a list of `-o => "Option=value"` pairs.

**`open_ssh_debug_file($dev_opt_tab, $dev_repository, $dev_id, $dev_host)`** — method. If `debug=on`: opens `<repository>/<dev_id>.debug`, `chmod 0600`, autoflush, writes the header line, returns the handle. Else (or on open failure, logged) `undef`.

**`secure_debug_file($target)`** — method. `chmod 0600` on a path or an open handle. Call it on every file that records a session — they contain passwords as typed.

### 8.4 Prompt matching and chat

**`chat_banner($t, $dev_opt_tab, $login_pattern)`** — method. `waitfor(Match => $login_pattern)` with the timeout temporarily set to `banner_timeout` if that option is set. Returns `($prematch, $match)`; `$prematch` undefined on timeout. Use it for the **first** prompt of a session (login banners can be slow); plain `$t->waitfor` afterwards.

**`drain_until_idle($t, $settle_ms)`** — method. Reads until no byte has arrived for `$settle_ms` milliseconds, then pushes everything back into `Net::Telnet`'s buffer so a following `waitfor` sees it all. Non-consuming. Use before matching a prompt whose token is broad (spaces, non-ASCII) so a banner line ending in the prompt sign is not mistaken for the prompt. `$settle_ms <= 0` does nothing.

**`prompt_head()`, `prompt_tail()`** — hooks, defaults `''` and `'#$'`. Regex fragments placed before/after the byte-safely quoted hostname by `expect_enable_prompt`.

**`expect_enable_prompt($t, $prompt, $tail_override, $label)`** — method. Waits for `prompt_head . quote($prompt) . (tail_override // prompt_tail)`. Returns `($prematch, $match)`; `$prematch` undefined on timeout, with `[<label>: ]could not match enable command prompt: /regex/` logged. Use for every wait for the enable prompt after the first. Callers must not pre-escape `$prompt`.

**`wait_for_command_prompt($t, $prompt_regex, $label)`** — method. Waits for `$prompt_regex` (preceded by any VT100 escapes) **or** one of the model's `interrupt_screens`; on a screen, sends its keystroke and waits again; then a 1-second settle check for a screen trailing in behind an apparent prompt; bounded retries. Returns `($prematch, $match)` or `undef`. Run `$match` through `stripansi` before reading the hostname.

**`interrupt_screens()`** — hook, default `()`. List of `[regex_text, keystroke, debug_note_or_undef]`, e.g. `['Press any key to continue', ' ', undef]`, `['Main Menu', '5', undef]`, `['Do you want to save current configuration', 'y', 'saved running config']`. Keystrokes are sent raw with `put()` — no newline.

**`expect_enable_prompt_paging_auto($t, $prompt, $paging_prompt)`** — method. Waits for the enable prompt or `$paging_prompt` (a `--More--`-style marker); on the marker sends a space and continues; strips the marker with `escape_brackets`-quoted matching. Returns the accumulated `($prematch, $match)` or `undef`. Suitable when the device's erase sequence is simple; for a device that erases with backspaces adjacent to the next line's indentation, follow `MediantSBC.pm::chat_fetch` (sentinel at each page boundary, targeted strip) instead.

**`chat_show_conf($t, $show_cmd_default, $show_cmd_custom)`** — method. Sends `$show_cmd_custom // $show_cmd_default`, logs `cmd: [...]`. Returns `undef` on success, **`1`** on failure (logged).

**`regexp_quote_keep_bytes($str)`** — function. Escapes regex metacharacters (ASCII only) and leaves every other byte, including UTF-8 sequences, untouched. **Always** quote a learned prompt with this, never `quotemeta` (which mangles non-ASCII) and never raw interpolation (a `.` in a hostname then matches anything).

**`stripansi($str)`** — function. Removes CSI escape sequences (any parameter count, `?` private forms), two-byte escapes (`ESC E/M/D/7/8/=/>`), NUL and CR. Apply to prompts before reading the hostname and to captured configuration text before splitting into lines.

**`escape_brackets($str)`** — function. Legacy: escapes `@`, `[`, `]` only. Prefer `regexp_quote_keep_bytes`.

### 8.5 Configuration storage and comparison

**`dump_config($dev_id, $dev_opt_tab, $conf_ref)`** — method. Writes `@$conf_ref` (one line per element, newline-terminated) to the repository path for today, creating directories. Validates `filename_append_suffix` (must start with `.`, no `/` or whitespace). Honours `timezone=hide`. Returns `($config_dir, $config_file)`, or `undef` on failure (logged). This return value is what `fetch()` returns.

**`find_latest($dev_id, $dev_opt_tab)`** — method. `($dir, $file)` of the most recent backup by **parsed timestamp** (never string order — the timezone token varies by platform), or `undef` if none.

**`config_equal($prev_dir, $prev_file, $curr_dir, $curr_file)`** — method, overridable. Default: `File::Compare` byte equality. Returns true if equal.

**`config_equal_ignoring_lines($prev_dir, $prev_file, $curr_dir, $curr_file, $ignore_re)`** — method. Compares after removing every line matching `$ignore_re` from both files. Returns false if either file cannot be read (keeps the newer version). Wrap it in your `config_equal` override:

```perl
my $VOLATILE = qr/^!Time: /;             # NX-OS example
sub config_equal { my ($self, @a) = @_; $self->config_equal_ignoring_lines(@a, $VOLATILE) }
```

**`parse_backup_filename($dev_id, $file)`** — function. `($timestamp, $tz, $suffix)` from a backup file name; recognises `+0200`, `CEST`/`CET`, `-CEST`, multi-word Windows zones, and none.

**`sort_backups_desc($dev_id, $files_ref, $unparsed_ref)`** — function. Sorts file names newest first by parsed timestamp; unparsable names go to `@$unparsed_ref`.

The core calls `purge_ancient`, `config_discard`, `prune_dir_tree`, `scan_dir` itself; a model does not.

### 8.6 HTTP models (`AbstractHTTP`)

Inherit `fetchconfig::model::AbstractHTTP` and implement `http_login($ua, $base, $user, $pass, $dev_opt_tab)`, `http_backup(...)` and `http_logout(...)`; `AbstractHTTP::do_fetch` runs them with an `LWP::UserAgent` and cookie jar. Helpers: `http_request($ua, $req, $what, $timeout)` (one request with logging), `response_body($res)`, `accept_binary_response($res, $default_name)`, `uuencode_lines($filename, $binary)` (store a binary config as text; restore with `-g … | uudecode`), `open_debug`/`close_debug` (0600 trace of every request and response).

## 9. Conventions That Matter

### 9.1 Return values

The shared helpers carry two historical conventions: chat helpers return `($prematch, $match)` with `$prematch` undefined on failure; `chat_fetch`/`chat_show_conf` return `undef` on success and `1` on failure; `fetch`/`dump_config` return a value or nothing. **New code: return the useful value, `undef`/empty on failure, and log the error exactly once at the point of failure.** Never `die` inside a model — a failure of one device must not end the run.

### 9.2 Never modify the device

A backup tool reads. It must not enter configuration mode, change a setting, or save anything on the device — not even to make its own job easier (the AudioCodes pager could have been disabled with a configuration change; the model drives the pager instead). If a device offers a **session-only** command for a terminal setting at the exec level (`terminal length 0`), that is acceptable; anything under a `configure` mode is not.

### 9.3 Credentials

Never log a password or community string; log the device-table line only through `mask_secrets`. Any file that records a session (`dump_log`, HTTP trace, SSH debug) gets `secure_debug_file` (0600) at creation. Never retry a password over a second, weaker channel after an authentication failure (see `MediantSBC.pm`'s `transport=auto` rule: fall back to telnet only when no SSH service answered).

### 9.4 Volatile lines and `changes_only`

If the device rewrites a line on every read — a save timestamp (`!!: Written by …`), an uptime, `!Time:`, a re-salted password hash — `changes_only` will never discard a backup for that model. Override `config_equal` with `config_equal_ignoring_lines` and a tight regex for exactly that line. The line is still **stored**; it is only ignored for the comparison. Weigh what you ignore: the maintainer chose *not* to ignore Hirschmann's re-rendered password hashes because that would also hide a real password change.

### 9.5 Bytes, not characters

Devices send bytes: UTF-8 hostnames, `\r\r\n`, NULs, cursor escapes, backspaces. Match and quote at the byte level (`regexp_quote_keep_bytes`, `stripansi`), and verify with a raw capture, never with a terminal window or a printable log — both hide the very bytes that break extraction.

### 9.6 Timeouts

`timeout` (default 30 s) governs every `waitfor`; a long configuration needs `fetch_timeout` applied only around the show command (see the skeletons). A pager that is driven page by page is bounded by `timeout` per page, not by the total.

### 9.7 Debug file

`debug=on` must produce `<repository>/<dev_id>.debug`, mode 0600, and it should be the complete raw session: for SSH models the shared `open_ssh_debug_file` + `ssh_open` give the ssh client's `-v` trace followed by the session dump; for telnet, `dump_log`. The README documents this per model — keep it true.

---

*Generated documentation: `How-To-add-a-model.html` is produced from this file by `tools/md2html.py` (Python 2.7 / 3.x, no dependencies): `python tools/md2html.py How-To-add-a-model.md How-To-add-a-model.html`.*
