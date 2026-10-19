# fetchconfig -- Documentation

<!--stats-->
34 | device platforms
{version} | version
Telnet / SSH / HTTP / SNMP | transports
Linux / AIX / Windows | tested platforms
<!--/stats-->

A Perl script for retrieving and backing up the configuration of network devices at scale — over telnet, SSH or a device’s web UI, across dozens of vendors, with change tracking, e-mail summaries, and a repository you can script against.

<!--nav-group: Overview-->

## Introduction {#introduction}

fetchconfig is a Perl script for retrieving the configuration of multiple devices. It has been tested under Linux, AIX and Windows, and currently supports a variety of devices, including Cisco IOS, Cisco Catalyst, Cisco ASA, Cisco PIX, FortiGate Firewalls, ProCurve, Alcatel Ethernet Routers (aka Riverstone), Dell PowerConnect Switches, Terayon 3200/3500 CMTS, Datacom DmSwitch Switches, HP MSR Routers, Mikrotik Routers, Tellabs MSR Routers, Juniper EX Switch JunOS, Oracle Acme Packet, Audiocodes Mediant, Cisco IOS XR, NEC Univerge IX, Hirschmann Railswitch, Zyxel switches, PLANET managed switches, Aruba CX switches, Cisco Nexus switches, TP-Link Easy Smart switches, HP ProCurve 1700 series switches, and HP ProCurve ProVision (incl. 4000M/8000M) over SNMP+TFTP.

**Key concepts.** A *device table* lists the devices to back up, one per line, each naming a *model* (how to talk to that kind of device) and options. fetchconfig connects to each device, retrieves its configuration, and stores it in a *repository* (a dated directory tree), keeping a configurable history. Reading on: [Device table](#device-table) defines the input, [Template model](#template-model) covers the flexible generic model, and [Options reference](#options) lists every command-line option.

> [!warn] Important change in v9.55 (filename_append_suffix)
> Starting with v9.55, `filename_append_suffix` must start with a “.” (e.g. `.txt`). A device whose suffix lacks the leading dot, or contains `/` or whitespace, now **fails its backup** with an error and writes nothing. Fix any dotless suffix in your device table before the first v9.55 run. Also: do not add, remove or change a suffix on a device that already has backups; use `fetchconfig.pl -S` to find devices whose existing backups already mix suffixes.

> [!warn] Important change in v9.53 (affects every device)
> Saved configuration files now end with a trailing newline on the last line, matching the device’s own output (and a config downloaded from a device web UI). This touches **every** model. Because the file content changes by that one final byte, the **first** backup run after upgrading reports every device as “changed” and, with `changes_only`, saves a fresh copy — a one-time effect of the fix, not real drift. The second run onward compares clean.

## License {#license}

> [!note]
> fetchconfig — Retrieving configuration for multiple devices Copyright (C) 2006 Everton da Silva Marques
>
> fetchconfig is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2, or (at your option) any later version.
>
> fetchconfig is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
>
> You should have received a copy of the GNU General Public License along with fetchconfig; see the file `COPYING`. If not, write to the Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.

## Installation {#installation}

<!--tabs-->

<!--tab: UNIX / Linux-->

1. fetchconfig.pl expects a Perl interpreter at `/usr/bin/perl`.
2. Install the Perl modules you need — see [Perl module requirements](#modules). Most are in the Perl core (5.26+); the non-core ones are `Net::Telnet` and `Net::SMTP` (every run), `Net::OpenSSH` (SSH devices), `LWP::UserAgent`/`HTTP::Request::Common` (web-UI models), and `Net::SNMP`/`Net::TFTP` (`procurve-snmp`).
3. Unpack the fetchconfig tarball at a suitable location.

```shell
# fetchconfig tarball available at /tmp/fetchconfig-0.0.tar.gz
cd /usr/local
tar xzf /tmp/fetchconfig-0.0.tar.gz
ln -s fetchconfig-0.0 fetchconfig
# fetchconfig is now available under /usr/local/fetchconfig
```

<!--tab: Windows-->

1. fetchconfig.pl expects to find a Perl interpreter in the `PATH`.
2. Install the Perl modules you need — see [Perl module requirements](#modules). Most are in the Perl core (5.26+); the non-core ones are `Net::Telnet` and `Net::SMTP` (every run), `Net::OpenSSH` (SSH devices), `LWP::UserAgent`/`HTTP::Request::Common` (web-UI models), and `Net::SNMP`/`Net::TFTP` (`procurve-snmp`).
3. Unpack the fetchconfig tarball at a suitable location. From the command line, [gzip](http://www.gzip.org) and [tar](http://gnuwin32.sourceforge.net/packages/tar.htm) can be used — or a GUI archiver such as WinZip.

```cmd
:: fetchconfig tarball available at c:\temp\fetchconfig-0.0.tar.gz
c:
cd \
gzip -cd c:\temp\fetchconfig-0.0.tar.gz | tar xvf -
move fetchconfig-0.0 fetchconfig
:: fetchconfig is now available under c:\fetchconfig
```

<!--/tabs-->

## Perl module requirements {#modules}

fetchconfig runs on Perl 5.26 or later (tested on 5.26, 5.28 and 5.40; see the DEPENDENCIES file for the full module list and core-vs-CPAN status). Most of the modules it uses are in the Perl core on those versions and need no separate installation (`Text::ParseWords`, `POSIX`, `IO::Handle`, `Time::HiRes`, `MIME::Base64`, `FindBin`, `File::Temp`, `File::Path`, `File::Basename`, `File::Compare`, `Getopt::Long`, `Digest::SHA`). The modules below are **not** in the core and must be installed separately — but only if you use the devices that need them.

| Module(s) | Needed for |
|---|---|
| `Net::Telnet` | Every run. Telnet devices, and also driving the pseudo-terminal for all SSH devices — in practice fetchconfig cannot back up any device without it. |
| `Net::SMTP` | Every run. Part of the core *libnet* distribution (core since Perl 5.7.3), so no separate installation is needed. fetchconfig loads its reporting code on every run — it writes the per-device [status file](#status-file) even when no e-mail is configured — so this must be present regardless. No SMTP connection is made unless an `email:` line is configured. |
| `Net::OpenSSH` | All SSH-based models: `cisco-ios-ssh`, `cisco-asa-ssh`, `comware-ssh`, `procurve-ssh`, `planet-ssh`, `aruba-cx-ssh` and any other `*-ssh` model. |
| `LWP::UserAgent`, `HTTP::Request::Common` | The web-UI models `tplink-web-sg105e` and `procurve-web-1700` (no CLI). Both come with the *libwww-perl* distribution. |
| `Net::SNMP`, `Net::TFTP` | The `procurve-snmp` model (HP ProCurve ProVision, including the 4000M/8000M chassis), which backs up over SNMP + TFTP. |
| `IO::Socket::SSL` (needs `Net::SSLeay`) | Only if TLS is enabled for the summary e-mail (`email: tls=starttls` or `tls=ssl`). Plain SMTP does not need it. `Mozilla::CA` is optional, for a CA bundle where the system has none. |

```shell
# install the non-core modules you need, e.g.
cpan install Net::Telnet Net::OpenSSH
cpan install LWP::UserAgent Net::SNMP Net::TFTP
```

<!--nav-group: Getting started-->

## Usage {#usage}

1. Edit `device_table.example` according to your needs, and save it as `device_table`.

```
# fetchconfig available under /usr/local/fetchconfig
cd /usr/local/fetchconfig
cp device_table.example device_table
vi device_table
```

1. Run fetchconfig.pl:

```
cd /usr/local/fetchconfig
./fetchconfig.pl -devices=device_table
```

fetchconfig.pl scans the `device_table` file, tries to retrieve the configuration for every device, and stores the configuration files under the `repository`.

<!--nav-group: Configuration-->

## Device table {#device-table}

The device table assigned with `-devices=` is a text file that supports two types of lines.

### 1. Default-options lines

Assign default options to a device model. The following example adds default options to the `cisco-ios` model:

```device_table
#default	model		model-default-options
#
default:        cisco-ios       user=backup,pass=fran,enable=jose
```

### 2. Device lines

Define attributes of every device, and optionally assign device-specific options. The following example defines a device named `vpn-gw`:

```device_table
#model		dev-unique-id	device-host	[device-options]
#
cisco-ios       vpn-gw          192.168.0.1     keep=10,changes_only=1
```

> [!note] dev-unique-id constraints
> Must be (a) an unique identifier across all devices, and (b) a valid filesystem's directory name.

## Device table on the command line {#embedding} {nav: Device table on the CLI}

Valid lines for the device table file can also be passed directly through the `-line=`*string* switch.

```
/path/to/fetchconfig.pl -line="default: tellabs-msr user=backup,pass=s&cr&t,timeout=10,keep=5,changes_only=0,fetch_timeout=1200,filename_append_suffix=.txt,repository=/path/to/repo" -line="tellabs-msr lab-router 10.0.0.1"
```

## Directory allowlist {#directory-allowlist}

Restrict which directories a repository=, template_dir= or on_fetch_run= may name.

Optionally, the device table may restrict which directories a `repository=` or `template_dir=` option is allowed to name. This is useful when the device table is edited through a less-trusted front end (e.g. a web UI): the allowlist lives only in the real config file and cannot be widened from the UI, so an edit can never point a device at an arbitrary path.

With all three directory types allowed:

```
directory: repository $REPO1     /usr/local/fetchconfig/config
directory: template   $TEMPLATE1 /usr/local/fetchconfig/templates
directory: fetch_run  $CMD1      /var/fetchconfig/fetch_run
directory: report    $REP1       /var/www/fetchconfig/reports
```

With `on_fetch_run` disabled (`fetch_run none`):

```
directory: repository $REPO1     /usr/local/fetchconfig/config
directory: template   $TEMPLATE1 /usr/local/fetchconfig/templates
directory: fetch_run  none
```

Each line is `directory: <type> <$TAG> <path>`, where `type` is `repository`, `template`, `fetch_run`, `report` or `lock`, `$TAG` is a unique `$NAME` symbol, and `path` is the allowed directory. A section must cover **all four** types; `fetch_run` constrains `on_fetch_run=` (the directory of the command's program must be an allowed `fetch_run` directory), and `directory: fetch_run none` forbids `on_fetch_run` entirely.

Enforcement is **opt-in**: with no `directory:` line, nothing is restricted beyond the system-directory rule below (existing device tables are unaffected). The system-directory rule below always applies: a system directory is rejected whether or not an allowlist is present. Since v9.68 each distinct **non-system** `repository=`, `template_dir=` and `on_fetch_run` directory in use is then reported once per run as `warning: ... has no directory: allowlist entry (unrestricted ...)`, so you can see which paths are unrestricted and decide whether to add a `directory:` section (a system directory never reaches this warning - it is rejected first). With at least one present, every `repository=` and `template_dir=` used by a device (or inherited from a `default:` line) must be allowed:

- `repository=` must name a `repository` entry; `template_dir=` a `template` entry; `on_fetch_run=` must run a program in a `fetch_run` entry (types are not interchangeable).
- The value may be the `$TAG` or the literal path; a `$TAG` is expanded internally.
- Matching is exact, ignoring a single trailing slash. Paths are **not** canonicalized, so a symlinked, version-free path (e.g. `/usr/local/fetchconfig` &rarr; `/usr/local/fetchconfig-9.64`) is compared as written and the version stays hidden.
- Every path is checked for illegal content: no `/../` or `/./`, must be absolute, and only characters valid for the host OS.
- **System directories are never accepted, allowlist or not** (since v9.68): `/bin`, `/sbin`, `/lib`, `/lib64`, `/usr/bin`, `/usr/sbin`, `/usr/lib`, `/usr/lib64`, `/usr/share`, `/usr/include`, `/etc`, `/boot`, `/dev`, `/proc`, `/sys`, `/run`, `/var/run`, `/var/lock`, the root `/`, and anything under them. A `repository=`, `template_dir=` or `on_fetch_run` program there is rejected and the device skipped.

A value off the list, of the wrong type, an undefined tag, or with illegal content is rejected at fetch time with a clear error and that device is skipped; a bad value inherited from a `default:` line rejects every device that inherits it. `--list-allowed-dirs` prints the parsed allowlist.

<!--nav-group: Supported devices-->

## Template-driven model (generic) {#template-model} {nav: Template model}

Describe a device with a template instead of a Perl module.

Besides the per-device Perl models, fetchconfig has a `generic` model whose device interaction is described by a **template** file rather than Perl code. A template is a small state machine of expect/send steps, with the transport, prompt, timeouts, interrupt screens and ignore-lines as data. For a clean-CLI device this is a short file rather than a ~200-line module, and similar devices can share or clone one template.

A device selects it in the device table with the model `generic` and a template name:

```
generic  sw1  10.0.0.1  model=cisco-ios,transport=ssh,user=...
```

This loads `templates/cisco-ios.tmpl`; `transport` is `ssh` or `telnet`. Templates for Cisco IOS/IOS-XE (both transports) and HP ProCurve (menu/VT100) ship as worked examples. Two companion tools support the workflow: `tools/record-session.pl` captures a real session as a byte-accurate log to build a template from, and `tools/generate_template.pl` scaffolds a template draft from such a capture.

A template can be checked without a device:

```
./fetchconfig.pl --check-template templates/cisco-ios.tmpl
```

The argument must be the **full path** to the `.tmpl` file — a bare template name is not resolved, because the same name can exist in different `template_dir` directories. This runs the grammar and the load-time validator (self-loops, goto targets, capture markers, reachability, transport entry) and prints `ok` or the errors; it exits `0` ok, `1` errors, `2` file problem, and needs no device table. It is a **structural** check only — a template that passes may still need adjusting against the real device.

To list the templates available to the loaded devices:

```
./fetchconfig.pl -devices=device_table -t
```

`-t` (`--list-template`) scans every `template_dir=` a loaded device configures, plus the default template directory, and prints the template names it finds, numbered, one per line. Exit `0` if any template is found, `1` if none.

> [!plain] Further reading
> The generic model and its tools are documented separately:
>
> - [README.generic-model](README.generic-model.html) — the generic model and template grammar (quick reference)
> - [README.template_engine](README.template_engine.html) — the full engineering reference: architecture, grammar, execution semantics, writing and generating templates
> - [README.record-session](README.record-session.html) — the record-session.pl capture tool
> - [How to add a model](How-To-add-a-model.html) — writing a new per-device Perl model (the alternative to a template)

The template parser is production-ready; the execution engine has been verified on Cisco IOS-XE over telnet and SSH and on an HP ProCurve menu switch. Verify a template against the target device before relying on it.

## Device support {#device-support}

Known to be supported — not a comprehensive list. Other devices and versions are likely to work but haven't been verified.

| Model name | Devices / OS supported |
|---|---|
| `cisco-cat` | CatOS switches |
| `cisco-ios` | IOS routers — 2500 series, 2600 series, 2800 series, CS‑516 (with `show_cmd=wrterm`) |
| `cisco-asa` | Cisco ASA firewalls |
| `cisco-pix` | Cisco PIX firewalls |
| `cisco-iosxr` | Cisco IOS XR |
| `fortigate` | FortiOS 3.0 |
| `parks` | Parks 209R |
| `riverstone` | Alcatel Ethernet Router 3100 (Riverstone RS3100) |
| `terayon-os` | Terayon 3200/3500 CMTS |
| `dmswitch` | Datacom DmSwitch |
| `3com-msr` | 3Com MSR routers |
| `mikrotik` | MikroTik routers |
| `coriant-8600` | Coriant 8600 Smart Router Series |
| `tellabs-msr` | Tellabs MSR routers |
| `junos` | Juniper EX Switch JunOS |
| `acme` | Oracle Acme Packet |
| `mediant` | Audiocodes Mediant |
| `nec-univerge-ix` | NEC Univerge IX |
| `hirschmann` | Hirschmann Railswitch (L2E software, telnet) |
| `zyxel` | Zyxel switches (Cisco-IOS-like CLI, telnet) |
| `cisco-ios-ssh` | Cisco IOS over SSH (the SSH counterpart of `cisco-ios`) |
| `cisco-asa-ssh` | Cisco ASA over SSH (the SSH counterpart of `cisco-asa`) |
| `comware-ssh` | HP/H3C Comware switches over SSH (bracketed `<host>`/`[host]` prompt, no `enable` step) |
| `cisco-sg300` | Cisco SG300 small-business switches (Cisco-IOS-like CLI) |
| `dell` | Dell PowerConnect switches |
| `procurve` | HP ProCurve switches (telnet); see also `procurve-ssh` |
| `procurve-ssh` | HP ProCurve switches over SSH (the SSH counterpart of `procurve`; also handles a hostname containing spaces) |
| `planet-ssh` | PLANET managed switches (Cisco-IOS-like CLI, SSH; observed on IGS‑4215‑16P2T2S and IGS‑5225‑8P4S, also reported working on the M‑Series — with or without the switch’s own Username/Password dialog after the SSH login, with or without a “Building configuration…” banner, and whether one or two `exit`s end the session) |
| `aruba-cx-ssh` | Aruba CX switches (AOS-CX, SSH; observed on PL.10.17). Administrator account required — AOS-CX has no `enable`, an operator’s `>` prompt is reported as an error. Also backs up HPE Aruba Networking wireless access points running AOS-8 (confirmed on an AP model 515, AOS-8 8.13.2.2). |
| `nexus-ssh` | Cisco Nexus switches (NX-OS, SSH; observed on 10.4(7)). Administrator account required — NX-OS has no `enable`, a `>` prompt is reported as an error. The `!Time:` header line changes on every run and is ignored by `changes_only`. |
| `mediant-sbc` | AudioCodes Mediant SBC / gateway with the current Cisco-style CLI (“Welcome to AudioCodes CLI”; observed on a Mediant 500Li). SSH by default; `transport=telnet` or `auto` (telnet only if no SSH service answers, never after an authentication failure). Reads `show running-config full` from the privileged prompt after `enable`; pager disabled per session. Not the older menu-style CLI — that is `mediant`. |
| `procurve-snmp` | HP ProCurve ProVision, incl. the older 4000M/8000M chassis, over SNMP+TFTP (no CLI needed). See [ProCurve SNMP backups](#procurve-snmp). |
| `tplink-web-sg105e` | TP-Link Easy Smart switches (TL‑SG105E, TL‑SG105PE and siblings, HTTP web UI — these switches have no CLI). See [Web UI backups](#tplink). |
| `procurve-web-1700` | HP ProCurve 1700 series (1700‑8, 1700‑24; HTTP web UI — web-managed only, no CLI). See [Web UI backups](#tplink). |

Need a device that isn't listed? Two routes: describe it with a
 template (see [Template-driven model](#template-model) below),
 or write a per-device Perl model — see
 [How to add a model](How-To-add-a-model.html).

<!--nav-group: Features-->

## Parallel fetching {#parallel}

Fetching is sequential unless asked otherwise: one device at a time, in device-table order, every log line shown as it happens. With thousands of devices the run time is dominated by the network sessions (roughly 5–15 s each, plus a full timeout for every unreachable device), and a sequential run no longer fits in a night.

```shell
./fetchconfig.pl -devices=device_table -P 20
```

`-P N` fetches with `N` concurrent worker processes. The parent loads the device table, then hands out one device at a time to whichever worker asks next, so a slow device never holds up the others. Every worker is a copy of the fully loaded parent, so the models run unchanged. With `N` = 10–20 a run of several hours typically completes in well under one; the gain is bounded by what the devices and the network tolerate, not by the backup host.

> [!note] Output is atomic per device
> While a worker fetches, everything it writes to stdout and stderr is buffered; when the device finishes, the parent copies that buffer to the real streams in one uninterrupted block. One device’s output is therefore **never mixed with another’s** — each block looks exactly as in a sequential run. Two consequences: blocks appear in *completion* order, not table order; and a device’s lines appear when it finishes, not live. At `-P 1` nothing is buffered and behaviour is unchanged.

Everything else is unaffected: each device writes only its own directory, `.status` and `.debug`; the summary e-mail, per-device `to=` bundling and the `.status` files are produced by the parent from the workers’ results, exactly as in a sequential run. A worker that dies is detected by the parent; the device it was fetching is recorded as failed and the remaining devices are still fetched by the other workers.

**Sizing `N`.** Start at 10 and raise it while watching for devices that refuse or delay logins: the limits are the switches’ concurrent-session caps, the TACACS+/RADIUS rate, and the links to remote sites — not the backup host. 10–25 is typical. `-P` applies to fetching only and cannot be combined with the lookup/maintenance modes, which stay single-process.

## E-mail notifications {#email-notifications}

fetchconfig.pl can e-mail a summary of a run's backup results as an HTML table (Device‑ID, Date, Time, State, Size, Changes). This is entirely optional: unless an `email:` line is present, no SMTP connection is ever attempted.

The message is laid out as a white rounded card on a grey canvas, with a dark-blue (`#1f4e79`) header bar carrying a small logo and “fetchconfig vX.Y”, and the copyright footer below the card — matching the fetchconfig-web mails. The header logo is embedded in the message as a `multipart/related` inline image (`Content-ID <fcwlogo>`); it is independent of the `report_logo=` used inside the on-disk HTML report, which is unchanged.

### 1. Configure the sender, recipient, and SMTP server

Add an `email:` line to the default options section (it is independent of any device model):

```
#email:	options
#
email:	from=config.backup@acme.com,to=admin@acme.com,smtp=mail.acme.com
```

| Key | Requirement | Description |
|---|---|---|
| `from` | Mandatory | The envelope/header sender address. |
| `to` | Mandatory | Recipient who receives the status of every device backed up in the run. Multiple addresses are separated by `;` (not a comma, since commas already separate options). |
| `smtp` | Mandatory | SMTP server, as `host` or `host:port` (default port 25). Plain SMTP only — no encryption. |
| `user` | Optional | SMTP AUTH LOGIN username. |
| `password` | Optional | SMTP AUTH LOGIN password. Only used (and AUTH attempted) when `user` is also given. |
| `footer` | Optional | Copyright/attribution text shown in the summary e-mail's footer. The ` - Version <n>` that follows it is fixed and always appended. If the value contains a comma, wrap it in double quotes (the quotes are stripped). Default: `(c) 2006-2026 Everton da Silva Marques, Rainer Tammer and others`. |
| `port` | Optional | TCP port of the SMTP server; works with every `tls` setting. Precedence: an explicit `port=` beats a port given as part of the host (`smtp=mail.acme.com:587`), which beats the default. The default follows the TLS mode — 25 for `off`/`starttls`, 465 for `ssl` — so `tls=ssl` works without also setting the port. Must be 1–65535. |
| `tls` | Optional | Transport security for the SMTP connection: `off` (default, plain SMTP), `starttls` (connect in clear, upgrade with STARTTLS; typically port 25/587) or `ssl` (TLS from the start; typically port 465). Both TLS modes need `IO::Socket::SSL` (and `Net::SSLeay`); plain SMTP needs neither. If TLS is requested but unavailable, or the handshake fails, the mail is **not** sent — fetchconfig never falls back to plaintext. `AUTH LOGIN` sends the password base64-encoded (not encrypted), so use `tls` whenever the server is not on a trusted network. |

`email:` may be repeated; later values overwrite earlier ones for the same key (same rule as `default:`). A value may be wrapped in double quotes to include a comma (e.g. `footer="(c) 2026 ACME, Inc."`); the quotes are stripped.

### 2. Override the recipient per device

```
#model		dev-unique-id	hostname	device-options
#
parks		lab209r		10.30.0.6	to=lab-owner@acme.com
```

A device whose recipient was overridden this way is left out of no one's mail: it is bundled with every other device sharing that same override recipient into one separate e-mail, containing just their own device(s). The globally configured recipient still receives the status of every device processed in the run, including overridden ones.

### 3. The “Changes” column

Only reflects a changed-vs-previous comparison for devices where the run already performs one (`changes_only=1`, or `on_fetch_run`/`on_fetch_cat` set); for other devices it is reported as `n/a` — no extra repository scan is performed just for this report.

## Change reports {#change-reports}

An HTML report of what changed, with coloured diffs; summary in e-mail, full report via fetchconfig-web.

After a run fetchconfig can write a self-contained HTML change report (summary table plus a coloured diff per changed device) to an allowlisted `report` directory, and embed up to `email_max_diff` device diffs in the summary e-mail with a link to the full report. The report directory is presented by fetchconfig-web (view/download/delete) and is not meant to be served to users directly. Options on `email:` lines:

- `report_dir=$REP` — the report directory (a `report` allowlist entry).
- `write_report=on|off` — write the report. With `on` and no `from=/to=/smtp=`, only the report is written (no e-mail).
- `email_max_diff=N` — embed up to N changed devices' diffs in the e-mail (device-table order). Default `0` (no diffs); `0` or unset = none.
- `web_report_url=URL` — base URL of fetchconfig-web (the CGI itself, no query string, e.g. `https://host/cgi-bin/fetchconfig-web.cgi`); fetchconfig appends `?action=view_report&file=<report>` automatically for the e-mail's full-report link (emitted only when a report was written; any query string already on the value is ignored).
- `report_logo=FILE|none` — a logo in `report_dir`, embedded (self-contained), recommended 250×50 px.
- `report_days=N` — prune reports older than N days (only if N>1), by exact filename.
- `mask_secrets=on|off` — mask common secret forms in diffs (default on); master switch for all hiding.
- `report_hide=<regex>` — additional custom regex (one per line, accumulates); the matched substring becomes `****`. Governed by `mask_secrets`.

**Secret masking is best effort** — it masks common Cisco/ProCurve forms after diffing, on both old and new lines (a rotated secret shows as `**** &rarr; ****`), but is vendor-incomplete. Reports and report e-mails must be treated as sensitive; the stored configs in the repository still contain cleartext credentials regardless.

**Custom patterns.** For secrets the built-ins miss, add regexes with `report_hide`, one per line — only the substring each regex matches becomes `****`, so match just the value (a fixed-width lookbehind keeps the keyword):

```
email: report_hide=(?<=wpa-passphrase )\S+
email: report_hide=(?<=^key )[0-9a-f]{16,}
```

turning `wpa-passphrase c1ca253b...` into `wpa-passphrase ****`. Take care not to over-match (e.g. `(?<=secret )\S+` also fires inside `my-secret`). Patterns accumulate; comment a line out to disable it. They are governed by `mask_secrets` (with `mask_secrets=off` nothing is hidden), and an invalid regex is logged and skipped. For `report_hide` the whole rest of the line is taken verbatim as the regex — no comma splitting, no quote stripping, no space trimming — so a regex may contain commas (e.g. `{16,}`), `=` and spaces with no escaping. Do not wrap it in quotes (they would become part of the pattern). One regex per line.

Each device's diff is wrapped in an **armored** `<div class="device-diff" data-device="<id>" id="dev-<id>">` with a stable structure, so fetchconfig-web can parse it into an expandable per-device view. Treat this markup as a parse contract.

**Report directory setup.** So that fetchconfig-web (running as the web server's user/group) can read and manage the reports, set the report directory's group to the web server's group and set the setgid bit, e.g. `chgrp <webgroup> /var/www/fetchconfig/reports` and `chmod g+s /var/www/fetchconfig/reports`. With `g+s`, each report file inherits the directory's group automatically — fetchconfig needs no special privileges and does not change ownership itself.

## Retrieving a previously backed-up config {#retrieving} {nav: Retrieving backups}

In addition to fetching configuration from devices, fetchconfig.pl can retrieve a configuration file already saved in the repository, without contacting the device again — useful for scripting: dumping the latest config to stdout, comparing today's config against yesterday's, or pulling an older backup by its position in the history.

### 1. Retrieve the latest backup

```
./fetchconfig.pl -devices=device_table -g fw01.acme.net
```

### 2. Retrieve an older backup

```
./fetchconfig.pl -devices=device_table -g fw01.acme.net -n 2
```

### 3. List every backup on file

```
./fetchconfig.pl -devices=device_table -l fw01.acme.net
```

Sample output (tab-separated: number, size in bytes, path). The numbers in the first column are exactly what `-n`/`-m` expect.

```
1	28221	/usr/local/fetchconfig/config/202608/20260824/fw01.acme.net/fw01.acme.net.run.20260824.001105CEST
2	28221	/usr/local/fetchconfig/config/202608/20260823/fw01.acme.net/fw01.acme.net.run.20260823.001105CEST
```

### 4. Check for 0-byte backups

```
./fetchconfig.pl -devices=device_table -z fw01.acme.net
```

Catches a fetch that connected but failed to save anything. If any are found, they're listed like `-l` above and fetchconfig.pl exits 1; if none are found, nothing is printed and the exit status is 0.

### 5. Check every device at once

```
./fetchconfig.pl -devices=device_table -Z
```

Same as `-z`, but across every loaded device in one pass (tab-separated: dev_id, number, size, path). A device whose repository can't be read is logged and skipped without aborting the rest of the check.

### 6. Delete 0-byte backups

Add `-D` to delete the empty backups `-z`/`-Z` find — only the empty backup **files** (never directories), and only for devices still in the table, since `-z`/`-Z` look only at loaded devices (a decommissioned device’s leftovers are orphaned files, cleaned with `-o` above). Preview first with `-T`: the deletes are logged as `would delete: unlink <path>`, nothing is removed.

```
./fetchconfig.pl -devices=device_table -z fw01.acme.net -D -T    # preview
./fetchconfig.pl -devices=device_table -z fw01.acme.net -D       # delete
```

An emptied day/month directory is left in place; prune it afterwards with `-e -D`. The exit status is unchanged by `-D` — still 1 if any 0-byte backup was found, 0 otherwise.

### 7. Find orphaned backups

Configs on disk with no matching device in the table — e.g. left behind by a decommissioned or renamed device.

```
./fetchconfig.pl -devices=device_table -o
```

`-o` also lists a removed device's `<dev_id>.status` and `<dev_id>.debug` files at the repository root (not inside the dated directory); with `-D` they are deleted too. This clears a decommissioned device's debug log, which can hold credentials. To delete what `-o` found, add `-D`. Since this is destructive, preview it first with `-T` — the delete commands are only logged, never run:

```
./fetchconfig.pl -devices=device_table -o -D -T    # preview
./fetchconfig.pl -devices=device_table -o -D       # delete for real
```

### 8. Save to a file instead of stdout

```
./fetchconfig.pl -devices=device_table -g fw01.acme.net -n 2 -f config.file
```

### 9. Compare two backups

```
./fetchconfig.pl -devices=device_table -g fw01.acme.net -n 1 -m 2
```

Output matches the standard `diff older newer` convention: lines starting with `<` come from `-m` (older), lines starting with `>` come from `-n` (newer).

> [!note] stdout stays clean
> Log/diagnostic messages always go to stderr, so stdout only ever carries the retrieved config content — safe to pipe and redirect, e.g. `./fetchconfig.pl -devices=device_table -g fw01.acme.net > latest.cfg`.

### Flag reference

#### Retrieval options {.flag-group}

<!--flag: -g dev_id | mutually exclusive with -l / -z / -Z / -o / -e / -s / -S-->
Retrieval mode for `dev_id` instead of fetching from every device in the table(s). `dev_id` must match a device line's dev-unique-id.
<!--/flag-->

<!--flag: -l dev_id | mutually exclusive with -g / -z / -Z / -o / -e / -s / -S-->
Listing mode: prints one line per backup on file, newest first — `<number>\t<size>\t<path>`.
<!--/flag-->

<!--flag: -n N | optional-->
Selects which backup to retrieve, counting from the most recent: `N=1` latest (default), `N=2` the one before that, and so on.
<!--/flag-->

<!--flag: -m M | requires -g-->
Compare mode: prints a diff between backup `M` (older) and backup `N` (newer) instead of printing backup `N`. `M` must be numerically higher than `N`.

<!--exit-list-->
- 0 | the two backups are identical
- 1 | the two backups differ
- >1 | an error occurred
<!--/exit-list-->
<!--/flag-->

#### Housekeeping options {.flag-group}

<!--flag: -z dev_id | mutually exclusive with -g / -l / -Z / -o / -e / -s / -S-->
Zero-byte check for one device, same tab-separated format as `-l`. Nothing prints if no backups are 0 bytes.

<!--exit-list-->
- 1 | at least one 0-byte backup found
- 0 | all backups non-empty
<!--/exit-list-->
<!--/flag-->

<!--flag: -Z | mutually exclusive with -g / -l / -z / -o / -e / -s / -S-->
Same as `-z`, no dev_id — checks every loaded device: `<dev_id>\t<number>\t<size>\t<path>`. A device that can't be scanned is skipped and logged, and does not by itself cause a non-zero exit.
<!--/flag-->

<!--flag: -o | mutually exclusive with -g / -l / -z / -Z / -e / -s / -S-->
Orphaned-backup check: lists device directories on disk with no matching dev_id in the currently loaded table(s) — `<name>\t<file count>\t<total bytes>\t<path>`. Scans every `repository=` path configured by a currently loaded device (deduplicated); a path used only by a device no longer in the table can't be discovered this way.

<!--exit-list-->
- 1 | at least one orphan found (backup dir or status/debug file)
- 0 | none found
<!--/exit-list-->
<!--/flag-->

<!--flag: -e | mutually exclusive with -g/-l/-z/-Z/-o/-s/-S-->
Empty-directory check: scans every configured `repository=` path for empty directories in the three-level layout `<repository>/YYYYMM/YYYYMMDD/<dev_id>/` and lists them, one tab-separated row per directory: `level` (`device`, `day` or `month`) and `path`. The scan is bottom-up, so a day whose only content is an empty device directory, and a month whose only content is such a day, are listed too. Only names of the expected shape are candidates (`YYYYMM`; `YYYYMMDD` whose first six digits match the month; a dev_id-shaped name starting with a letter or digit) — anything else, and the repository root, is never touched. Such leftovers typically come from deleting old backups by hand. Honours `-f`.

With `-D` the directories are **deleted, bottom-up**: device dirs, then the day dirs empty by then, then the month dirs empty by then. Each removal is **one plain `rmdir` on the exact path** — no wildcards, no recursion; `rmdir` refuses a non-empty directory, so files can never be taken along. Every command is reported as `deleting: rmdir <path>`; rows gain a `deleted`/`failed` column. `-e -D -T` reports `would delete: rmdir <path>` and removes nothing.

<!--exit-list-->
- 0 | `-e`: no empty directories &middot; `-e -D`: every rmdir succeeded
- 1 | `-e`: empty directories found &middot; `-e -D`: at least one rmdir failed
<!--/exit-list-->
<!--/flag-->

<!--flag: -D | requires -o or -e-->
With `-e`: deletes the empty directories found (see `-e`). With `-o`: also deletes every orphaned device directory `-o` finds (and the orphaned `<dev_id>.status` / `<dev_id>.debug` files at the repository root), and since v9.56 then prunes the day (`YYYYMMDD`) and month (`YYYYMM`) directories this leaves empty — one plain `rmdir` each, only if empty, each reported. Each backup file is deleted individually by its exact name — never a wildcard, never `rm -rf` — logged as `rm <file>`, followed by `rmdir <path>` for the now-empty directory. Deletion uses Perl's own `unlink()`/`rmdir()`; no shell command is actually spawned. `rmdir()` only succeeds on a genuinely empty directory, so anything left behind unexpectedly makes that removal fail loudly rather than being swept away. A repository root itself is never deleted. With `-z` or `-Z`: deletes the 0-byte backup **files** found — one plain `unlink` on each exact path (never a directory), logged as `deleting: unlink <path>`; an emptied directory is left for a later `-e -D` to prune. `-D` requires one of `-o`, `-e`, `-z` or `-Z`.

<!--exit-list-->
- 1 | any deletion failed
- 0 | nothing needed deleting, or everything found was deleted
<!--/exit-list-->
<!--/flag-->

<!--flag: -T | requires -D-->
Preview mode for `-o -D`, `-e -D`, `-z -D` and `-Z -D`: logs the delete commands `-D` would run (`would delete: rmdir/unlink <path>`), without deleting anything. Exit status is that of the plain check — `-o`: 1 if anything orphaned was found; `-e`: 1 if any empty directory was found; `-z`/`-Z`: 1 if any 0-byte backup was found; 0 otherwise. Use it before a bare `-D` run.
<!--/flag-->

<!--flag: -s dev_id | mutually exclusive with -g/-l/-z/-Z/-o/-e/-S-->
Suffix-consistency check for one device: verifies that all of its backup files carry the same filename suffix. Reports the device if its backups mix suffixes — including “some with a suffix and some without”, which is what happens when `filename_append_suffix` was added or changed after backups already existed. Prints one tab-separated line per distinct suffix: `dev_id`, suffix (or `(none)`), count, example file. Prints nothing if consistent. An unknown `dev_id` exits 1. Honours `-f`.

A second step then compares the (single) suffix the backups use against the `filename_append_suffix` configured for the device and logs a warning if they differ — e.g. backups written before a suffix was configured. This step is skipped for a device whose backups are already inconsistent.

<!--exit-list-->
- 0 | backup suffixes are consistent, configured suffix matches backup file suffixes
- 1 | inconsistent backup suffixes (not checked against the configured suffix), or unknown device
- 2 | backup suffixes are consistent, but the configured suffix does not match them
<!--/exit-list-->
<!--/flag-->

<!--flag: -S | mutually exclusive with -g/-l/-z/-Z/-o/-e/-s-->
Like `-s`, but takes no `dev_id` and checks every device loaded via `-devices=`/`-line=`. `-S` is a pure consistency check — it does *not* compare against the configured `filename_append_suffix` (that second step is `-s dev_id` only). Exit 1 if any device’s backups mix suffixes, 0 otherwise. Note `-s` takes a `dev_id`: write `-s dev_id -f file` or `-S -f file`; `-s -f file` is rejected.
<!--/flag-->

> [!note] How -s / -S separate the timezone from the suffix
> A backup is named `<dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>`, and `<tz>` is whatever `strftime` produced on the backup host — it differs by platform and **changes with daylight saving time** (AIX: `CET` in winter, `CEST` in summer; older AIX `NFT`/`DFT`). The check parses the tz token first — numeric `+0200`/`-0500` (Linux, modern Windows), a bare name `CEST` (AIX), `-CEST` (Solaris), or a multi-word name such as `W. Europe Standard Time` (older Windows) — and only then looks at what follows, so a DST change is **not** reported as a suffix change. It **only works if the suffix is separated from the tz by** `.`, `-` or `_`: `.` is the rule since v9.55; `-` and `_` are accepted so backups written before that rule are still recognized. One inherent ambiguity: `-` followed by uppercase letters is the Solaris tz form, so an old suffix like `-BAK` on a `timezone=hide` backup (no tz token) is read as a tz; `_BAK`, `-bak`, or any suffix after a real tz token are unambiguous.

#### Template options (generic model) {.flag-group}

<!--flag: -t, --list-template | honours -f-->
Lists the generic-model templates available to the loaded devices, one TAB-separated row per template: `<id> <section> <full_path> <model> <template_dir>`. `section` is `default` (a template in the directory the `default:` scope uses — the `default: generic template_dir=` if set, else the program default `templates/` beside fetchconfig.pl; feeds the defaults editor) or `device` (a template in a device-specific `template_dir=`; feeds the device editor). `template_dir` is the configured value as written (a directory: `$TAG` or a literal path), so a consumer can filter by exactly what the table holds; `full_path` is always the real resolved path (a `$TAG` is expanded). A device configuring the same path as the default still yields `device` rows, so a model may appear under both sections; device directories are deduplicated by configured path (no device id in the output). Rows are sorted default first, then device; within a section by directory, then model. Every directory to be scanned — the default included — must exist; a missing configured path is reported and the exit status is `2` regardless of what else was found, otherwise `0` if any template was found, `1` if none. Honours `-f`. See [Template-driven model](#template-model).
<!--/flag-->

<!--flag: --list-allowed-dirs | honours -f-->
Lists the `directory:` allowlist configured in the device table (see [Directory allowlist](#directory-allowlist)), one TAB-separated row per entry: `<id> <type> <tag> <path>`. It also lints: exit `0` if a `directory:` section exists and every entry is valid (well-formed and its path exists on disk), `1` if no section, `2` if any entry is invalid.
<!--/flag-->

<!--flag: --check-template PATH | no device table-->
Structurally checks the generic-model template at PATH (grammar + the load-time validator) and exits. PATH must be the **full path** to the `.tmpl` file — a bare name is not resolved, as the same name can exist in different `template_dir` directories. Prints `ok` or the errors; exits `0` ok, `1` errors, `2` file problem. Structural check only. Does not honour `-f`. It needs no device table and does **not** apply the directory: allowlist — any readable `.tmpl` path is checked.
<!--/flag-->

<!--flag: --template-syntax PATH | no device table-->
Prints the syntax style a generic-model template declares — the value of a `# syntax_style: <token>` header comment — to **stdout**, and exits. This is metadata for a config viewer (e.g. fetchconfig-web) to pick a highlighter for a `generic`-model backup, whose `generic` model name says nothing about the output syntax; it has no effect on a backup. PATH is the full path to the `.tmpl` file, as for `--check-template`. Exits `0` and prints the token if declared, `1` and prints nothing if not, `2` on a file problem (error to stderr). Log output stays on stderr, so stdout carries only the value. It needs no device table and does **not** apply the directory: allowlist — any readable `.tmpl` path is read. The value is a free-text token `[A-Za-z0-9_-]+`. fetchconfig-web currently recognises `cisco-ios`, `procurve`, `comware`, `zyxel`, `aruba-cx`, `nexus`, `mediant`, `template`, `json`, `xml` and `generic`; the set is open, and any other or absent value lets the viewer fall back to plain text.
<!--/flag-->

#### Fetching options {.flag-group}

<!--flag: -P N | fetching only-->
Fetch with `N` concurrent worker processes (default 1 = sequential, device-table order, live output). With `N>1` each device’s output is buffered while it runs and shown as **one uninterrupted block** when it finishes, in completion order — never interleaved with another device. Not combinable with `-g`/`-l`/`-z`/`-Z`/`-o`/`-e`/`-s`/`-S`. See [Parallel fetching](#parallel).
<!--/flag-->

#### Output option {.flag-group}

<!--flag: -f file | optional-->
Writes the **result data** to `file` instead of stdout: the retrieved config (`-g`), the diff (`-m`), or the listing rows (`-l`, `-z`, `-Z`, `-o`, `-s`, `-S`, `-t`). The file is created/overwritten as needed. It does **not** apply to `--check-template`, whose ok/error result is written to the log only.

The file receives *only* that data — never the screen output. All `info:`/`debug:`/`error:` lines, including the “checked N backup(s), …” summary and the “wrote … to file” confirmation, are log messages and always go to stderr.

For the listing/check modes (`-l`, `-z`, `-Z`, `-o`, `-s`, `-S`) the result data **ends with one summary line prefixed by `#`**, carrying the same text the run logs — e.g. `# dev=sw01: checked 2 backup(s), no zero-byte backups found` — so the output is never empty and is self-describing: a reader can tell “checked, nothing found” from “nothing was written” without the exit status or stderr. The rows before it contain only the items *found*. The trailer is part of the result stream, so stdout and `-f` carry identical content. It is *not* added to `-g` or `-m`, which stay byte-exact.

> [!warn] Format change for parsers (v9.55)
> Anything that parses these listings — fetchconfig-web in particular — must skip lines starting with `#`. Before v9.55 a check that found nothing produced a 0-byte file.
<!--/flag-->

<!--flag: --clean-lock-dir [N] | no device table-->
Removes device lock files older than `N` days (by mtime) from the lock directory, then exits. With `-T`, only shows what **would** be removed (dry run). `N` defaults to `30`, minimum `1`. A lock file is removed **only if it is not currently held** — the cleaner `flock()`s each candidate first and keeps any live lock — so an in-use lock is never deleted. The lock directory is `<dir of fetchconfig.pl>/.lock` by default; pass `-devices=` if a custom `lock_dir=` applies. Exits `0` on success, `2` on a bad `N` or an unusable lock directory.
<!--/flag-->

#### Generic options {.flag-group}

<!--flag: -v, --version | version-->
Prints just the program version to stdout (one line, e.g. `9.72`) and exits with status 0. Nothing else is written — no banner, nothing on stderr — so a script can parse it safely.
<!--/flag-->

<!--flag: -?, -h, --help | help-->
Prints the usage/help text to stdout and exits with status 0. (Before v9.55, `-?` was treated as an unknown argument: it printed an error, the usage to stderr, and ended with “Died at …”.)
<!--/flag-->

> [!warn] Unknown device or missing backup
> If `dev_id` is unknown, or the device has no `repository` configured, fetchconfig.pl reports an error and exits non-zero; nothing is written to stdout or `-f`. Same if `-n` (or `-m`) refers to a backup that doesn't exist — use `-l` first if unsure how many backups exist. `-m` shells out to the standard `diff` utility, which must be available in `PATH`.

<!--nav-group: Reference-->

## Options reference {#options}

The modules `CiscoIOS`, `CiscoCAT`, `CiscoASA`, and `CiscoPIX` recognize the following options; nearly every other model reuses the same set (see the per-model matrix below for exactly which apply).

| Option | Requirement | Description |
|---|---|---|
| `pass` | Mandatory | The login password. |
| `user` | Optional | Login username. Can be omitted for devices not requiring one. |
| `enable` | Mandatory | The enable password. |
| `timeout` | Mandatory | How long to wait for TELNET responses from devices. |
| `fetch_timeout` | Optional | Overrides `timeout` specifically while fetching configuration lines — useful for devices that take several seconds to build the configuration. |
| `repository` | Mandatory | Base directory for saving configuration files. |
| `keep` | Mandatory | Maximum number of config files to retain per device; older files are discarded once the limit is reached. |
| `changes_only` | Optional | Boolean. If `changes_only=1`, only new configurations are saved. Otherwise the script may retain multiple identical files across runs. |
| `on_fetch_run` | Optional | Path to an external program called whenever a config is fetched. Passed `FETCHCONFIG_DEV_ID`, `FETCHCONFIG_DEV_HOST`, `FETCHCONFIG_PREV` (undefined if none), and `FETCHCONFIG_CURR`. Available for all modules. If `changes_only=1`, the file at `FETCHCONFIG_CURR` is erased right after the program finishes. The value is a **program plus optional literal arguments, not a shell command line**: since v9.68 it is split into words (quoting is honoured, e.g. `prog "two words"`) and executed directly, never through `/bin/sh`, so shell syntax such as `;`, `\|`, `$(...)` or `>` is passed to the program as plain text. To run a pipeline, put it in a script and name the script. The program may not live in a system directory (`/bin`, `/usr/lib`, `/etc`, … — see [Directory allowlist](#directory-allowlist)). |
| `lock` | Optional | `lock=on` takes an exclusive flock on the device before backing it up, so two runs cannot back up the same device at once (overlapping cron, or a web “Backup Now” over a cron run). Values are `on` or `off`; default `off`. The lock releases when the run ends (even on crash) and the lock file is never deleted. On contention the device is retried (see `lock_retry`/`lock_retry_time`) and then recorded as **skipped**; the process exit code is not changed. |
| `lock_dir` | Optional | Directory for the lock files — a `directory: lock` `$TAG` or an absolute path. Default `<dir of fetchconfig.pl>/.lock`, created `0700` if absent; if it cannot be created or used, fetchconfig exits `10` after the run. Must be a **local** filesystem (flock over NFS on AIX is unreliable); a system directory is refused. |
| `lock_retry` | Optional | How many times to retry a locked device before skipping. Integer &ge; 0; default `5`. `0` = skip on first contention. |
| `lock_retry_time` | Optional | Seconds between lock retries. Integer &ge; 1; default `10`. Maximum wait before skipping is `lock_retry × lock_retry_time` seconds. |
| `on_fetch_cat` | Optional | Boolean. If `on_fetch_cat=1`, the fetched configuration is also written to stdout. Available for all modules. |
| `timezone` | Optional | If `timezone=hide`, suppresses timezone information from the config filename. |
| `filename_append_suffix` | Optional | Appended to the generated backup filename, which then reads `<dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>`, e.g. `filename_append_suffix=.txt`. Available for all modules. **fetchconfig 9.x and later only accept a suffix that starts with a “.”** (a file extension); a dotless suffix, or one containing `/` or whitespace, fails that device’s backup with an error and writes nothing. **Do not add, remove or change the suffix once a device has backups** — files are found by their `<dev_id>.run.` prefix, so old and new names would coexist (`keep=N` expires them together, “latest” ordering can be affected). Decide before the first backup; use `-s dev_id` or `-S` to find devices whose existing backups already mix suffixes. |
| `to` | Optional | Overrides, for this device only, who receives the backup summary e-mail. See [E-mail notifications](#email-notifications)
 [Change reports](#change-reports). Available for all modules. |
| `comment` | Optional | Free-text note about the device, for whoever reads the device table — not used anywhere else. Available for all modules. Example: `comment=lab switch`. |
| `site` | Optional | Free-text site/location tag, like `comment` — fetchconfig does not use it. Used by fetchconfig-web for per-site access control (users see only devices whose site matches their user record; a device with no `site` is visible only to “all sites” / site 0 users). Single-byte characters. Example: `site="Plant 3, Hall A"`. |

> [!note] Quoting option values
> Any option value may be wrapped in double quotes, e.g. `comment="Building 3, Floor 2"`. This is only needed if the value contains a literal comma, since a comma otherwise separates one option from the next — quoting is never required just because a value contains spaces. Inside a quoted value, `\"` and `\\` represent a literal quote and backslash. Quoting is optional, not enforced: an unquoted value with a comma is still just split at that comma, exactly as before.

### Per-model option matrix

Beyond the options above, each model recognizes its own subset of `user` / `pass` / `enable` / `timeout` / `repository` / `keep` / `fetch_timeout` / `changes_only`. `on_fetch_run`, `on_fetch_cat`, `timezone`, `filename_append_suffix`, `to`, `comment`, `site` and `debug` are available for every model and are omitted here for space.

| Model | user | pass | enable | timeout | repository | keep | fetch_timeout | changes_only |
|---|---|---|---|---|---|---|---|---|
| `generic`[^0] | opt. | &#10003; | opt. | opt. | &#10003; | opt. | opt. | opt. |
| `cisco-ios` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-cat` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-asa` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-pix` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-ios-ssh` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-asa-ssh` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-sg300` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `comware-ssh` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `dell` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve-ssh` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-ios / -cat / -asa / -pix` | opt. | &#10003; | &#10003; | &#10003; | &#10003; | &#10003; | opt. | opt. |
| `fortigate` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `parks`[^1] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `riverstone` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `terayon-os` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `dmswitch` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `3com-msr` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `mikrotik` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `tellabs-msr` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `junos` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `acme` | opt. | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `mediant` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `nec-univerge-ix` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-iosxr` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `coriant-8600` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `hirschmann`[^2] | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `zyxel`[^3] | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `planet-ssh`[^4] | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `aruba-cx-ssh`[^5] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `nexus-ssh`[^9] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `mediant-sbc`[^10] | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve-snmp`[^6] | — | — | — | opt. | &#10003; | &#10003; | — | opt. |
| `tplink-web-sg105e`[^7] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve-web-1700`[^8] | — | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |

`timeout` is shown as optional for every model because it has a built-in default: if it is set neither on the device line nor on the model’s `default:` line, fetchconfig uses **30 seconds** and logs `Using 30s fetch timeout because the timeout was not set for this model` at debug level. Before v9.55 an unset timeout fell through to the underlying library’s own default (10 s for telnet/SSH, 180 s for the web-UI models), so set it explicitly for anything but a lab test.

[^0]: `generic` is the template-driven model: `model=` names the template and is mandatory (it may be set on a `default: generic` line so devices sharing one template need not repeat it, and a device line can still override it), `transport` is `ssh`/`telnet`, and it also recognizes `banner_timeout`, `fetch_delay`, `max_visits`, `strip_ansi`, `prompt_head`, `prompt_tail`, `ssh_extra_opts` and `template_dir` (most also settable in the template; the `prompt_settle` directive was removed in v9.72 — it was parsed but never used by the generic engine, and the SSH-model option `prompt_settle_ms` is a different option that is unaffected). `user`/`pass` are mandatory for SSH. See [Template-driven model](#template-model) and the README DEVICE OPTIONS section. **`debug` (optional, boolean) is available for every model** (since v9.71); the per-model notes below only describe what its `<dev_id>.debug` file contains for that transport (raw telnet/SSH session, HTTP request/response, or SNMP+TFTP), not which models support it.
[^1]: `parks` also recognizes `banner_timeout` (optional) — overrides the timeout used to wait for the initial `login:` prompt, since the Parks 209R can take many seconds to issue it.
[^2]: `hirschmann`'s `enable` is optional because that firmware's `enable` command doesn't ask for a password; it's read defensively in case another firmware version does. `hirschmann` also recognizes `show_cmd` (optional), same as `cisco-ios` below.
[^3]: `zyxel`'s `enable` is optional: one real login sample went straight to the privileged prompt with no separate "enable" step (account already had full privilege), while another needed "enable" plus its own password — both are handled, so this is read defensively rather than assumed either way. `zyxel` also recognizes `show_cmd` (optional, same as `cisco-ios`) and `debug` (optional, boolean — records the raw telnet session to `<repository>/<dev_id>.debug` when set to `on`, same convention as `procurve`/`procurve-ssh`).
[^4]: `planet-ssh`: `user`/`pass` serve the SSH authentication and, on firmware that shows one, the switch’s own `Username:`/`Password:` dialog that follows it. `enable` is optional and only used if the account lands on the `>` prompt; it defaults to the login password. The `! System Up Time:` header line of the running-config is kept in the backup but ignored by `changes_only`. Also recognizes `banner_timeout`, `show_cmd`, `debug` (to `<repository>/<dev_id>.debug`: first the ssh client’s verbose account of the SSH authentication, then the raw switch session — the SSH login itself is not switch output, so it can only appear as those ssh log lines) and `type_delay` (milliseconds between typed characters, default 100 — the switch does not reliably accept a burst of input right after a prompt, so every line is typed character by character; 0 disables the pauses).
[^5]: `aruba-cx-ssh`: `user` must be an administrator (AOS-CX has no `enable`; an operator’s `>` prompt is an error). Also works for HPE Aruba Networking AOS-8 wireless access points (confirmed on an AP model 515, AOS-8 8.13.2.2). Pager disabled with `no page`; the `Current configuration:` header is dropped. Also recognizes `banner_timeout`, `show_cmd`, `prompt_settle_ms` (idle-wait before matching the prompt, default 150 ms — the prompt token allows spaces and non-ASCII, and the wait keeps a banner line ending in “#” from being taken for the prompt) and `debug` (same debug file layout as `planet-ssh`).
[^6]: `procurve-snmp` has no `user`/`pass`: the credential is the SNMP read-write `community`. `timeout` defaults to 30s and covers both SNMP and TFTP; also recognizes `oid`, `remote_file`, `snmp_version` and `debug`.
[^7]: `tplink-web-sg105e` talks HTTP, not telnet: `user`/`pass` are the web UI login, `timeout` applies to each HTTP request, and `fetch_timeout` to the config download request only. Also recognizes `debug` (optional, boolean — records every HTTP request and response of the run, password masked and binary bodies summarized by size, to `<repository>/<dev_id>.debug`).
[^8]: `procurve-web-1700` likewise talks HTTP; it has only a manager password, so `user` is ignored. Same `timeout`/`fetch_timeout`/`debug` handling as `tplink-web-sg105e`.
[^9]: `nexus-ssh`: `user` must land on the `#` prompt (NX-OS has no `enable`; a `>` prompt is an error). Pager disabled with `terminal length 0`. The `!Time:` header line of the running-config changes on every run and is ignored by `changes_only`; `!Running configuration last done at:` counts. Also recognizes `banner_timeout`, `show_cmd`, `prompt_settle_ms` (idle-wait before matching the prompt, default 150 ms) and `debug` (`on`/`off`, default off; records to `<repository>/<dev_id>.debug`, mode 0600, the ssh authentication record followed by the raw switch session).
[^10]: `mediant-sbc` also recognizes `transport` (optional; `ssh` default, `telnet`, or `auto` = SSH with telnet fallback only when no SSH service answers), `prompt_settle_ms` (optional, SSH; idle-wait before matching the prompt, default 150 ms), `banner_timeout`, `show_cmd` (optional; default `show running-config full`), `pager_cmd` (optional; a command sent before the show command to disable paging, for firmware that offers one — its rejection, e.g. “Invalid command” or “%”, aborts the fetch; not needed on the observed Mediant 500Li) and `debug` (optional).
### show_cmd (most CLI models)

If specified, replaces the model's usual show-config command — useful for older devices. On `cisco-ios`, `show_cmd=wrterm` is kept as a backward-compatible alias for `write term` in place of `show run`.

### debug

Boolean, available for **all** models (since v9.71). If `debug=on` (default off), records the raw telnet/SSH session (or, for the web UI models, every HTTP request and response) to `<repository>/<dev_id>.debug` (mode 0600, login/enable passwords kept out) for troubleshooting.

## Troubleshooting {#troubleshooting}

> [!warn] Legacy SSH key exchange
> Some older SSH implementations (e.g. older HP/Aruba ProCurve firmware) only offer legacy key exchange algorithms that modern OpenSSH clients disable by default. fetchconfig.pl itself already re-enables what it needs for its own SSH connections (see the `KexAlgorithms`/`HostKeyAlgorithms`/`Ciphers` `master_opts` in `ProCurveSSH.pm` and `ComwareSSH.pm`), so this only matters if you want to connect to the same device manually with the system's own `ssh` command — the same kind of algorithm may need to be re-enabled in the SSH client's own configuration:
>
> ```/etc/ssh_config
> Host *
>     KexAlgorithms +diffie-hellman-group1-sha1
> ```

## Security notes {#security}

See also the [Directory allowlist](#directory-allowlist), which restricts the directories a device table may reference - important when the table is edited through a less-trusted front end.

> [!warn] Debug files contain credentials
> With `debug=on`, `<repository>/<dev_id>.debug` records the session verbatim — for the telnet/SSH models that includes the login and enable passwords exactly as typed, and for `procurve-snmp` the SNMP read-write community. Since v9.54 these files are created with mode `0600` regardless of the process umask. Still, enable `debug=on` only while troubleshooting and delete the file afterwards. Backup files, their directories and the `.status` file are created with the process umask — an unprivileged reader such as fetchconfig-web (running as `nobody` for `-l`/`-g`) must be able to read them, so they are deliberately **not** forced owner-only (parallel-fetch worker scratch files, in a private temp dir, are owner-only). Backups contain configuration secrets — and not always hashed: SNMP communities and some routing/VPN keys (BGP, OSPF, RADIUS/TACACS, IPsec pre-shared keys) are cleartext, and Cisco “type 7” passwords are reversible. Restrict the repository directory on a shared host and treat every backup as sensitive.

**SSH host keys are not verified.** The SSH models use `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null`: any host key is accepted and none remembered. This is deliberate — fetchconfig runs unattended, and a switch’s host key changes on every hardware swap, which would otherwise halt backups until someone edited `known_hosts`. The trade-off is that an on-path attacker could impersonate a device and capture the login password. Run fetchconfig on a trusted management network.

**Device IDs are validated.** A `dev_id` may contain letters, digits, underscore, dot and dash (hostnames like `sw01.example.com` are fine) but may not consist only of dots, since `.` or `..` would resolve to the repository itself or its parent.

**SMTP.** `AUTH LOGIN` sends the password base64-encoded, not encrypted — see the `tls` option under [E-mail notifications](#email-notifications)
 [Change reports](#change-reports). Header fields (From, To, Subject) have line breaks stripped before sending, so a device-table value cannot inject extra mail headers.

**Backup file naming.** Backups are named `<dev_id>.run.YYYYMMDD.HHMMSS[tz]`, i.e. one-second resolution. Two backups of one device completed within the same second would share a name; rather than let the second silently overwrite the first, the backup is written with `O_EXCL`, so the second run fails to create the file and is reported, leaving the first intact. This essentially never happens for a real fetch (it never completes in under a second and scheduled runs are minutes apart), and device locking (`lock=on`) prevents concurrent same-device runs outright. Since v9.55 every operation that orders backups (“latest” for `changes_only`, `keep=N` expiry, `-g`/`-n`/`-m`, `-l`, `-z`/`-Z`, `-s`/`-S`) sorts by the parsed timestamp `YYYYMMDD.HHMMSS`, not by a plain string sort of the whole name, so neither the timezone token (which changes with DST and by platform) nor a suffix can disturb the order.

**Non-ASCII hostnames.** `aruba-cx-ssh` and `planet-ssh` handle a prompt containing spaces or non-ASCII characters. `procurve`, `procurve-ssh`, `hirschmann`, `comware-ssh` and `nec-univerge-ix` still build their prompt regexp with `quotemeta()` and would not match such a prompt; this is left unchanged pending tests against real devices — keep hostnames on those devices to ASCII.

## Status file {#status-file}

After every backup attempt fetchconfig writes a small status file next to the backups, at `<repository>/<dev_id>.status`. It is written for every device and every model, and does *not* depend on the `email:` line — it is a plain repository artifact, meant for external tools (for example a web front-end that reads `backup_duration_sec` to size a progress spinner). It is overwritten on every run and written atomically, so a reader never sees a half-written file.

```<dev_id>.status
[swi-lab-01]
backup_start_date=2026-09-11
backup_start_time=22:14:03
backup_end_date=2026-09-11
backup_end_time=22:14:09
backup_duration_sec=6
backup_state=success
backup_changed=changed
```

| Key | Value |
|---|---|
| `backup_start_date` / `backup_start_time` | When the fetch started (local time). Derived as end minus `backup_duration_sec`. |
| `backup_end_date` / `backup_end_time` | When the fetch finished (local time). |
| `backup_duration_sec` | Whole seconds the fetch took — the same value logged for the run and shown in the summary e-mail. |
| `backup_state` | `success`, `failed`, or `skipped`. |
| `backup_changed` | `unchanged` or `changed` for a `changes_only=1` device; `forced` for a `changes_only=0` device (saved regardless of any comparison); `unknown` when the state is failed or skipped. |

## ProCurve SNMP backups (ProVision, 4000M/8000M) {#procurve-snmp} {nav: ProCurve SNMP backups}

The older HP ProCurve ProVision chassis (4000M, 8000M) can only be managed remotely through a VT100 menu, which is not usable for scripted backup. They will, however, export a text copy of their configuration over TFTP when told to over SNMP, and that is what `procurve-snmp` does. It is a transport unlike the other models — no shell and no web UI, but SNMP plus TFTP — and so has no `user`/`pass`: the credential is the SNMP read-write `community`.

An SNMP set arms the switch’s TFTP export, the config is fetched from the switch by TFTP, and a second SNMP set disables the export again. That disable always runs, even when the transfer failed, so the switch is never left with its TFTP server open.

> [!note] browse vs. running-config
> The default `remote_file=browse` produces a human-readable report — fine for backup and change tracking, but a display export, not a file that can be TFTP’d back to restore the switch. Later ProVision models also accept `remote_file=running-config`, a replayable config.

> [!warn] TFTP is inbound
> The switch pushes the file to the backup host over TFTP (UDP/69 inbound, then a data port). A host firewall on the backup machine can block this; it then shows up as a TFTP get failure or timeout, not a hang.

## Web UI backups (TP-Link Easy Smart, ProCurve 1700) {#tplink} {nav: Web UI backups}

Some switches have no CLI at all — TP-Link Easy Smart switches (TL‑SG105E, TL‑SG105PE and siblings) and the HP ProCurve 1700 series. The `tplink-web-sg105e` and `procurve-web-1700` models retrieve the config the same way a browser does on the switch’s config backup page: they log in over plain HTTP (the switches offer no HTTPS), download the config file, and log out again. The two models share their HTTP plumbing (`AbstractHTTP.pm`); the login, download and logout requests are per device, taken from packet captures of real browser sessions.

**TP-Link:** both session mechanisms seen on real devices are handled — the TL‑SG105E binds the login session to the client’s IP address, the TL‑SG105PE v2 uses a session cookie. Either way the switch only allows a limited number of concurrent logins; if it reports the login table as full, the backup of that device is reported as failed rather than forcing another user out.

**ProCurve 1700:** the switch has only a manager password (`user` is ignored) and binds the session to the client’s IP address.

> [!warn] Secrets in clear
> The 1700’s `switch.cfg` contains the SNMP communities and, apparently, the manager password in clear — protect the repository accordingly.

The downloaded config is an opaque binary file, not text. It is stored uuencoded (`begin 644 <name>.cfg` … `end`) so that it fits the text-based repository, the `changes_only` comparison and the `-g` retrieval like any other backup. To turn a backup back into the file the switch’s restore page expects:

```shell
uudecode -o config.cfg <backup-file>
# or straight from the repository:
fetchconfig.pl -devices=... -g <dev_id> | uudecode -o config.cfg
```

> [!note] Diffs are not meaningful here
> A line-by-line comparison between two backups (`-m`) works, but on uuencoded binary it only shows *that* something changed, not *what*. Byte-exact change detection (`changes_only=1`) is unaffected: identical binaries encode to identical text.
