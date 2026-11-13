# fetchconfig -- README / Documentation

<!--stats-->
34 | device platforms
{version} | version
Telnet / SSH / HTTP / SNMP | transports
Linux / AIX / Windows | tested platforms (Windows: no SSH/diff)
<!--/stats-->

A Perl script for retrieving and backing up the configuration of network devices at scale — over telnet, SSH or a device’s web UI, across dozens of vendors, with change tracking, e-mail summaries, and a repository you can script against.

<!--nav-group: Overview-->

## Introduction {#introduction}

fetchconfig is a Perl script for retrieving the configuration of multiple devices. It has been tested under Linux, AIX and Windows (on native Windows: telnet, web-UI and SNMP devices only, no SSH — see [Platform support](#platform-support)), and currently supports a variety of devices, including Cisco IOS, Cisco Catalyst, Cisco ASA, Cisco PIX, FortiGate Firewalls, ProCurve, Alcatel Ethernet Routers (aka Riverstone), Dell PowerConnect Switches, Terayon 3200/3500 CMTS, Datacom DmSwitch Switches, HP MSR Routers, Mikrotik Routers, Tellabs MSR Routers, Juniper EX Switch JunOS, Oracle Acme Packet, Audiocodes Mediant, Cisco IOS XR, NEC Univerge IX, Hirschmann Railswitch, Zyxel switches, PLANET managed switches, Aruba CX switches, Cisco Nexus switches, AudioCodes Mediant SBCs, TP-Link Easy Smart switches, HP ProCurve 1700 series switches, and HP ProCurve ProVision (incl. 4000M/8000M) over SNMP+TFTP.

**Key concepts.** A *device table* lists the devices to back up, one per line, each naming a *model* (how to talk to that kind of device) and options. fetchconfig connects to each device, retrieves its configuration, and stores it in a *repository* (a dated directory tree), keeping a configurable history. Reading on: [Device table](#device-table) defines the input, [Template model](#template-model) covers the flexible generic model, and [Options reference](#options) lists every command-line option.

> [!note] Companion web UI
> Need a browser-based UI? A companion project, **fetchconfig-web**, provides a web front-end on top of fetchconfig for browsing backups, viewing and comparing configurations, checking run status, and editing the device table: <https://github.com/rainer-tammer/fetchconfig-web>

> [!note] For developers
> `DEVELOPER-GUIDE.md` / `.html` is the architecture and engineering guide (internals, data structures, device-table format, security model, and how to extend); `How-To-add-a-model.md` / `.html` is the programming manual for writing a new device model. `perl Makefile.PL && make test` (or `prove -I. t/`) runs the test suite under `t/`, and `make doc` regenerates the `.md`-derived docs via `tools/render-doc.py` and `tools/md2html.py` (launched through `tools/pyrun`, which selects python3 on Linux and python on AIX). Perl module requirements (core vs CPAN for Perl 5.26/5.28/5.40, by feature) are in the file `DEPENDENCIES`.

## License {#license}

> [!note]
> fetchconfig — Retrieving configuration for multiple devices Copyright (C) 2006 - 2026 Everton da Silva Marques, Rainer Tammer and others - see CREDITS for more information.
>
> fetchconfig is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2, or (at your option) any later version.
>
> fetchconfig is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
>
> You should have received a copy of the GNU General Public License along with fetchconfig; see the file `COPYING`. If not, write to the Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.

## Upgrading & compatibility {#upgrading} {nav: Upgrading}

This release is the 9.x line of fetchconfig, a continuation of upstream fetchconfig 0.25.

**Config- and command-line-compatible with 0.25.** A device table and the command lines you used with upstream 0.25 keep working unchanged — the 9.x line is a drop-in replacement, and no existing configuration has to be rewritten to upgrade. New behaviour is added through new options and new models, never by changing the meaning of what 0.25 already understood. `CHANGES.md` (entry 9.56) summarises how the 9.x fork differs from 0.25 — new models and transports, backup-file and comparison improvements, and the command-line additions below.

A few changes alter *behaviour* on first upgrade, even though the configuration itself still parses. Read these before the first run of a new version on an existing repository:

> [!warn] v9.53 — trailing newline (affects every device)
> Saved configuration files now end with a trailing newline on the last line, matching the device’s own output (and a config downloaded from a device web UI). This touches **every** model. Because the file content changes by that one final byte, the **first** backup run after upgrading reports every device as “changed” and, with `changes_only`, saves a fresh copy — a one-time effect of the fix, not real drift. The second run onward compares clean.

> [!warn] v9.55 — the backup filename suffix must start with “.”
> Starting with v9.55, `filename_append_suffix` must start with a “.” (e.g. `.txt`). A device whose suffix lacks the leading dot, or contains `/` or whitespace, now **fails its backup** with an error and writes nothing. Fix any dotless suffix in your device table before the first v9.55 run. Also: do not add, remove or change a suffix on a device that already has backups; use `fetchconfig.pl -S` to find devices whose existing backups already mix suffixes.

> [!note] v9.65 — generic-model template grammar (generic model only)
> This affects only the [template-driven generic model](#template-model), which postdates 0.25 — a 0.25 device table has no templates to migrate. Since v9.65 every template state is declared with the `state` keyword, including the per-transport entry states, so a template written for v9.64 or earlier no longer parses. To migrate a template, add `state` before each bare entry-state header (e.g. `state_login_ssh` → `state state_login_ssh`). The shipped templates and `tools/generate_template.pl` were updated accordingly; see `README.generic-model`.

## Installation {#installation}

In a hurry? [QUICK-INSTALL.md](QUICK-INSTALL.md) has the essential steps with no fuss; the sections below are the full reference.

<!--tabs-->

<!--tab: UNIX / Linux-->

1. fetchconfig.pl expects a Perl interpreter at `/usr/bin/perl`.
2. Install the Perl modules you need — see [Perl module requirements](#modules). Most are in the Perl core (5.26+); the non-core ones are `Net::Telnet` and `Net::SMTP` (every run), `Net::OpenSSH` (SSH devices), `LWP::UserAgent`/`HTTP::Request::Common` (web-UI models), and `Net::SNMP` (`procurve-snmp` and SNMP device inventory on any model) and `Net::TFTP` (`procurve-snmp`).
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
2. Install the Perl modules you need — see [Perl module requirements](#modules). Most are in the Perl core (5.26+); the non-core ones are `Net::Telnet` and `Net::SMTP` (every run), `Net::OpenSSH` (SSH devices), `LWP::UserAgent`/`HTTP::Request::Common` (web-UI models), and `Net::SNMP` (`procurve-snmp` and SNMP device inventory on any model) and `Net::TFTP` (`procurve-snmp`). **On native Windows the SSH models do not run** (`Net::OpenSSH`/`IO::Pty` are unavailable there), so only telnet, web-UI and `procurve-snmp` devices work; backup comparison (`-g … -m`) and change-report diffs are disabled, `-P` always runs sequentially, and `chmod`/`umask` hardening is a no-op (rely on folder ACLs). Under Cygwin/WSL it behaves as on Linux. See [Platform support](#platform-support).
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

> [!note] Tarball name is a placeholder
> `fetchconfig-0.0.tar.gz` (and the unpacked `fetchconfig-0.0` directory) above are placeholders — replace them with the actual name of the release you downloaded. The name varies by how you obtained it: a GitHub release or tag download, for example, is named for the tag or commit rather than `0.0`.

## Platform support {#platform-support} {nav: Platform support}

fetchconfig runs on Linux, AIX and Windows. On Linux and AIX all features are available. On **native Windows** (Strawberry/ActivePerl) the features below rely on POSIX facilities and are unavailable; everything else works normally.

- **SSH models are not supported.** `Net::OpenSSH` and `IO::Pty` do not run on native Windows, so the `*-ssh` models and the generic model's `transport=ssh` cannot connect. Telnet, web-UI and `procurve-snmp` devices work normally.
- **Config diffs are not produced** (they need an external `diff`). The `-g … -m` backup comparison exits with an error. The change report and summary e-mail are still generated, but a changed device is shown as **`diff-unavailable`** instead of a diff; `email_max_diff` does not switch this off (it only caps how many diffs are embedded when diffs are available).
- **`-P` always runs sequentially.** There is no `fork`, so `-P N>1` is accepted but reduced to `-P 1`.
- **File-permission hardening is a no-op.** `chmod 0600` on `.debug` files and the `umask` on lock/backup files have no effect on Windows; confidentiality relies on the containing folder's NTFS ACLs.

> [!note] Cygwin / WSL
> Under Cygwin or WSL, fetchconfig behaves as on Linux — SSH, diffs and parallel fetch all work.

## Perl module requirements {#modules}

fetchconfig runs on Perl 5.26 or later (tested on 5.26, 5.28 and 5.40; see the DEPENDENCIES file for the full module list and core-vs-CPAN status). Most of the modules it uses are in the Perl core on those versions and need no separate installation (`Text::ParseWords`, `POSIX`, `IO::Handle`, `Time::HiRes`, `MIME::Base64`, `FindBin`, `File::Temp`, `File::Path`, `File::Basename`, `File::Compare`, `Getopt::Long`, `Digest::SHA`). The modules below are **not** in the core and must be installed separately — but only if you use the devices that need them.

| Module(s) | Needed for |
|---|---|
| `Net::Telnet` | Every run. Telnet devices, and also driving the pseudo-terminal for all SSH devices — in practice fetchconfig cannot back up any device without it. |
| `Net::SMTP` | Every run. Part of the core *libnet* distribution (core since Perl 5.7.3), so no separate installation is needed. fetchconfig loads its reporting code on every run — it writes the per-device [status file](#status-file) even when no e-mail is configured — so this must be present regardless. No SMTP connection is made unless an `email:` line is configured. |
| `Net::OpenSSH` | All SSH-based models: `cisco-ios-ssh`, `cisco-asa-ssh`, `comware-ssh`, `procurve-ssh`, `planet-ssh`, `aruba-cx-ssh` and any other `*-ssh` model. |
| `LWP::UserAgent`, `HTTP::Request::Common` | The web-UI models `tplink-web-sg105e` and `procurve-web-1700` (no CLI). Both come with the *libwww-perl* distribution. |
| `Net::SNMP` | The `procurve-snmp` model (HP ProCurve ProVision, including the 4000M/8000M chassis), and the [SNMP device inventory](#snmp-inventory) (9.80), which any model can use. `Net::TFTP` additionally for `procurve-snmp`'s file transfer. SNMPv3 (either use) also needs `Digest::HMAC` and `Crypt::DES`/`Crypt::Rijndael`. |
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

2. Run fetchconfig.pl:

```
cd /usr/local/fetchconfig
./fetchconfig.pl -devices=device_table
```

fetchconfig.pl scans the `device_table` file, tries to retrieve the configuration for every device, and stores the configuration files under the `repository`.

A relative `-devices=` name is looked for in the current directory first, then beside `fetchconfig.pl` (its own directory), so a device table kept with the script is found from any working directory — a cron job, say — without a `cd` first. An absolute path is used exactly as given.

By default the devices are fetched one after another, in device-table order. With many devices the run time is dominated by the network sessions; `-P N` fetches `N` devices concurrently — see [Parallel fetching](#parallel). On native Windows `-P N` always runs sequentially (no fork; see [Platform support](#platform-support)).

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

Beside the two line types above, the device table also accepts the control directives `email:` (see [E-mail notifications](#email-notifications)), `db:` (see [Backup-history database](#backup-history)), `directory:` (see [Directory allowlist](#directory-allowlist)) and `pw:` (see [Credential aliases](#credential-aliases)).

### Line syntax {#devtable-syntax}

The device-table line forms as syntax (railroad) diagrams — follow each path left→right; a branch is an alternative, and an item the line skips past is optional:

```railroad
devtable-line
A line is a `default:` options line, a device line (**model first**, then the unique id and host, then optional options), or one of the control directives below.
```

```railroad
devtable-options
`options` on a `default:` or device line are comma-separated `key=value` pairs (e.g. `user=backup,pass=secret,keep=10`).
```

```railroad
devtable-directives
The control directives: `email:`, `db:`, `directory:` (`<type> $TAG path` — `$TAG` and `path` are required; only `fetch_run`/`report` may instead be `none`) and `pw:`.
```

## Device table on the command line {#embedding} {nav: Device table on the CLI}

Valid lines for the device table file can also be passed directly through the `-line=`*string* switch.

```
/path/to/fetchconfig.pl -line="default: tellabs-msr user=backup,pass=s&cr&t,timeout=10,keep=5,changes_only=0,fetch_timeout=1200,filename_append_suffix=.txt,repository=/path/to/repo" -line="tellabs-msr lab-router 10.0.0.1"
```

## Directory allowlist {#directory-allowlist}

Restrict which directories a repository=, template_dir=, on_fetch_run=, report or lock directory may name.

Optionally, the device table may restrict which directories a `repository=` or `template_dir=` option is allowed to name. This is useful when the device table is edited through a less-trusted front end (e.g. a web UI): the allowlist lives only in the real config file and cannot be widened from the UI, so an edit can never point a device at an arbitrary path.

With all four directory types allowed:

```
directory: repository $REPO1     /usr/local/fetchconfig/config
directory: template   $TEMPLATE1 /usr/local/fetchconfig/templates
directory: fetch_run  $CMD1      /var/fetchconfig/fetch_run
directory: report    $REP1       /var/www/fetchconfig/reports
```

With `on_fetch_run` disabled (`fetch_run none`); a section must still cover all
four types, so `report` is present:

```
directory: repository $REPO1     /usr/local/fetchconfig/config
directory: template   $TEMPLATE1 /usr/local/fetchconfig/templates
directory: fetch_run  none
directory: report     $REP1      /var/www/fetchconfig/reports
```

Each line is `directory: <type> <$TAG> <path>`, where `type` is `repository`, `template`, `fetch_run`, `report` or `lock`, `$TAG` is a unique `$NAME` symbol, and `path` is the allowed directory. A section must cover **all four** types; `fetch_run` constrains `on_fetch_run=` (the directory of the command's program must be an allowed `fetch_run` directory), and `directory: fetch_run none` forbids `on_fetch_run` entirely. Likewise `directory: report none` satisfies the `report` type and disables change-report writing entirely.

Enforcement is **opt-in**: with no `directory:` line, nothing is restricted beyond the system-directory rule below (existing device tables are unaffected). The system-directory rule below always applies: a system directory is rejected whether or not an allowlist is present. Since v9.68 each distinct **non-system** `repository=`, `template_dir=` and `on_fetch_run` directory in use is then reported once per run as `warning: ... has no directory: allowlist entry (unrestricted ...)`, so you can see which paths are unrestricted and decide whether to add a `directory:` section (a system directory never reaches this warning — it is rejected first). With at least one present, every `repository=` and `template_dir=` used by a device (or inherited from a `default:` line) must be allowed:

- `repository=` must name a `repository` entry; `template_dir=` a `template` entry; `on_fetch_run=` must run a program in a `fetch_run` entry (types are not interchangeable).
- The value may be the `$TAG` or the literal path; a `$TAG` is expanded internally.
- Matching is exact, ignoring a single trailing slash. Paths are **not** canonicalized, so a symlinked, version-free path (e.g. `/usr/local/fetchconfig` &rarr; `/usr/local/fetchconfig-9.64`) is compared as written and the version stays hidden.
- Every path is checked for illegal content: no `/../` or `/./`, must be absolute, and only characters valid for the host OS.
- **System directories are never accepted, allowlist or not** (since v9.68): `/bin`, `/sbin`, `/lib`, `/lib64`, `/usr/bin`, `/usr/sbin`, `/usr/lib`, `/usr/lib64`, `/usr/share`, `/usr/include`, `/etc`, `/boot`, `/dev`, `/proc`, `/sys`, `/run`, `/var/run`, `/var/lock`, the root `/`, and anything under them. A `repository=`, `template_dir=` or `on_fetch_run` program there is rejected and the device skipped.

A value off the list, of the wrong type, an undefined tag, or with illegal content is rejected at fetch time with a clear error and that device is skipped; a bad value inherited from a `default:` line rejects every device that inherits it. `--list-allowed-dirs` prints the parsed allowlist.

## E-mail notifications {#email-notifications}

fetchconfig.pl can e-mail a summary of a run's backup results as an HTML table (Device‑ID, Date, Time, State, Size, Changes, Inventory). This is entirely optional: unless an `email:` line is present, no SMTP connection is ever attempted.

The summary carries two small count tables — a backup **Statistics** table (success/failed, changed/unchanged/…) and, directly below it, an **Inventory** table counting the per-device [SNMP inventory](#snmp-inventory) outcome (`success` / `failed` / `N/A` / `not due`, summing to the device total) — followed by the per-device table whose last column, **Inventory**, shows each device's state: `success` (green), `failed` (red), `N/A` (no SNMP configured, grey), or `not due` (an `snmp_inventory_interval` skip — the read was not due this run, amber). Devices with no SNMP inventory simply show `N/A`.

The message is laid out as a white rounded card on a grey canvas, with a dark-blue (`#1f4e79`) header bar carrying a small logo and “fetchconfig vX.Y”, and the copyright footer below the card — matching the fetchconfig-web mails. The header logo is embedded in the message as a `multipart/related` inline image (`Content-ID <fcwlogo>`); it is independent of the `report_logo=` used inside the on-disk HTML report, which is unchanged. The message is multipart: the HTML part above, and a plain-text part carrying the same statistics, inventory, and per-device tables rendered as plain text (auto-sized columns, no diffs), so a text-only mail client or a notification preview still shows the result summary.

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
| `footer` | Optional | Copyright/attribution text shown in the summary e-mail's footer. The ` - Version <n>` that follows it is fixed and always appended. If the value contains a comma, wrap it in double quotes (the quotes are stripped). Default: `(c) 2006-2026 Everton da Silva Marques, Rainer Tammer and others`. |
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

On **native Windows** the per-device diffs are disabled (they need an external `diff`); changed devices still appear in the report, marked "diff unavailable". See [Platform support](#platform-support).

After a run fetchconfig can write a self-contained HTML change report (summary table plus a coloured diff per changed device) to an allowlisted `report` directory, and embed up to `email_max_diff` device diffs in the summary e-mail with a link to the full report. The report directory is presented by fetchconfig-web (view/download/delete) and is not meant to be served to users directly. Options on `email:` lines:

- `report_dir=$REP1` — the report directory (a `report` allowlist entry).
- `write_report=on|off` — write the report. With `on` and no `from=/to=/smtp=`, only the report is written (no e-mail).
- `email_max_diff=N` — embed up to N changed devices' diffs in the e-mail (device-table order). Default `0` (no diffs); `0` or unset = none.
- `web_report_url=URL` — base URL of fetchconfig-web (the CGI itself, no query string, e.g. `https://host/cgi-bin/fetchconfig-web.cgi`); fetchconfig appends `?action=view_report&file=<report>` automatically for the e-mail's full-report link (emitted only when a report was written; any query string already on the value is ignored).
- `report_logo=FILE|none` — a logo in `report_dir`, embedded (self-contained), recommended 250×50 px.
- `report_days=N` — prune reports older than N days (only if N>1), by exact filename.
- `mask_secrets=on|off` — mask common secret forms in diffs (default on); master switch for all hiding.
- `report_hide=<regex>` — additional custom regex (one per line, accumulates); the matched substring becomes `****`. Governed by `mask_secrets`.

Device states in the report: `initial` (first backup, no diff), `Changed` (diff shown), `Unchanged`, `Failed`, and `diff-unavailable` (a changed device whose previous backup could not be read).

**Secret masking is best effort** — it masks common Cisco/ProCurve forms after diffing, on both old and new lines (a rotated secret shows as `****` &rarr; `****`), but is vendor-incomplete. The built-in forms include SNMP community, type-5/7 secrets, enable secret hashes, key-string, pre-shared-key, wpa-psk, wpa-passphrase, a bare `key <hex>` and the Hirschmann `passwd <user> :vN:<hash>:` form (username kept, hash masked). Reports and report e-mails must be treated as sensitive; the stored configs in the repository still contain cleartext credentials regardless of report masking — the report only masks what it displays, not what is stored.

**Custom patterns.** For secrets the built-ins miss, add regexes with `report_hide`, one per line — only the substring each regex matches becomes `****`, so match just the value (a fixed-width lookbehind keeps the keyword):

```
email: report_hide=(?<=wpa-passphrase )\S+
email: report_hide=(?<=^key )[0-9a-f]{16,}
```

turning `wpa-passphrase c1ca253b...` into `wpa-passphrase ****`. Take care not to over-match (e.g. `(?<=secret )\S+` also fires inside `my-secret`). Patterns accumulate; comment a line out to disable it. They are governed by `mask_secrets` (with `mask_secrets=off` nothing is hidden), and an invalid regex is logged and skipped. For `report_hide` the whole rest of the line is taken verbatim as the regex — no comma splitting, no quote stripping, no space trimming — so a regex may contain commas (e.g. `{16,}`), `=` and spaces with no escaping. Do not wrap it in quotes (they would become part of the pattern). One regex per line.

Each device's diff is wrapped in an **armored** `<div class="device-diff" data-device="<id>" id="dev-<id>">` with a stable structure, so fetchconfig-web can parse it into an expandable per-device view. Treat this markup as a parse contract.

**Report directory setup.** So that fetchconfig-web (running as the web server's user/group) can read and manage the reports, set the report directory's group to the web server's group and set the setgid bit, e.g. `chgrp <webgroup> /var/www/fetchconfig/reports` and `chmod g+s /var/www/fetchconfig/reports`. With `g+s`, each report file inherits the directory's group automatically — fetchconfig needs no special privileges and does not change ownership itself.

## Backup-history database (optional) {#backup-history} {nav: Backup-history DB}

Record each run's backup health and config-change history to a PostgreSQL database, for a fetchconfig-web dashboard that scales to thousands of devices without walking the repository on every page. OFF by default and entirely optional: with no `db:` line fetchconfig stays file-based and `DBI`/`DBD::Pg` are never loaded. The per-device [`.status`](#status-file) file is unchanged; the database is a separate, additional sink.

The schema and the writer login role are created and owned by fetchconfig-web (run `fetchconfig-web-dbsetup.pl --upgrade`, which creates the login role and grants it the required `SELECT`/`INSERT`/`UPDATE`). The engine only writes rows: it never issues DDL and never creates roles. PostgreSQL 8.2 or newer is supported (no `ON CONFLICT`/`MERGE`/`jsonb` is used).

### 1. Enable it

Add a single `db:` line to the default options section. It is fleet-wide, not a per-device option:

```
#db:	key=value,...
db:	db_inst=fetchconfig,db_user=fetchconfig_dashboard,db_pass=secret,db_host=db.acme.com
```

| Key | Requirement | Description |
|---|---|---|
| `db_inst` | Mandatory | Database (instance) name. |
| `db_user` | Mandatory | Writer login role. No default is applied; `fetchconfig_dashboard` is only the name `fetchconfig-web-dbsetup.pl` creates by convention. |
| `db_pass` | Optional | Its password. Normal device_table quoting, so a value containing a comma or equals sign must be double-quoted (`db_pass="a,b=c"`). Never written to the log. |
| `db_host` | Mandatory | `host` or `host:port`. IPv6 uses brackets to carry a port, `[2001:db8::1]:5432`; a bare `2001:db8::1` is the host at the default port (5432). |
| `db_connect_timeout` | Optional | Seconds to wait for the connection (default 5). Kept short so a dead database can never stall a run. |
| `db_sslmode` | Optional | libpq sslmode: `disable`, `require` or `verify-full`. Default `disable` (the DB is normally local on the same box). Use `require` or stronger when the database is across a WAN. |
| `db_max_outbox_days` | Optional | Spool (outbox) retention in days (default 90). See below. |

`db:` may be repeated; later values overwrite earlier ones for the same key (same rule as `default:` and `email:`). The device_table holds `db_pass`, so it must stay mode 0600 (see [Security notes](#security)).

### 2. How it writes (store-and-forward)

Nothing blocks the run, and an unreachable database never costs a backup:

- During the run nothing touches the database. Each run appends its records to a per-repository write-ahead spool file, `<repository>/.db-<pid>-<timestamp>`.
- At the end of the run, in the parent and whether or not `email:` is configured, the spool files are drained into the database one transaction per file, oldest first. A file is deleted only after its transaction commits.
- If the database is unreachable the run still completes normally; the spool files accumulate and are drained on a later run. Spool files older than `db_max_outbox_days` are dropped (after that long an outage, the on-disk backups and the `.status` files remain the source of truth).

All writes use DBI placeholders; the append-only tables use `INSERT ... WHERE NOT EXISTS` and the per-device current row is UPDATE-else-INSERT, so replaying a spool file is idempotent.

### 3. What it records

Three tables, all owned by fetchconfig-web: a dense `backup_runs` (one row per device per run), a sparse `backup_versions` (one row per retained backup, carrying its sha1), and `backup_current` (one row per device: its latest state and last-good backup). All timestamps are stored as the box's local wall-clock time, so every column is consistent on a single-host install; fetchconfig-web renders them as-is, with no timezone conversion.

Every run (with or without `email:`) logs a `-----[DB writer]-----` section with the DB-history result: `all N record(s) written; outbox empty`, or `INCOMPLETE - M run(s) still pending (oldest <ts>); will retry next run` when the database was unreachable and the records were spooled (connect/drain warnings appear in the same section). Nothing is logged when no `db:` is set. When `email:` is configured, the summary mail shows the result as a status box inside the card: green when everything was written, red when records are still buffered for a later run, and grey (`history export not configured`) when no `db:` is set.

**Backfilling existing backups.** When you first enable `db:`, only new runs populate the database — the backups already on disk are not in it. Run [`--db-backfill`](#options) once to reconstruct the history from those files: one `backup_versions` row (its sha1 recomputed from the file, identical to a live save) and one `backup_runs` row per stored backup, plus a `backup_current` row for each device not yet recorded. It is idempotent and repeatable, never overwrites a row a live run wrote, and `-T` previews the counts. Only saved backups can be rebuilt — the dense run history (unchanged or failed runs leave no file) accrues from live runs afterwards.

**Per-version line deltas.** Each `backup_versions` row can carry `lines_added` and `lines_removed` — the +added/-removed of the ignore-normalized diff against the device's previous version, so a same-length edit is not reported as a zero-byte change. The two columns belong to the fetchconfig-web 2.12 schema; the engine checks once per run whether they exist and writes them only then, so an older web side keeps working with the columns unpopulated. The live writer computes the delta over the same normalized view it uses for change detection. `--db-backfill` also records them for existing backups and UPDATEs rows written earlier whose deltas are still empty; a backfilled generic-template device counts raw lines (its template is not loaded during a backfill), whereas live runs count the normalized view.

<!--nav-group: Supported devices-->

## Device support {#device-support}

Known to be supported — not a comprehensive list. Other devices and versions are likely to work but haven't been verified.

> [!note] Windows
> The SSH models (`cisco-ios-ssh`, `cisco-asa-ssh`, `comware-ssh`, `procurve-ssh`, `planet-ssh`, `aruba-cx-ssh`, `nexus-ssh`) and the SSH transport of `mediant-sbc` are **not available on native Windows** (`Net::OpenSSH`/`IO::Pty` do not run there); their telnet counterparts, and `mediant-sbc` over telnet, work. See [Platform support](#platform-support).

| Model name | Devices / OS supported |
|---|---|
| `3com-msr` | 3Com MSR routers |
| `acme` | Oracle Acme Packet |
| `aruba-cx-ssh` | Aruba CX switches (AOS-CX, SSH; observed on PL.10.17). Administrator account required — AOS-CX has no `enable`, an operator’s `>` prompt is reported as an error. Also backs up HPE Aruba Networking wireless access points running AOS-8 (confirmed on an AP model 515, AOS-8 8.13.2.2). |
| `cisco-asa` | Cisco ASA firewalls |
| `cisco-asa-ssh` | Cisco ASA over SSH (the SSH counterpart of `cisco-asa`) |
| `cisco-cat` | CatOS switches |
| `cisco-ios` | IOS routers — 2500 series, 2600 series, 2800 series, CS‑516 (with `show_cmd=wrterm`) |
| `cisco-ios-ssh` | Cisco IOS over SSH (the SSH counterpart of `cisco-ios`) |
| `cisco-iosxr` | Cisco IOS XR |
| `cisco-pix` | Cisco PIX firewalls |
| `cisco-sg300` | Cisco SG300 small-business switches (Cisco-IOS-like CLI) |
| `comware-ssh` | HP/H3C Comware switches over SSH (bracketed `<host>`/`[host]` prompt, no `enable` step) |
| `coriant-8600` | Coriant 8600 Smart Router Series |
| `dell` | Dell PowerConnect switches |
| `dmswitch` | Datacom DmSwitch |
| `fortigate` | FortiOS 3.0 |
| `hirschmann` | Hirschmann Railswitch (L2E software, telnet) |
| `junos` | Juniper EX Switch JunOS |
| `mediant` | Audiocodes Mediant |
| `mediant-sbc` | AudioCodes Mediant SBC / gateway with the current Cisco-style CLI (“Welcome to AudioCodes CLI”; observed on a Mediant 500Li). SSH by default; `transport=telnet` or `auto` (telnet only if no SSH service answers, never after an authentication failure). Reads `show running-config full` from the privileged prompt after `enable`; pager disabled per session. Not the older menu-style CLI — that is `mediant`. |
| `mikrotik` | MikroTik routers |
| `nec-univerge-ix` | NEC Univerge IX |
| `nexus-ssh` | Cisco Nexus switches (NX-OS, SSH; observed on 10.4(7)). Administrator account required — NX-OS has no `enable`, a `>` prompt is reported as an error. The `!Time:` header line changes on every run and is ignored by `changes_only`. |
| `parks` | Parks 209R |
| `planet-ssh` | PLANET managed switches (Cisco-IOS-like CLI, SSH; observed on IGS‑4215‑16P2T2S and IGS‑5225‑8P4S, also reported working on the M‑Series — with or without the switch’s own Username/Password dialog after the SSH login, with or without a “Building configuration…” banner, and whether one or two `exit`s end the session) |
| `procurve` | HP ProCurve switches (telnet); see also `procurve-ssh` |
| `procurve-snmp` | HP ProCurve ProVision, incl. the older 4000M/8000M chassis, over SNMP+TFTP (no CLI needed). See [ProCurve SNMP backups](#procurve-snmp). |
| `procurve-ssh` | HP ProCurve switches over SSH (the SSH counterpart of `procurve`; also handles a hostname containing spaces) |
| `procurve-web-1700` | HP ProCurve 1700 series (1700‑8, 1700‑24; HTTP web UI — web-managed only, no CLI). See [Web UI backups](#tplink). |
| `riverstone` | Alcatel Ethernet Router 3100 (Riverstone RS3100) |
| `tellabs-msr` | Tellabs MSR routers |
| `terayon-os` | Terayon 3200/3500 CMTS |
| `tplink-web-sg105e` | TP-Link Easy Smart switches (TL‑SG105E, TL‑SG105PE and siblings, HTTP web UI — these switches have no CLI). See [Web UI backups](#tplink). |
| `zyxel` | Zyxel switches (Cisco-IOS-like CLI, telnet) |

Need a device that isn't listed? Two routes: describe it with a
 template (see [Template-driven model](#template-model) below),
 or write a per-device Perl model — see
 [How to add a model](How-To-add-a-model.html).

## Template-driven model (generic) {#template-model} {nav: Template model}

Describe a device with a template instead of a Perl module. On native Windows the template model's `transport=ssh` is unavailable (SSH needs `Net::OpenSSH`/`IO::Pty`); use `transport=telnet`. See [Platform support](#platform-support).

Besides the per-device Perl models, fetchconfig has a `generic` model whose device interaction is described by a **template** file rather than Perl code. A template is a small state machine of expect/send steps, with the transport, prompt, timeouts, interrupt screens and ignore-lines as data. For a clean-CLI device this is a short file rather than a ~200-line module, and similar devices can share or clone one template.

A device selects it in the device table with the model `generic` and a template name:

```
generic  sw1  10.0.0.1  model=cisco-ios,transport=ssh,user=...
```

This loads `templates/cisco-ios.tmpl`; `transport` is `ssh` or `telnet`. Templates for Cisco IOS/IOS-XE (both transports) and HP ProCurve (menu/VT100) ship as worked examples. Two companion tools support the workflow: `tools/record-session.pl` captures a real session as a byte-accurate log to build a template from, and `tools/generate_template.pl` scaffolds a template draft from such a capture. For Windows users without Perl, `contrib/windows/` contains Python ports of these two tools (`record_session.py`, `generate_template.py`) with the same command line and file formats; `build.cmd` packages them into standalone `.exe`s with PyInstaller. See `contrib/windows/README.windows`.

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

The generic model's device-table options — and the template-only directives — are listed under [Per-model option tables](#per-model-options) in the Options reference.

> [!plain] Further reading
> The generic model and its tools are documented separately:
>
> - [README.generic-model](README.generic-model.html) — the generic model & template engine: architecture, template grammar, execution semantics, writing and generating templates, and the `record-session.pl` capture tool
> - [How to add a model](How-To-add-a-model.html) — writing a new per-device Perl model (the alternative to a template)
> - [README.fc-snmp-inventory](README.fc-snmp-inventory.html) — the read-only `tools/fc-snmp-inventory.pl` SNMP inventory probe: what a device exposes, what the inventory feature derives from it, and which `snmp-profiles.conf` directive to add when onboarding a new device or vendor

The template parser is production-ready; the execution engine has been verified on Cisco IOS-XE over telnet and SSH and on an HP ProCurve menu switch. Verify a template against the target device before relying on it.

<!--nav-group: Features-->

## Parallel fetching {#parallel}

Fetching is sequential unless asked otherwise: one device at a time, in device-table order, every log line shown as it happens. With thousands of devices the run time is dominated by the network sessions (roughly 5–15 s each, plus a full timeout for every unreachable device), and a sequential run no longer fits in a night.

```shell
./fetchconfig.pl -devices=device_table -P 20
```

`-P N` fetches with `N` concurrent worker processes. The parent loads the device table, then hands out one device at a time to whichever worker asks next, so a slow device never holds up the others. Every worker is a copy of the fully loaded parent, so the models run unchanged. With `N` = 10–20 a run of several hours typically completes in well under one; the gain is bounded by what the devices and the network tolerate, not by the backup host.

> [!note] Output is atomic per device
> While a worker fetches, everything it writes to stdout and stderr is buffered; when the device finishes, the parent copies that buffer to the real streams in one uninterrupted block. One device’s output is therefore **never mixed with another’s** — each block looks exactly as in a sequential run. Two consequences: blocks appear in *completion* order, not table order; and a device’s lines appear when it finishes, not live. At `-P 1` nothing is buffered and behaviour is unchanged.

Everything else is unaffected: each device writes only its own directory, `.status` and `.debug`; the summary e-mail, per-device `to=` bundling and the `.status` files are produced by the parent from the workers’ results, exactly as in a sequential run; `keep=N` expiry and `changes_only` comparison run per device as before. A worker that dies is detected by the parent; the device it was fetching is recorded as failed and the remaining devices are still fetched by the other workers.

**Sizing `N`.** Start at 10 and raise it while watching for devices that refuse or delay logins: the limits are the switches’ concurrent-session caps, the TACACS+/RADIUS rate, and the links to remote sites — not the backup host. 10–25 is typical. `-P` applies to fetching only and cannot be combined with the lookup/maintenance modes, which stay single-process.

On **native Windows** there is no `fork`, so `-P` always runs sequentially (`N>1` is reduced to `-P 1`); see [Platform support](#platform-support).

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

## ProCurve SNMP backups (ProVision, 4000M/8000M) {#procurve-snmp} {nav: ProCurve SNMP}

The older HP ProCurve ProVision chassis (4000M, 8000M) can only be managed remotely through a VT100 menu, which is not usable for scripted backup. They will, however, export a text copy of their configuration over TFTP when told to over SNMP, and that is what `procurve-snmp` does. It is a transport unlike the other models — no shell and no web UI, but SNMP plus TFTP — and so has no `user`/`pass`: the credential is the SNMP read-write `snmp_community` (renamed from `community` in 9.80).

An SNMP set arms the switch’s TFTP export, the config is fetched from the switch by TFTP, and a second SNMP set disables the export again. That disable always runs, even when the transfer failed, so the switch is never left with its TFTP server open.

> [!note] SNMP options renamed in 9.80
> `procurve-snmp` now uses the shared `snmp_*` option namespace (see [SNMP device inventory](#snmp-inventory)): `community` → `snmp_community`, and the SNMP timeout is `snmp_timeout` (no longer the shared telnet/SSH `timeout`). **`snmp_timeout` defaults to 5 s, down from the old implicit `timeout=30`** — set `snmp_timeout=30` on these lines to keep the former behaviour, especially if the TFTP export is slow. A site that keeps a separate read-write community can set `snmp_write_community`; otherwise `snmp_community` must be read-WRITE for this model. Update affected device-table lines when upgrading.

> [!note] browse vs. running-config
> The default `remote_file=browse` produces a human-readable report — fine for backup and change tracking, but a display export, not a file that can be TFTP’d back to restore the switch. Later ProVision models also accept `remote_file=running-config`, a replayable config.

> [!warn] TFTP is inbound
> The switch pushes the file to the backup host over TFTP (UDP/69 inbound, then a data port). A host firewall on the backup machine can block this; it then shows up as a TFTP get failure or timeout, not a hang.

## SNMP device inventory {#snmp-inventory} {nav: SNMP inventory}

During a normal backup run, fetchconfig can also collect a **hardware inventory** of each device over SNMP — vendor, model, serial number, OS version, and the serial-bearing parts (stack members, modules, power supplies, and optionally optics) — and write it to the fetchconfig-web dashboard database (schema 2.15). It is **model-independent**: one collector runs for every model, reading the standard **ENTITY-MIB** physical table plus the system group, so it works across vendors without per-model parsing.

Inventory is **entirely opt-in and off by default**: it runs for a device only when SNMP credentials are configured for it — `snmp_community` (or `snmp_write_community`) for SNMPv1/v2c, or `snmp_user` for SNMPv3. A read-WRITE community reads fine, so a `procurve-snmp` device that carries only `snmp_write_community` is inventoried too (the read session falls back to it). It is **independent of the config backup** (a device whose SSH/telnet backup failed, or an SNMP-only device, still gets inventory) and **never affects the backup**: an SNMP failure is a warning unless `snmp_fatal=on`.

> [!note] Requires the fetchconfig-web 2.15 database (2.16/2.17 for the extra fields)
> The inventory tables are created and owned by fetchconfig-web (`fetchconfig-web-dbsetup.pl --upgrade`, schema 2.15). The engine only writes them, through the same store-and-forward outbox as the [backup-history DB](#backup-history). Against a database not yet migrated to 2.15 the inventory writes are silently skipped — backups and backup history are unaffected. The two later additions need a newer schema and are written only where the column exists: per-component firmware/ROMMON (`fw_version`) needs **2.16**, and the `sysName`/`sysLocation`/`sysContact` headline needs **2.17** (the engine probes for each and omits it against an older DB, so one engine build runs against 2.15/2.16/2.17).

### SNMP options

All of these are ordinary device-table options: set them on a model’s `default:` line (shared) and override per device as needed — except `snmp_profile_file`, which is `default:`-only (see its note below).

| Option | Default | Meaning |
|---|---|---|
| `snmp_community` | *(none)* | SNMP read community (v1/v2c). Its presence enables inventory. Secret. For `procurve-snmp` it must be read-WRITE. |
| `snmp_write_community` | `= snmp_community` | Read-WRITE community. Used by `procurve-snmp` to arm the TFTP export, and also enables/serves the inventory read when no `snmp_community` is set. Secret. |
| `snmp_version` | `2c` | `1`, `2c`, or `3`. |
| `snmp_port` | `161` | SNMP agent UDP port. |
| `snmp_timeout` | `5` | Per-request timeout, seconds (SNMP-specific — not the telnet/SSH `timeout`). |
| `snmp_retries` | `1` | Retries per request. |
| `snmp_max_repetitions` | `25` | GET-BULK max-repetitions for the ENTITY-MIB walk (v2c/v3). Higher = fewer round-trips on a large stack; lower it only if an agent rejects a big bulk response. Ignored for v1 (no GET-BULK). |
| `snmp_user` | *(none)* | SNMPv3 user. Its presence enables inventory. |
| `snmp_level` | *derived* | SNMPv3 `noAuthNoPriv` / `authNoPriv` / `authPriv`; derived from the credentials given, or set to assert a minimum. |
| `snmp_authproto` | `sha` | SNMPv3 auth protocol (`md5`/`sha`/…). |
| `snmp_authpass` | *(none)* | SNMPv3 auth passphrase. Secret. |
| `snmp_privproto` | `aes` | SNMPv3 privacy protocol (`des`/`aes`/…). |
| `snmp_privpass` | *(none)* | SNMPv3 privacy passphrase. Secret. |
| `snmp_inventory` | `on` | Master switch (boolean: `on`/`off`, `1`/`0`, `yes`/`no`). `off`/`0` disables inventory on a device even if a community is inherited from `default:`. |
| `snmp_inventory_level` | `1` | `1` = chassis + modules + power supplies; `2` also captures transceivers/optics (higher churn). |
| `snmp_inventory_history` | `on` | Boolean (`on`/`off`, `1`/`0`). Whether a hardware/OS change appends an audit row to the inventory history. |
| `snmp_fatal` | `off` | Boolean (`on`/`off`, `1`/`0`). `on` makes a failed inventory attempt a device error (exit 11); the config backup is never affected. |
| `snmp_inventory_interval` | `0` | Seconds. `0` (default) collects inventory every run. When set, a run **skips** the SNMP read if the last successful inventory for the device is younger than this, and carries that result forward (DB and `.status` unchanged) — so config backups stay fast on a device whose SNMP inventory is slow. A failed or missing prior forces a fresh read. E.g. `86400` = at most once a day. |
| `snmp_profile_file` | shipped `snmp-profiles.conf` | Optional override for the vendor/model profile file (`vendor`, `model`, `oid` and `override` lines keyed by `sysObjectID` or enterprise number). **`default:`-only** — see the note below. |

> [!note] `snmp_profile_file` is a `default:`-only option
> `snmp_profile_file` may be set **only on a `default:` line**, never on a device line. One file serves the whole fleet (it can list many vendors/models), and the parsed file is cached process-wide, so a value on a device line would not take effect anyway — the engine therefore **ignores a device-line `snmp_profile_file` and logs a warning**. It is the only `snmp_*` (and, currently, the only device-table) option restricted this way; every other `snmp_*` option is usable on both `default:` and device lines.

A minimal SNMPv2c setup is one line on the model’s `default:`:

```
default:  cisco-ios  user=backup,pass=secret,snmp_community=public
```

Stacks are reported with every member’s serial; the dashboard shows make/model/serial/OS and, per device, a `disabled` / `successful` / `failed` state. Each run also logs one per-device line for the inventory outcome (`SNMP inventory read successful (…) in N secs`, `read failed after N secs: …`, or `disabled`), alongside the config-retrieval line — note the config-retrieval time does **not** include the SNMP work, which the inventory line times separately.

The same per-device state and headline are also written to the `<dev_id>.status` file (in addition to the database): an `inventory=disabled|successful|failed` line, and on a successful/failed read the `inventory_source`/`inventory_vendor`/`inventory_model`/`inventory_serial`/`inventory_os_version`/`inventory_sysname`/`inventory_syslocation`/`inventory_syscontact`/`inventory_member_count`/`inventory_hw_set` values. A device not configured for inventory writes no `inventory*` keys. The full component list and change history live only in the database.

`backup_duration_sec` (in `.status`, and the duration in the summary and the history DB) is the **whole** per-device time — config fetch **plus** the SNMP inventory collection — so a dashboard spinner keyed on it reflects the real wall-clock, not just the config fetch. The two per-device log lines break the total down (`config retrieval took N secs` + `SNMP inventory read … in N secs`).

Performance: on a large stack most of the `entPhysicalTable` is ports and sensors the inventory never stores, and some agents (notably HPE Comware IRF stacks) serve that table slowly. So on v2c/v3 the collector **GET-BULK-walks only `entPhysicalClass`** (the one column it must read for every row) and then **GETs the descriptive columns for just the parts it keeps** — chassis, modules, power supplies (and transceivers at level 2) — instead of pulling every column for every port. `snmp_max_repetitions` (default 25) tunes the class walk; raise it (e.g. 50–100) on a slow agent to cut round-trips. On v1 (GET-NEXT only, no GET-BULK) it falls back to a full per-column walk and is unavoidably slower — prefer v2c/v3 for inventory. Some agents (again, Comware IRF stacks) serve the `entPhysicalClass` pass slowly no matter how it is batched; if a device's inventory stays costly and its hardware rarely changes, set **`snmp_inventory_interval`** so the slow read runs only every so often (e.g. once a day) while config backups stay fast every run — the last inventory is carried forward in between.

### Identification and best-effort fallbacks

The collector derives vendor, model, serial and OS version from the ENTITY-MIB, with fallbacks for devices whose ENTITY-MIB is sparse (notably the old menu-only ProCurve chassis such as the 4000M/8000M, which report a chassis descr but no serial and no software rev):

- **vendor** — the canonical name from the vendor registry in `snmp-profiles.conf` (matched by `sysObjectID`, full or longest prefix, then enterprise number; built-in: Cisco, HP, Hirschmann (Belden), Zyxel Communications, PLANET Technology Corporation, Aruba Networks, HPE Comware, HPE Aruba Networking), else the ENTITY `entPhysicalMfgName` as reported, else `unknown`. The raw `entPhysicalMfgName` is always kept too, as `vendor_raw`.
- **model** — ENTITY `entPhysicalModelName`, else `entPhysicalDescr`, else a `sysObjectID → model` lookup from the profile file’s `model` lines (built-in: the 4000M `J4121A` and 8000M `J4110A`). Add more with `model <sysObjectID> <name>`.
- **os_version** — ENTITY software/firmware rev, else a best-effort parse of `sysDescr` (`revision C.09.30`, `Version 17.12.04`, …).
- **sysName / sysLocation / sysContact** — the device's own configured name, location and contact (SNMPv2-MIB system group), read on every device regardless of ENTITY-MIB and stored verbatim (`device_inventory`, web schema 2.17; the engine writes them only when those columns exist). These are current-state only — a rename or relocation does **not** write a change-history row.
- **member_count** — the number of serial-bearing chassis (a stack counts its members); when no chassis carries a serial, the count of physical chassis entities instead, so a lone serial-less chassis is `1`.

Each stored component carries its own running software (`entPhysicalSoftwareRev`) and firmware/ROMMON (`entPhysicalFirmwareRev`) revisions — so a stack's per-member IOS and ROMMON are both recorded (the firmware goes to `device_inventory_component.fw_version`, web schema 2.16; the engine populates it only when that column exists and the agent returns a non-empty value, mostly Cisco). A device with no serial anywhere still records `successful` with the data it could read; only parts that carry a serial appear in the component list, and `hw_set` covers only serial-bearing chassis/modules/power supplies.

**Devices that describe themselves as a `stack`** rather than a `chassis` in the ENTITY-MIB (entPhysicalClass `stack`, e.g. Zyxel single-unit switches) are handled automatically: when the table has no `chassis` entry but does have one or more `stack` entries, each stack entry is **promoted to a chassis**, so its model/serial/OS/hardware revision are harvested exactly like a normal chassis (and counted as a member). A device with a real chassis keeps it and ignores the `stack` entry, which there is only a logical container.

**Devices with no ENTITY-MIB at all** — e.g. Hirschmann classic RS/MACH switches, which keep their identity in a private MIB — are **not** marked `failed` as long as they answer the system group. The collector records a one-device headline: vendor from the `sysObjectID` enterprise, plus model/serial/OS read from the vendor's **private MIB** when `snmp-profiles.conf` has `oid` lines for it. An `oid` line names a headline field (`model`, `serial` or `os_version`), the matching enterprise number or `sysObjectID`, a fully-indexed instance OID, and an optional regex whose first capture group is taken from the raw value:

```
oid model      248  1.3.6.1.4.1.248.14.1.1.9.1.3.1
oid os_version 248  1.3.6.1.4.1.248.14.1.1.2.0  SW:\s*(\S+)
```

`oid` lines are read **only when the ENTITY-MIB is absent**, and only for fields still empty — real ENTITY data always wins. Resolve a vendor's private-MIB symbols to numeric OIDs offline (`snmptranslate -On`); the runtime uses numeric OIDs only.

An `oid` (or `override`) OID that ends in **`.*`** is a bare table-**column** base rather than a fully-indexed instance: the engine walks it with a single GETNEXT and takes the first row inside that column. This is for a single value whose index is per-device and not known in advance, so one line serves the whole fleet with no hard-coded index. The walk is opt-in per rule (only the line carrying `.*`); every plain instance OID keeps its exact-GET behaviour, so no other model is affected.

**Member tables (`members`).** When a device *aggregates others* — e.g. an Aruba virtual-controller AP that lists all of its member APs in `AI-AP-MIB::aiAPTable` — a `members` line records **one chassis member per row**, like a stack. Each value is a table-**column** base; the engine walks the serial column (which enumerates the members) and joins the model/name/os columns by the same per-row index (a MAC), producing one component per member (with `member_count`, `member_serials` and `hw_set` following). `serial=` is required; `model=`/`name=`/`os=` are optional. The member whose name matches the device's `sysName` (the controller's own entry) becomes the primary, and the headline serial is the primary's:

```
members 14823  serial=1.3.6.1.4.1.14823.2.3.3.1.2.1.1.4  model=…1.6  name=…1.2
```

Like every other profile directive, `members` is keyed by enterprise number or `sysObjectID`, so it is **not** Aruba-specific — any device that lists its sub-units in a private-MIB table (another WLAN controller, a modular system) can be inventoried this way with one line and no code change. It is read on the ENTITY-less path (a device with a real ENTITY-MIB stack already yields members directly).

To work out which of these directives (if any) a device needs, use the read-only probe `tools/fc-snmp-inventory.pl`: it prints what SNMP exposes, what the inventory feature derives from it, and which `snmp-profiles.conf` directive matched — see [README.fc-snmp-inventory](README.fc-snmp-inventory.html).

**Correcting a wrong ENTITY value (`override`).** Some devices implement the ENTITY-MIB but populate it with the wrong thing — e.g. PLANET's Vitesse-based switches report the SoC codename `Luton26` in `entPhysicalModelName`, while the real product (`IGS-5225-8P4S`) is only in `sysDescr`. An `override` line **replaces** a present-but-wrong field (unlike `oid`, which only fills an empty one):

```
override model 10456  sysdescr  ^PLANET,\s*([^,]+)
```

`override <field> <enterprise|sysObjectID> <source> [<regex>]` — `<field>` is `model`, `serial` or `os_version`; `<source>` is a numeric OID (GET one instance) or a symbol naming already-collected data (`sysdescr`, `entdescr`, `entmodel`, `entserial`); the optional regex's first capture group (trimmed) becomes the value. A regex miss leaves the ENTITY value in place — an override never blanks a field. Matched most-specific-first, and consulted **before** the ENTITY value. Both `oid` and `override` apply on the ENTITY-less headline path as well, so a device with no ENTITY-MIB can still get its model/serial/OS from `sysDescr` or a private MIB. Aruba WLAN APs/controllers (AOS-8 / Instant, enterprise 14823) are the worked example: the shipped profile carries `override model 14823 sysdescr MODEL:\s*([^)]+)` (model from the `(MODEL: nnn)` token; OS then from the `sysDescr` parse) and a `members` line that walks the AI-AP table so a virtual controller inventories all of its member APs (see *Member tables* above).

**File syntax.** One directive per line; leading/trailing whitespace is ignored and fields are whitespace-separated (a name or regex is read verbatim to the end of the line, so it may contain spaces). A line whose first non-blank character is `#` is a comment and blank lines are skipped — there are **no inline comments** (a `#` after a directive becomes part of the value). A match token is read as an enterprise number when it is all digits, otherwise as a `sysObjectID`/prefix when dotted. A line that matches no directive, or whose field/OID/match is malformed, is **silently ignored** (no error) — so after adding a line, confirm it took effect with the `profile` section of `tools/fc-snmp-inventory.pl`. The file is optional and merges on top of the built-in registries.

## Credential aliases (`pw:`) {#credential-aliases} {nav: Credential aliases}

A `pw:` line defines a username or password **once** and lets you reference it as `$Alias` on any `default:` or device line — exactly like a [`directory:` tag](#directory-allowlist). Change a shared password in one place instead of on every line.

```
pw: user $Admin  backup
pw: pass $AdminPw secret

default:  cisco-ios  user=$Admin,pass=$AdminPw
default:  cisco-ios-ssh  user=$Admin,pass=$AdminPw,enable=$AdminPw
```

- `pw: <kind> $Alias <value>` — `kind` is `user` or `pass`. The alias name is `$Name`: a `$` followed by a **letter or underscore — not a digit** — then any letters, digits or underscores (`$Admin`, `$pass_site1`). The value follows the same quoting rules as an inline `user=`/`pass=` value (quote anything with a comma or space), so an alias is a drop-in for what you would otherwise type inline.
- An alias is used as the **whole value** of a credential option: `user=$Admin`, not `user=pre$Admin`.
- **user**-kind aliases fit `user=` and `snmp_user=`; **pass**-kind aliases fit `pass=`, `enable=`, and the SNMP secrets `snmp_community=` / `snmp_write_community=` / `snmp_authpass=` / `snmp_privpass=`. So one `pw: pass` alias can feed a telnet password and an SNMPv3 passphrase alike.
- `pass`-kind values are masked in logs. An undefined alias, or one used in the wrong kind of slot, is rejected with a clear error (the device is not logged into with a literal `$Name`).

### Literal credentials that start with `$` or `\` {#credential-literals} {nav: Literal $ credentials}

A credential value is interpreted by its **first character** — the three forms are mutually exclusive:

- **`"` → a quoted literal** — fully verbatim, never an alias, and the backslash rules below do not apply inside it. Use quotes for any value that contains a comma or whitespace (required on `default:`/device lines, which are split on both), and as the simplest way to write a literal that starts with `$`.
- **`$` → an alias reference** — it must match `$Name` (`^\$[A-Za-z_][A-Za-z0-9_]*$`) and resolve to a defined `pw:` alias of the right kind (user-kind for `user`/`snmp_user`; pass-kind for the rest). An undefined or wrong-kind alias is a **hard error** (the run, and a fetchconfig-web save, are rejected), never a silent literal.
- **anything else → an unquoted literal**, with a **first-character-only** de-escape: a leading `\$` becomes `$`, a leading `\\` becomes `\`, and any other first character is taken as-is. Interior `\` and `$` are never touched, so ordinary values like `DOMAIN\user` or `pa$$w0rd` need no escaping at all.

To force a literal that starts with `$` or `\`, either quote it (`"$ecret"`) or escape the first character (`\$ecret`). You never need both — a value that needs quoting is simply quoted.

| Entered (after `pass=`) | Interpreted as | Rule |
|---|---|---|
| `$NetPass` (defined) | the alias's value | unquoted `$`, valid name, defined |
| `$nope` (undefined) | **error** | undefined alias rejected |
| `\$abc` | `$abc` | unquoted, leading `\$`→`$` |
| `\\$xyz` | `\$xyz` | unquoted, leading `\\`→`\`, rest verbatim |
| `ab$cd` | `ab$cd` | `$` not the first character |
| `C:\tools` | `C:\tools` | verbatim |
| `C:\\tools` | `C:\\tools` | interior untouched |
| `DOMAIN\user` | `DOMAIN\user` | verbatim |
| `pa\$\$` | `pa\$\$` | interior untouched |
| `"$abc"` | `$abc` | quoted → fully literal |
| `"$ab,cd"` | `$ab,cd` | quoted → literal (handles the comma and the `$`) |
| `"my,pass"` | `my,pass` | quoted → literal (comma) |
| `"$NetPass"` | `$NetPass` (the literal, not the alias) | quoted → literal |

This grammar only affects a value whose **first character** is `$` or a backslash. Everything else — including a value that merely *contains* a dollar or a backslash, such as `DOMAIN\user` or `pa$$w0rd` — is stored verbatim and needs no change. When you upgrade a table that already holds a credential starting with `$` or a backslash, re-save it in the escaped or quoted form shown above.

<!--nav-group: Reference-->

## Retrieving a previously backed-up config {#retrieving} {nav: Retrieving backups}

In addition to fetching configuration from devices, fetchconfig.pl can retrieve a configuration file already saved in the repository, without contacting the device again — useful for scripting: dumping the latest config to stdout, comparing today's config against yesterday's, or pulling an older backup by its position in the history. The examples below walk through retrieval and the related repository-maintenance modes; the full, grouped option reference follows under [Flag reference](#flag-reference).

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

Sample output (tab-separated: number, size in bytes, path). The numbers in the first column are exactly what `-n`/`-m` expect (1=latest, 2=next most recent, …).

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

Add `-D` to delete the empty backups `-z`/`-Z` find — only the empty backup **files** (never directories), and only for devices still in the table, since `-z`/`-Z` look only at loaded devices (a decommissioned device’s leftovers are orphaned files, cleaned with `-o` below). Preview first with `-T`: the deletes are logged as `would delete: unlink <path>`, nothing is removed.

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

### 8. Find empty directories

```
./fetchconfig.pl -devices=device_table -e            # list
./fetchconfig.pl -devices=device_table -e -D -T      # preview delete
./fetchconfig.pl -devices=device_table -e -D         # delete
```

`-e` finds empty directories left behind in the repositories (e.g. after deleting old backups by hand); with `-D` it removes them bottom-up. See the [Flag reference](#flag-reference) for the full semantics.

### 9. Check suffix consistency

```
./fetchconfig.pl -devices=device_table -s fw01.acme.net   # one device
./fetchconfig.pl -devices=device_table -S                 # every device
```

Checks whether a device's backups carry inconsistent filename suffixes (e.g. after `filename_append_suffix` was introduced on a device that already had backups). See the [Flag reference](#flag-reference).

### 10. Save to a file instead of stdout

```
./fetchconfig.pl -devices=device_table -g fw01.acme.net -n 2 -f config.file
```

### 11. Compare two backups

```
./fetchconfig.pl -devices=device_table -g fw01.acme.net -n 1 -m 2
```

Output matches the standard `diff older newer` convention: lines starting with `<` come from `-m` (older), lines starting with `>` come from `-n` (newer).

**Not available on native Windows:** the comparison shells out to an external `diff` and is disabled there — it exits with an error instead of a diff. See [Platform support](#platform-support).

> [!note] stdout stays clean
> Log/diagnostic messages always go to stderr, so stdout only ever carries the retrieved config content — safe to pipe and redirect, e.g. `./fetchconfig.pl -devices=device_table -g fw01.acme.net > latest.cfg`.

The device-unique-id passed to `-g` (or `-l`) is looked up in the device table(s) given with `-devices=` and/or `-line=`, exactly as when fetching; at least one of `-devices=` or `-line=` is therefore still required. Only the device's options (model, repository, etc.) are resolved — the device itself is **not** contacted.

### Flag reference {#flag-reference}

#### Retrieval options {.flag-group}

<!--flag: -g dev_id | mutually exclusive with -l / -z / -Z / -o / -e / -s / -S / --db-backfill-->
Retrieval mode for `dev_id` instead of fetching from every device in the table(s). `dev_id` must match a device line's dev-unique-id. Plain retrieval works on all platforms; the compare form (`-g … -m`) is not available on native Windows (see [Platform support](#platform-support)).
<!--/flag-->

<!--flag: -l dev_id | mutually exclusive with -g / -z / -Z / -o / -e / -s / -S / --db-backfill-->
Listing mode: prints one line per backup on file, newest first — `<number>\t<size>\t<path>`.
<!--/flag-->

<!--flag: -n N | optional-->
Selects which backup to retrieve, counting from the most recent: `N=1` latest (default), `N=2` the one before that, and so on. Selecting a backup works on all platforms; only the `-m` comparison it feeds is unavailable on native Windows.
<!--/flag-->

<!--flag: -m M | requires -g-->
Compare mode: prints a diff between backup `M` (older) and backup `N` (newer) instead of printing backup `N`. `M` must be numerically higher than `N`. On native Windows this is disabled (it needs an external `diff`) and exits with an error.

<!--exit-list-->
- 0 | the two backups are identical
- 1 | the two backups differ -- OR an in-mode error prevented the compare (a missing backup `N`/`M`, or `diff` could not run); on Linux/AIX these are not distinguished from "differ"
- 2 | native Windows only: compare is unsupported (it needs an external `diff`)
<!--/exit-list-->
<!--/flag-->

#### Housekeeping options {.flag-group}

<!--flag: -z dev_id | mutually exclusive with -g / -l / -Z / -o / -e / -s / -S / --db-backfill-->
Zero-byte check for one device, same tab-separated format as `-l`. Nothing prints if no backups are 0 bytes.

<!--exit-list-->
- 1 | at least one 0-byte backup found
- 0 | all backups non-empty
<!--/exit-list-->
<!--/flag-->

<!--flag: -Z | mutually exclusive with -g / -l / -z / -o / -e / -s / -S / --db-backfill-->
Same as `-z`, no dev_id — checks every loaded device: `<dev_id>\t<number>\t<size>\t<path>`. A device that can't be scanned is skipped and logged, and does not by itself cause a non-zero exit.
<!--/flag-->

<!--flag: -o | mutually exclusive with -g / -l / -z / -Z / -e / -s / -S / --db-backfill-->
Orphaned-backup check: lists device directories on disk with no matching dev_id in the currently loaded table(s) — `<name>\t<file count>\t<total bytes>\t<path>`. Scans every `repository=` path configured by a currently loaded device (deduplicated); a path used only by a device no longer in the table can't be discovered this way.

<!--exit-list-->
- 1 | at least one orphan found (backup dir or status/debug file)
- 0 | none found
<!--/exit-list-->
<!--/flag-->

<!--flag: -e | mutually exclusive with -g/-l/-z/-Z/-o/-s/-S/--db-backfill-->
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
- 0 | `-o`/`-e`: nothing needed deleting, or every removal succeeded
- 1 | `-o`/`-e`: a removal failed &middot; `-z`/`-Z`: a 0-byte backup was found (the check's own result; deleting it does not change the exit)
<!--/exit-list-->
<!--/flag-->

<!--flag: -T | requires -D (or --clean-lock-dir / --db-backfill)-->
Preview mode for `-o -D`, `-e -D`, `-z -D` and `-Z -D`: logs the delete commands `-D` would run (`would delete: rmdir/unlink <path>`), without deleting anything. Also valid with `--clean-lock-dir` (shows which lock files would be removed) and with `--db-backfill` (previews the counts without hashing or writing). Exit status is that of the plain check — `-o`: 1 if anything orphaned was found; `-e`: 1 if any empty directory was found; `-z`/`-Z`: 1 if any 0-byte backup was found; 0 otherwise. Use it before a bare `-D` run.
<!--/flag-->

<!--flag: -s dev_id | mutually exclusive with -g/-l/-z/-Z/-o/-e/-S/--db-backfill-->
Suffix-consistency check for one device: verifies that all of its backup files carry the same filename suffix. Reports the device if its backups mix suffixes — including “some with a suffix and some without”, which is what happens when `filename_append_suffix` was added or changed after backups already existed. Prints one tab-separated line per distinct suffix: `dev_id`, suffix (or `(none)`), count, example file. Prints nothing if consistent. An unknown `dev_id` exits 1. Honours `-f`.

A second step then compares the (single) suffix the backups use against the `filename_append_suffix` configured for the device and logs a warning if they differ — e.g. backups written before a suffix was configured. This step is skipped for a device whose backups are already inconsistent.

<!--exit-list-->
- 0 | backup suffixes are consistent, configured suffix matches backup file suffixes
- 1 | inconsistent backup suffixes (not checked against the configured suffix), or unknown device
- 2 | backup suffixes are consistent, but the configured suffix does not match them
<!--/exit-list-->
<!--/flag-->

<!--flag: -S | mutually exclusive with -g/-l/-z/-Z/-o/-e/-s/--db-backfill-->
Like `-s`, but takes no `dev_id` and checks every device loaded via `-devices=`/`-line=`. `-S` is a pure consistency check — it does *not* compare against the configured `filename_append_suffix` (that second step is `-s dev_id` only). Exit 1 if any device’s backups mix suffixes, 0 otherwise. Note `-s` takes a `dev_id`: write `-s dev_id -f file` or `-S -f file`; `-s -f file` is rejected.
<!--/flag-->

> [!note] How the suffix check separates the timezone from the suffix
> A backup is named `<dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>`, and `<tz>` is whatever `strftime` produced on the backup host — it differs by platform and **changes with daylight saving time** (AIX: `CET` in winter, `CEST` in summer; older AIX `NFT`/`DFT`). The check parses the tz token first — numeric `+0200`/`-0500` (Linux, modern Windows), a bare name `CEST` (AIX), `-CEST` (Solaris), or a multi-word name such as `W. Europe Standard Time` (older Windows) — and only then looks at what follows, so a DST change is **not** reported as a suffix change. It **only works if the suffix is separated from the tz by** `.`, `-` or `_`: `.` is the rule since v9.55; `-` and `_` are accepted so backups written before that rule are still recognized. One inherent ambiguity: `-` followed by uppercase letters is the Solaris tz form, so an old suffix like `-BAK` on a `timezone=hide` backup (no tz token) is read as a tz; `_BAK`, `-bak`, or any suffix after a real tz token are unambiguous.

#### Template options (generic model) {.flag-group}

<!--flag: -t, --list-template | honours -f-->
Lists the generic-model templates available to the loaded devices, one TAB-separated row per template: `<id> <section> <full_path> <model> <template_dir>`. `section` is `default` (a template in the directory the `default:` scope uses — the `default: generic template_dir=` if set, else the program default `templates/` beside fetchconfig.pl; feeds the defaults editor) or `device` (a template in a device-specific `template_dir=`; feeds the device editor). `template_dir` is the configured value as written (a directory: `$TAG` or a literal path), so a consumer can filter by exactly what the table holds; `full_path` is always the real resolved path (a `$TAG` is expanded). A device configuring the same path as the default still yields `device` rows, so a model may appear under both sections; device directories are deduplicated by configured path (no device id in the output). Rows are sorted default first, then device; within a section by directory, then model. Every directory to be scanned — the default included — must exist; a missing configured path is reported and the exit status is `2` regardless of what else was found, otherwise `0` if any template was found, `1` if none. Honours `-f`. See [Template-driven model](#template-model).
<!--/flag-->

<!--flag: --list-allowed-dirs | honours -f-->
Lists the `directory:` allowlist configured in the device table (see [Directory allowlist](#directory-allowlist)), one TAB-separated row per entry: `<id> <type> <tag> <path>`. It also lints: exit `0` if a `directory:` section exists and every entry is valid (well-formed and its path exists on disk), `1` if no section, `2` if any entry is invalid.
<!--/flag-->

<!--flag: --list-credentials | honours -f-->
Lists the `pw:` credential aliases configured in the device table (see [Credential aliases](#credential-aliases)), one TAB-separated row per alias: `<id> <kind> <name>`. **Values are never shown** — a `pass` alias's secret never leaves the table. It also lints: exit `0` if every alias is well-formed and every credential reference across the table resolves to a defined alias of the right kind, `1` if no aliases are configured, `2` if a `pw:` line or a reference is invalid. fetchconfig-web can gate device-table saves on this (`validate_table_with_fetchconfig`).
<!--/flag-->

<!--flag: --check-template PATH | no device table-->
Structurally checks the generic-model template at PATH (grammar + the load-time validator) and exits. PATH must be the **full path** to the `.tmpl` file — a bare name is not resolved, as the same name can exist in different `template_dir` directories. Prints `ok` or the errors; exits `0` ok, `1` errors, `2` file problem. Structural check only. Does not honour `-f`. It needs no device table and does **not** apply the directory: allowlist — any readable `.tmpl` path is checked.
<!--/flag-->

<!--flag: --template-syntax PATH | no device table-->
Prints the syntax style a generic-model template declares — the value of a `# syntax_style: <token>` header comment — to **stdout**, and exits. This is metadata for a config viewer (e.g. fetchconfig-web) to pick a highlighter for a `generic`-model backup, whose `generic` model name says nothing about the output syntax; it has no effect on a backup. PATH is the full path to the `.tmpl` file, as for `--check-template`. Exits `0` and prints the token if declared, `1` and prints nothing if not, `2` on a file problem (error to stderr). Log output stays on stderr, so stdout carries only the value. It needs no device table and does **not** apply the directory: allowlist — any readable `.tmpl` path is read. The value is a free-text token `[A-Za-z0-9_-]+`. fetchconfig-web currently recognises `cisco-ios`, `procurve`, `comware`, `zyxel`, `aruba-cx`, `nexus`, `mediant`, `template`, `json`, `xml` and `generic`; the set is open, and any other or absent value lets the viewer fall back to plain text.
<!--/flag-->

#### Fetching options {.flag-group}

<!--flag: -P N | fetching only-->
Fetch with `N` concurrent worker processes (default 1 = sequential, device-table order, live output). With `N>1` each device’s output is buffered while it runs and shown as **one uninterrupted block** when it finishes, in completion order — never interleaved with another device. Not combinable with `-g`/`-l`/`-z`/`-Z`/`-o`/`-e`/`-s`/`-S`/`--db-backfill`. See [Parallel fetching](#parallel). On Windows there is no fork, so `-P` always runs sequentially (`N>1` is reduced to 1).
<!--/flag-->

#### Output option {.flag-group}

<!--flag: -f file | optional-->
Writes the **result data** to `file` instead of stdout: the retrieved config (`-g`), the diff (`-m`), or the listing rows (`-l`, `-z`, `-Z`, `-o`, `-e`, `-s`, `-S`, `-t`, `--list-allowed-dirs`, `--list-credentials`). The file is created/overwritten as needed. It does **not** apply to `--check-template`, whose ok/error result is written to the log only.

The file receives *only* that data — never the screen output. All `info:`/`debug:`/`error:` lines, including the “checked N backup(s), …” summary and the “wrote … to file” confirmation, are log messages and always go to stderr.

For the listing/check modes (`-l`, `-z`, `-Z`, `-o`, `-e`, `-s`, `-S`, `-t`, `--list-allowed-dirs`, `--list-credentials`) the result data **ends with one summary line prefixed by `#`**, carrying the same text the run logs — e.g. `# dev=sw01: checked 2 backup(s), no zero-byte backups found` — so the output is never empty and is self-describing: a reader can tell “checked, nothing found” from “nothing was written” without the exit status or stderr. The rows before it contain only the items *found*. The trailer is part of the result stream, so stdout and `-f` carry identical content. It is *not* added to `-g` or `-m`, which stay byte-exact.

> [!warn] Format change for parsers (v9.55)
> Anything that parses these listings — fetchconfig-web in particular — must skip lines starting with `#`. Before v9.55 a check that found nothing produced a 0-byte file.
<!--/flag-->

#### Maintenance options {.flag-group}

<!--flag: --clean-lock-dir [N] | needs a device table-->
Removes device lock files older than `N` days (by mtime) from the lock directory, then exits. With `-T`, only shows what **would** be removed (dry run). `N` defaults to `30`, minimum `1`. A lock file is removed **only if it is not currently held** — the cleaner `flock()`s each candidate first and keeps any live lock — so an in-use lock is never deleted. At least one `-devices=`/`-line=` is required (the devices-required check runs before this mode); the lock directory is `<dir of fetchconfig.pl>/.lock` by default, so pass the device table that configures a custom `lock_dir=`/`directory: lock` to clean that directory instead. Exits `0` on success, `2` on a bad `N` or an unusable lock directory.
<!--/flag-->

<!--flag: --db-backfill | needs db:-->
Reconstructs the history database from the backups already on disk (requires a `db:` line; see [Backup-history database](#backup-history)), then exits — use it once after first enabling `db:`, since otherwise only new runs populate the DB. For every loaded device it scans its `repository=` and, for each stored backup not yet in the DB, inserts a `backup_versions` row (its sha1 **recomputed from the file** — identical to what a live save stores) and a `backup_runs` row (state `success`, `changed`, `run_end` = the backup's timestamp, no duration); it also inserts a `backup_current` row for each device that has none yet, from `<dev_id>.status` plus the newest backup. When the fetchconfig-web 2.12 line-delta columns exist it records `lines_added`/`lines_removed` on each version and UPDATEs existing version rows whose deltas are still empty. Idempotent and repeatable: an existing row is left alone, so a re-run only fills what is still missing (and does not re-hash a backup already recorded), and a `backup_current` row a live run wrote is never overwritten. Connects up front and aborts if the DB is unreachable. With `-T` it **previews** the counts (what would be inserted) without hashing or writing. Only saved backups can be reconstructed: the dense run history (unchanged or failed runs leave no file) is not on disk, so backfilled `backup_runs` rows are the saved change-events only (state `success`, no durations) — the full run history accrues from live runs afterwards. Mutually exclusive with the lookup/maintenance modes (`-g`/`-l`/`-z`/`-Z`/`-o`/`-e`/`-s`/`-S`); `-T` previews it. Exits `0` on success, `1` if the DB is unreachable or a write failed.
<!--/flag-->

<!--flag: --rename-device-id --old X --new Y | needs a device table-->
Renames a device id **everywhere it is used**, then exits: the device-table line, the on-disk backup tree, and — if a `db:` line is set — the backup-history database. Requires `--old <current-id>` and `--new <new-id>`. The new id must satisfy the [device-id rules](#device-table) (letters, digits, `_`, `.`, `-`; not all dots) and must not already be in use — the mode refuses if `--new` is in the table, has any on-disk backups/`.status`/`.debug`, or (when the DB is reachable) already has history rows. The device-table file is locked for the operation (an exclusive lock on a `<devices>.lock` sidecar; a concurrent run waits up to 2 s for it, then aborts). It then: renames every dated leaf directory `<repository>/YYYYMM/YYYYMMDD/<old>/` and the `<old>.run.*` files inside it to the new id, renames `<repository>/<old>.status` and `<old>.debug`, rewrites **only field 2** of the device-table line (model, host, options, comment and spacing preserved) atomically, and queues the DB change (`UPDATE dev_id` across `backup_current`/`backup_runs`/`backup_versions`) onto the repository outbox, draining it immediately. An interrupted rename leaves a `.rename-<old>-to-<new>.inprogress` journal in the repository so re-running the same command resumes it. With `-T` it **previews** every rename and the SQL without writing anything. The device must come from a `-devices=` file (not `-line=`). Mutually exclusive with the other modes and with `-P`. Exits `0` when fully done, `1` if the file/table rename succeeded but the DB change was left queued because the DB was unreachable (apply it later with [`--replay-db-change`](#flag-reference)), `2` on a validation or name-collision refusal (nothing changed).
<!--/flag-->

<!--flag: --replay-db-change | needs db:-->
Drains any **pending** history-DB operations from the per-repository outbox — device-id renames or statistics left queued while the DB was down — for every loaded device's repository, then exits. No fetching. This is the lightweight catch-up after a DB outage (a full run also drains the outbox at its end, but this applies it without touching any device). Requires a `db:` line. With `-T` it reports what is pending without applying it. Exits `0` if nothing remains pending after the drain, `1` if operations are still pending (the DB is still unreachable). Mutually exclusive with the other modes.
<!--/flag-->

#### Generic options {.flag-group}

<!--flag: -v, --version | version-->
Prints just the program version to stdout (one line, e.g. `9.78`) and exits with status 0. Nothing else is written — no banner, nothing on stderr — so a script can parse it safely.
<!--/flag-->

<!--flag: -?, -h, --help | help-->
Prints the usage/help text to stdout and exits with status 0. (Before v9.55, `-?` was treated as an unknown argument: it printed an error, the usage to stderr, and ended with “Died at …”.)
<!--/flag-->

> [!warn] Unknown device or missing backup
> If `dev_id` is unknown, or the device has no `repository` configured, fetchconfig.pl reports an error and exits non-zero; nothing is written to stdout or `-f`. Same if `-n` (or `-m`) refers to a backup that doesn't exist — use `-l` first if unsure how many backups exist. `-m` shells out to the standard `diff` utility, which must be available in `PATH`.

## Exit codes {#exit-codes} {nav: Exit codes}

Every invocation returns a process exit status a script can test. The per-flag cards above give each mode's codes; this is the consolidated summary.

Two codes are cross-cutting — they can come from any mode:

| Code | Meaning |
|---|---|
| `255` | Usage or argument error — an unknown or invalid option, a missing value, an illegal mode combination, or `--db-backfill` with no `db:` line. The usage text is printed to stderr and the program exits. |
| `2` | The device table's `directory:` allowlist has an error, so the run is refused before any fetch or lookup. Every mode **except** `--list-allowed-dirs`, which reports allowlist errors itself. |

Per mode (a mode not listing a code never returns it):

| Mode | Exit status |
|---|---|
| *(no mode flag)* — normal fetch run | `0` the run completed. `10` a device's lock directory could not be created or used (misconfiguration). `11` a device with `snmp_fatal=on` had its SNMP inventory collection fail (backups are unaffected). A per-device fetch failure is logged and does **not** change the exit. |
| `-g` — retrieve a backup | `0` backup emitted. `1` unknown device, no `repository`, or the selected backup does not exist. |
| `-g … -m` — compare two backups | `0` the two backups are identical. `1` they differ, **or** an in-mode error prevented the compare (a missing backup, or `diff` could not run) — on Linux/AIX these are not distinguished from "differ". `2` native Windows only: compare is unsupported (it needs an external `diff`). |
| `-l` — list backups | `0` listed (zero or more rows). `1` unknown device or no `repository`. |
| `-z` / `-Z` — zero-byte check | `0` all backups non-empty. `1` at least one 0-byte backup found. Adding `-D` does not change the status. |
| `-o` — orphan check | `0` none found. `1` at least one orphan found. |
| `-e` — empty-directory check | `0` none found (with `-e -D`, every `rmdir` succeeded). `1` empty directories found (with `-e -D`, at least one `rmdir` failed). |
| `-s` / `-S` — suffix check | `0` suffixes are consistent and the configured suffix matches. `1` inconsistent suffixes, or an unknown device. `2` consistent, but the configured suffix does not match. |
| `-t` / `--list-template` | `0` at least one template found. `1` none found. `2` a configured template directory is missing (regardless of what else was found). |
| `--list-allowed-dirs` | `0` a `directory:` section exists and every entry is valid. `1` no section. `2` an entry is invalid. |
| `--list-credentials` | `0` every `pw:` alias is well-formed and every credential reference resolves (right kind). `1` no aliases. `2` a `pw:` line or a reference is invalid. |
| `--check-template` | `0` ok. `1` structural errors. `2` file problem (PATH unreadable). |
| `--template-syntax` | `0` a syntax token is declared (printed to stdout). `1` none declared (nothing printed). `2` file problem (error to stderr). |
| `--clean-lock-dir` | `0` success. `2` a bad `N`, or an unusable lock directory. With `-T` it previews and writes nothing. |
| `--db-backfill` | `0` success. `1` the DB is unreachable or a write failed. With `-T` it previews and writes nothing. |
| `--rename-device-id` | `0` fully done. `1` the file/table rename succeeded but the DB change was left queued (DB unreachable) — apply it later with `--replay-db-change`. `2` a validation or name-collision refusal (nothing changed). With `-T` it previews and writes nothing. |
| `--replay-db-change` | `0` nothing left pending after the drain. `1` operations are still pending (DB unreachable). With `-T` it reports what is pending and applies nothing. |
| `-v` / `--version`, `-h` / `-?` / `--help` | `0` printed, then exit. |

`-n`, `-f`, `-P`, `-D` and `-T` are modifiers, not modes: the exit status is that of the mode they run under. With `-D` the status still reflects the check's own finding (`-z -D` stays `1` if a 0-byte backup was found); `-T` only previews and writes nothing.

## Options reference {#options}

The modules `CiscoIOS`, `CiscoCAT`, `CiscoASA`, and `CiscoPIX` recognize the following options; nearly every other model reuses the same set (see the per-model matrix below for exactly which apply). The template-driven `generic` model has its own additional options — see [Per-model option tables](#per-model-options).

Two option groups are **model-independent** and documented in their own sections rather than in the matrix below: the SNMP inventory options (`snmp_*`) under [SNMP device inventory](#snmp-inventory), and the credential aliases (`pw:`, usable in any `user=`/`pass=`/`enable=`/`snmp_*` credential slot) under [Credential aliases](#credential-aliases).

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
| `on_fetch_cat` | Optional | Boolean. If `on_fetch_cat=1`, the fetched configuration is also written to stdout. Available for all modules. |
| `timezone` | Optional | If `timezone=hide`, suppresses timezone information from the config filename. |
| `filename_append_suffix` | Optional | Appended to the generated backup filename, which then reads `<dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>`, e.g. `filename_append_suffix=.txt`. Available for all modules. **fetchconfig 9.x and later only accept a suffix that starts with a “.”** (a file extension); a dotless suffix, or one containing `/` or whitespace, fails that device’s backup with an error and writes nothing. **Do not add, remove or change the suffix once a device has backups** — files are found by their `<dev_id>.run.` prefix, so old and new names would coexist (`keep=N` expires them together, “latest” ordering can be affected). Decide before the first backup; use `-s dev_id` or `-S` to find devices whose existing backups already mix suffixes. |
| `to` | Optional | Overrides, for this device only, who receives the backup summary e-mail. See [E-mail notifications](#email-notifications) and [Change reports](#change-reports). Available for all modules. |
| `comment` | Optional | Free-text note about the device, for whoever reads the device table — not used anywhere else (not logged, not e-mailed, not saved into the backup file). Available for all modules. Example: `comment=lab switch`. |
| `site` | Optional | Free-text site/location tag, like `comment` — fetchconfig does not use it. Used by fetchconfig-web for per-site access control (users see only devices whose site matches their user record; a device with no `site` is visible only to “all sites” / site 0 users). Single-byte characters. Example: `site="Plant 3, Hall A"`. |
| `lock` | Optional | `lock=on` takes an exclusive flock on the device before backing it up, so two runs cannot back up the same device at once (overlapping cron, or a web “Backup Now” over a cron run). Values are `on` or `off`; default `off`. The lock releases when the run ends (even on crash) and the lock file is never deleted. On contention the device is retried (see `lock_retry`/`lock_retry_time`) and then recorded as **skipped**; the process exit code is not changed. |
| `lock_dir` | Optional | Directory for the lock files — a `directory: lock` `$TAG` or an absolute path. Default `<dir of fetchconfig.pl>/.lock`, created `0700` if absent; if it cannot be created or used, fetchconfig exits `10` after the run. Must be a **local** filesystem (flock over NFS on AIX is unreliable); a system directory is refused. |
| `lock_retry` | Optional | How many times to retry a locked device before skipping. Integer &ge; 0; default `5`. `0` = skip on first contention. |
| `lock_retry_time` | Optional | Seconds between lock retries. Integer &ge; 1; default `10`. Maximum wait before skipping is `lock_retry × lock_retry_time` seconds. |

> [!note] Quoting option values
> Any option value may be wrapped in double quotes, e.g. `comment="Building 3, Floor 2"`. This is only needed if the value contains a literal comma, since a comma otherwise separates one option from the next — quoting is never required just because a value contains spaces. Inside a quoted value, `\"` and `\\` represent a literal quote and backslash. Quoting is optional, not enforced: an unquoted value with a comma is still just split at that comma, exactly as before.

### Per-model option matrix

Beyond the options above, each model recognizes its own subset of `user` / `pass` / `enable` / `timeout` / `repository` / `keep` / `fetch_timeout` / `changes_only`. `on_fetch_run`, `on_fetch_cat`, `timezone`, `filename_append_suffix`, `to`, `comment`, `site`, the `lock…` options and `debug` are available for every model and are omitted here for space. The **SNMP inventory options** (`snmp_community`/`snmp_write_community`/`snmp_user`, `snmp_version`, `snmp_port`, `snmp_timeout`, `snmp_retries`, `snmp_max_repetitions`, the v3 `snmp_level`/`snmp_authproto`/`snmp_authpass`/`snmp_privproto`/`snmp_privpass`, and the `snmp_inventory`/`snmp_inventory_level`/`snmp_inventory_history`/`snmp_fatal`/`snmp_inventory_interval` controls) are likewise **model-independent** — any model may carry them to collect a hardware inventory alongside its config backup. They are documented once under [SNMP device inventory](#snmp-inventory) and omitted from the matrix and the per-model tables below. (`procurve-snmp` is the one model where `snmp_community`/`snmp_write_community`/`snmp_timeout`/`snmp_version` are *also* its transport credentials, so they appear in its own table too.)

| Model | user | pass | enable | timeout | repository | keep | fetch_timeout | changes_only |
|---|---|---|---|---|---|---|---|---|
| `3com-msr` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `acme` | opt. | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `aruba-cx-ssh`[^1] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-asa` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-asa-ssh` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-cat` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-ios` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-ios-ssh` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-iosxr` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-pix` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `cisco-sg300` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `comware-ssh` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `coriant-8600` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `dell` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `dmswitch` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `fortigate` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `generic`[^2] | opt. | &#10003; | opt. | opt. | &#10003; | opt. | opt. | opt. |
| `hirschmann`[^3] | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `junos` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `mediant` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `mediant-sbc`[^4] | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `mikrotik` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `nec-univerge-ix` | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `nexus-ssh`[^5] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `parks`[^6] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `planet-ssh`[^7] | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve-snmp`[^8] | — | — | — | —[^8] | &#10003; | &#10003; | — | opt. |
| `procurve-ssh` | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |
| `procurve-web-1700`[^9] | — | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `riverstone` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `tellabs-msr` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `terayon-os` | &#10003; | &#10003; | &#10003; | opt. | &#10003; | &#10003; | opt. | opt. |
| `tplink-web-sg105e`[^10] | &#10003; | &#10003; | — | opt. | &#10003; | &#10003; | opt. | opt. |
| `zyxel`[^11] | &#10003; | &#10003; | opt. | opt. | &#10003; | &#10003; | opt. | opt. |

`timeout` is shown as optional for every model because it has a built-in default: if it is set neither on the device line nor on the model’s `default:` line, fetchconfig uses **30 seconds** and logs `Using 30s fetch timeout because the timeout was not set for this model` at debug level. Before v9.55 an unset timeout fell through to the underlying library’s own default (10 s for telnet/SSH, 180 s for the web-UI models), so set it explicitly for anything but a lab test. **Exception: `procurve-snmp` (the `—` in its `timeout` cell).** Since 9.80 that model ignores the shared `timeout` entirely and takes its SNMP/TFTP timeout from `snmp_timeout` (default **5 s**); see footnote [^8].

[^1]: `aruba-cx-ssh`: `user` must be an administrator (AOS-CX has no `enable`; an operator’s `>` prompt is an error). Also works for HPE Aruba Networking AOS-8 wireless access points (confirmed on an AP model 515, AOS-8 8.13.2.2). Pager disabled with `no page`; the `Current configuration:` header is dropped. Also recognizes `banner_timeout`, `show_cmd`, `prompt_settle_ms` (idle-wait before matching the prompt, default 150 ms — the prompt token allows spaces and non-ASCII, and the wait keeps a banner line ending in “#” from being taken for the prompt) and `debug` (same debug file layout as `planet-ssh`).
[^2]: `generic` is the template-driven model: `model=` names the template and is mandatory (it may be set on a `default: generic` line so devices sharing one template need not repeat it, and a device line can still override it), `transport` is `ssh`/`telnet`, and `user`/`pass` are mandatory for SSH. It recognizes many more timing and prompt options (most also settable in the template) — see [Per-model option tables](#per-model-options) for the full list and defaults.
[^3]: `hirschmann`'s `enable` is optional because that firmware's `enable` command doesn't ask for a password; it's read defensively in case another firmware version does. `hirschmann` also recognizes `show_cmd` (optional; replaces `show running-config all`). The re-salted `users passwd <user> :v1:<hash>:` field — leading 18 hex (9 bytes) password-derived and stable, trailing hex a random salt regenerated on every read — is canonicalised before the `changes_only` comparison: the salt is collapsed and the prefix kept, so salt churn alone no longer forces a save while a real password change (which alters the prefix) still does. The saved backup keeps the exact hash; the report/e-mail masking is unchanged. The generic model offers the same via the template directive `canon /PATTERN/REPLACEMENT/`.
[^4]: `mediant-sbc` also recognizes `transport` (optional; `ssh` default, `telnet`, or `auto` = SSH with telnet fallback only when no SSH service answers), `prompt_settle_ms` (optional, SSH; idle-wait before matching the prompt, default 150 ms), `banner_timeout`, `pager_cmd` (optional; a command sent before the show command to disable paging, for firmware that offers one — its rejection, e.g. “Invalid command” or “%”, aborts the fetch; not needed on the observed Mediant 500Li) and `debug` (optional). Its `show_cmd` (optional) defaults to `show running-config` — the settings that differ from firmware defaults, the form the device’s own CLI-script export produces and that a restore via `copy cli-script from …` expects; `show running-config full` lists every parameter including defaults (better for auditing default changes across firmware upgrades, riskier to replay on newer firmware). To keep both, add a second device entry with its own dev_id and `show_cmd="show running-config full"`. The CLI pauses with ` --MORE--` after each screen; the pager is driven (a space is sent at each marker and the marker and its erase sequence are removed from the saved configuration) without entering configuration mode.
[^5]: `nexus-ssh`: `user` must land on the `#` prompt (NX-OS has no `enable`; a `>` prompt is an error). Pager disabled with `terminal length 0`. The `!Time:` header line of the running-config changes on every run and is ignored by `changes_only`; `!Running configuration last done at:` counts. Also recognizes `banner_timeout`, `show_cmd`, `prompt_settle_ms` (idle-wait before matching the prompt, default 150 ms) and `debug` (`on`/`off`, default off; records to `<repository>/<dev_id>.debug`, mode 0600, the ssh authentication record followed by the raw switch session).
[^6]: `parks` also recognizes `banner_timeout` (optional) — overrides the timeout used to wait for the initial `login:` prompt, since the Parks 209R can take many seconds to issue it.
[^7]: `planet-ssh`: `user`/`pass` serve the SSH authentication and, on firmware that shows one, the switch’s own `Username:`/`Password:` dialog that follows it. `enable` is optional and only used if the account lands on the `>` prompt; it defaults to the login password. The `! System Up Time:` header line of the running-config is kept in the backup but ignored by `changes_only`. Also recognizes `banner_timeout`, `show_cmd`, `debug` (to `<repository>/<dev_id>.debug`: first the ssh client’s verbose account of the SSH authentication, then the raw switch session — the SSH login itself is not switch output, so it can only appear as those ssh log lines) and `type_delay` (milliseconds between typed characters, default 100 — the switch does not reliably accept a burst of input right after a prompt, so every line is typed character by character; 0 disables the pauses).
[^8]: `procurve-snmp` has no `user`/`pass`: the credential is the SNMP read-write `snmp_community` (masked in logs; a split-credential site can read with `snmp_community` and arm the export with `snmp_write_community`). As of 9.80 it shares the `snmp_*` namespace (see [SNMP device inventory](#snmp-inventory)): **the shared `timeout` option no longer applies to this model — the timeout is `snmp_timeout`**, the per-request value that covers both the SNMP session and the TFTP transfer. A `timeout=` left on a `procurve-snmp` line is ignored (unread, so no error). **Its default dropped from the old `timeout=30` to `snmp_timeout=5`** — a slow TFTP export may need `snmp_timeout` raised, so set it explicitly on these lines when upgrading. Also recognizes `oid` (the copy/TFTP-mode trigger OID; default the one used by the observed chassis), `remote_file` (the TFTP filename to fetch, default `browse`), `snmp_version` (default `2c`) and `debug` (records the SNMP sets and the TFTP transfer).
[^9]: `procurve-web-1700` likewise talks HTTP; it has only a manager password, so `user` is ignored. Same `timeout`/`fetch_timeout`/`debug` handling as `tplink-web-sg105e`.
[^10]: `tplink-web-sg105e` talks HTTP, not telnet: `user`/`pass` are the web UI login, `timeout` applies to each HTTP request, and `fetch_timeout` to the config download request only. Also recognizes `debug` (optional, boolean — records every HTTP request and response of the run, password masked and binary bodies summarized by size, to `<repository>/<dev_id>.debug`).
[^11]: `zyxel`'s `enable` is optional: one real login sample went straight to the privileged prompt with no separate "enable" step (account already had full privilege), while another needed "enable" plus its own password — both are handled, so this is read defensively rather than assumed either way. `zyxel` also recognizes `show_cmd` (optional, replaces `show running-config`) and `debug` (optional, boolean — records the raw telnet session to `<repository>/<dev_id>.debug` when set to `on`, same convention as `procurve`/`procurve-ssh`).

### Per-model option tables (detailed) {#per-model-options}

The matrix above is the overview; the tables below are the full per-model reference — the exact options each model accepts and whether each is mandatory or optional. (fetchconfig-web parses these tables to build its device-table editor.) Option meanings are described once in the [common options table](#options) above; model-specific notes follow each table. The model-independent **SNMP inventory options** are not repeated in each table — any model accepts them; they are listed once under [SNMP device inventory](#snmp-inventory).

#### `generic` (template-driven)

The generic module recognizes the options below. Most of the timing and prompt options may also be set **in the template file**, and a device-table option overrides the template value of the same name. The options shared with all models are described in the [common options table](#options) above.

| Option | Description |
|---|---|
| `model` | Mandatory. The template to load: `templates/<model>.tmpl` (e.g. `model=cisco-ios`). The only option with no template-file equivalent. May be set on a `default: generic` line so all generic devices sharing one template need not repeat it; a device line can still override it. |
| `transport` | `ssh` or `telnet`. If omitted, the template's first-listed transport is used. On native Windows only `telnet` works (see [Platform support](#platform-support)). |
| `user` | Login username. Mandatory for SSH; for telnet it is sent at the device's `Username:` prompt if the template's login sequence uses it. |
| `pass` | Login password. Mandatory for SSH; for telnet as above. |
| `enable` | Enable password, if the template enters enable mode. |
| `timeout` | Optional, default 30 seconds. May be set in the template. |
| `fetch_timeout` | Optional. Timeout for reading the show output. May be set in the template. |
| `banner_timeout` | Optional, default 30. Seconds to wait for the first prompt after connecting. May be set in the template. |
| `fetch_delay` | Optional, default 0. Seconds to pause after connecting before interacting. May be set in the template. |
| `max_visits` | Optional, default 8. Global cap on how many times a template state may be re-entered (bounds self-loops). May be set in the template. |
| `strip_ansi` | Optional, `yes`/`no` (default no). Strip VT100/ANSI escape sequences from device output. May be set in the template. |
| `prompt_head` | Optional. Regex matched before the learned hostname when building the prompt pattern. May be set in the template. |
| `prompt_tail` | Optional, default `#`. Regex matched after the learned hostname. May be set in the template. |
| `ssh_extra_opts` | Optional. Extra options passed to the ssh client (e.g. legacy key-exchange/cipher settings for old switches). May be set in the template. |
| `prompt_settle_ms` | Optional, default 0 (off). Milliseconds to wait for the channel to go idle before matching the prompt — for SSH CLIs whose login banner races the prompt. May be set in the template. Added to the generic engine in v9.74; it is the real settle control and is distinct from the no-op `prompt_settle` directive removed in v9.72. |
| `type_delay_ms` | Optional, default 0 (off). Milliseconds between typed characters; each send (and secret) is typed char-by-char — for devices that drop fast/pasted input. May be set in the template. |
| `show_cmd` | Optional. The config command sent by a template's `send show_cmd` step (e.g. `show_cmd=wrterm` → `write term`). May be set in the template. |
| `template_dir` | Optional. Directory to load the template from. An absolute path, or relative to the current working directory. Defaults to the `templates/` directory beside fetchconfig.pl (located regardless of the working directory), so this is only needed to load templates from elsewhere. |

> [!note] Template-only directives
> The following are set only in the template file, not on a device line: `capture_from` (regex marking where the saved config starts), `skip_first` (drop the first N captured lines) and `canon` (rewrite part of each line before the `changes_only` comparison, e.g. to collapse a re-salted hash so only a real change counts). See `README.generic-model` for the full template grammar.

#### `cisco-ios`, `cisco-cat`, `cisco-asa`, `cisco-pix`

The cisco-ios, cisco-cat, cisco-asa and cisco-pix modules (CiscoIOS, CiscoCAT, CiscoASA and CiscoPIX) recognize the following options:

| Option | Description |
|--------|-------------|
| `pass` | A mandatory option, specifies the login password. |
| `user` | Specifies the login username. It can be omitted for devices not requiring a login username. |
| `enable` | Mandatory, specifies the enable password. |
| `timeout` | How long, in seconds, to wait for responses from the device. Defaults to 30 seconds if not set on the device line or the model's "default:" line; the default is applied by fetchconfig itself and logged at debug level ("Using 30s fetch timeout because the timeout was not set for this model"). Before 9.55 an unset timeout fell through to the underlying library's own default (10 s for telnet/ SSH via Net::Telnet, 180 s for the web-UI models), so set it explicitly for anything but a lab test. |
| `fetch_timeout` | Optional. If given, will override the timeout value used to fetch all the configuration lines. It is useful for devices which spend several seconds building the configuration. |
| `repository` | Mandatory, specifies the base directory for saving the configuration files. |
| `keep` | Mandatory, the maximum number of config files to retain for the device. When this limit is reached, the older files are discarded. |
| `changes_only` | Optional. Boolean. If specified as changes_only=1, only new configurations are saved. Otherwise, configurations are saved whenever the script runs; if not defined as changes_only=1, the script might possibly retain multiple identical configuration files. |
| `on_fetch_run` | Optional. Path to an external program to be called whenever the configuration is fetched. The following environmental variables are passed to the program: FETCHCONFIG_DEV_ID = device unique id FETCHCONFIG_DEV_HOST = device hostname (or IP addr) FETCHCONFIG_PREV = pathname to previous config, undefined if none exists FETCHCONFIG_CURR = pathname to current config Example: on_fetch_run=/usr/local/bin/mail_diff_to_admin.sh Please notice that, if changes_only=1, the backup file referenced to FETCHCONFIG_CURR will be erased right after the external program is finished. This option is available for all modules. The value is a PROGRAM plus optional literal arguments, not a shell command line: since 9.68 it is split into words (quoting is honoured, e.g. prog "two words") and the program is executed directly, never through /bin/sh. Shell syntax such as ";", "/", "$(...)" or ">" is passed to the program as ordinary text and has no effect. To run a shell pipeline, put it in a script and name the script here. The program must not live in a system directory (/bin, /sbin, /usr/lib, /etc, ... - see [Directory allowlist](#directory-allowlist)); such a value is rejected. |
| `on_fetch_cat` | Optional. Boolean. If specified as on_fetch_cat=1, the currently fetched configuration is issued to standard output. This option is available for all modules. |
| `timezone` | Optional. If defined as timezone=hide, it will supress timezone information from config filename. |
| `filename_append_suffix` | Optional. If defined, it is appended to the generated backup filename, which then reads <dev_id>.run.YYYYMMDD.HHMMSS<tz><suffix>. This option is available for all modules. Example: filename_append_suffix=.txt |

Options specific to CiscoIOS:

| Option | Description |
|--------|-------------|
| `show_cmd` | Optional. If specified, its value will replace the usual "show run" command. This is necessary for some older devices. It may be useful to send alternative commands to capture the configuration. To keep compatibility with previous versions of fetchconfig, if specified as show_cmd=wrterm, "write term" will be used in place of the usual "show run" command. |

#### `cisco-ios-ssh`, `cisco-asa-ssh`

The cisco-ios-ssh and cisco-asa-ssh modules recognize the following options: (See above cisco-ios/cisco-cat section for descriptions. These are the SSH counterparts of cisco-ios and cisco-asa; the login is done over SSH with user/pass, and the shell is then driven the same way as the telnet models.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. SSH login name. |
| `pass` | Mandatory. SSH login password. |
| `enable` | Optional. The enable password, sent if the account lands on the ">" prompt. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show run" command. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records to <repository>/<dev_id>.debug (mode 0600) first the ssh client's account of the SSH authentication and then the raw device session (since 9.59; before, these two models wrote no debug file). |

#### `cisco-sg300`

The cisco-sg300 module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Optional. The enable password, sent if the account lands on the ">" prompt. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config" command. |

#### `fortigate`

The fortigate module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `parks`

The parks module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

Options specific to Parks:

| Option | Description |
|--------|-------------|
| `banner_timeout` | Optional. If given, will override the timeout value used to wait for the 'login:' prompt. It is useful since the Parks 209R spends many seconds before issuing the initial login prompt for TELNET connections. |

#### `riverstone`

The riverstone module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `terayon-os`

The terayon-os module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `dmswitch`

The dmswitch module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `3com-msr`

The 3com-msr module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `dell`

The dell module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config" command. |

#### `comware-ssh`

The comware-ssh module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions. HP/H3C Comware over SSH; the prompt is bracketed - "<hostname>" in user view, "[hostname]" in system view - and there is no separate "enable" step.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. SSH login name. |
| `pass` | Mandatory. SSH login password. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records to <repository>/<dev_id>.debug (mode 0600) first the ssh client's account of the SSH authentication and then the raw device session (since 9.59; before, this model wrote no debug file). |

#### `mikrotik`

The mikrotik module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `tellabs-msr`

The tellabs-msr module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `junos`

The junos module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `acme`

The acme module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Optional. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `mediant`

The mediant module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `nec-univerge-ix`

The nec-univerge-ix module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `cisco-iosxr`

The cisco-iosxr module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `coriant-8600`

The coriant-8600 module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |

#### `hirschmann`

The hirschmann module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Optional. The Hirschmann "enable" command does not ask for a password on the firmware this module was written against (confirmed from a real login session) - "enable" goes straight from the ">" prompt to the "#" prompt. This option only matters if some other Hirschmann firmware version does prompt for one; it's read defensively, the same way CiscoIOS.pm handles Cisco's own enable password. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config all" command. |

Note: "show running-config all" renders the "users passwd <user> :v1:<hash>:" field differently on every read. The leading 18 hex characters (9 bytes) are derived from the password and are stable; the trailing hex is a random salt regenerated on every read. fetchconfig canonicalises that salt before the changes_only comparison (keeping the password-derived prefix), so salt churn alone no longer forces a save, while a real password change - which alters the prefix - is still detected and saved. The SAVED backup is byte-exact (the real hash is kept); only the comparison uses the canonical form, and the change-report/e-mail masking is unchanged (the whole :v1: hash is shown as :v1:****:). The 18-hex boundary is empirical (firmware L2E-06.0.03) and scoped to ":v1:".

#### `zyxel`

The zyxel module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Optional. The captured login session this module was written against went straight from login to the "#" (privileged) prompt with no separate "enable" step - the account used already had privilege 15. This option only matters for an account/firmware that does land on a ">" prompt needing "enable"; it's read the same way CiscoIOS.pm handles Cisco's own enable password. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config" command. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records the raw telnet session to <repository>/<dev_id>.debug for troubleshooting - same convention as ProCurve.pm. |

#### `planet-ssh`

The planet-ssh module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. Used for the SSH authentication and, on firmware that shows one, for the switch's own "Username:" prompt that follows it. Firmware without that dialog goes straight to the prompt; both are handled. |
| `pass` | Mandatory. Likewise. |
| `enable` | Optional. Only needed if the account lands on the ">" prompt: "enable" is then sent, and this is the password given at its "Password:" prompt. Defaults to the login password, which is what the observed device uses. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `banner_timeout` | Optional. |
| `type_delay` | Optional. Milliseconds between characters typed to the switch, default 100. Every line - credentials and commands - is typed character by character with that pause after each and three times that before the first one: the observed device does not reliably accept a burst of input right after a prompt (login fails intermittently at full speed). Raise it if debug=on shows dropped or garbled characters; 0 disables the pauses. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. The "! System Up Time:" header line of the running-config changes on every run; it is kept in the backup but ignored when comparing, so it alone never counts as a change. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config" command. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records to <repository>/<dev_id>.debug first the ssh client's verbose account of the SSH authentication ("Authenticated to ... using password", or why not) and then the raw switch session (Net::Telnet dump_log). Note the SSH login itself is not a switch dialog: "login as:" is PuTTY's prompt, and the password goes through the SSH protocol, so neither can appear as session bytes; the ssh log lines are the record of it. |

#### `aruba-cx-ssh`

The aruba-cx-ssh module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. Must be an administrator account: AOS-CX has no "enable"; an operator account lands on the ">" prompt and cannot show the running-config, which the module reports as an error. |
| `pass` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `banner_timeout` | Optional. |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config" command. The pager is disabled with "no page" beforehand. |
| `prompt_settle_ms` | Optional. Milliseconds to wait for output to go idle before matching the command prompt (default 150; 0 disables). The prompt token allows spaces and non-ASCII (AOS-CX hostnames can contain both); this settle keeps a banner line that ends in "#" from being mistaken for the prompt. Raise it on a slow/laggy link. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records to <repository>/<dev_id>.debug first the ssh client's verbose account of the SSH authentication and then the raw switch session - same layout as planet-ssh. |

#### `procurve`, `procurve-ssh`

The procurve and procurve-ssh modules recognize the following options: (See above cisco-ios/cisco-cat section for descriptions. procurve is telnet, procurve-ssh is the SSH counterpart; the session handling is otherwise the same. Both accept a hostname containing spaces in the prompt.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. |
| `pass` | Mandatory. |
| `enable` | Optional. The manager/enable password, sent if the account lands on the operator (">") prompt. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records the raw session to <repository>/<dev_id>.debug for troubleshooting; for procurve-ssh (since 9.59) the ssh client's account of the SSH authentication comes first, then the session dump. The file is created with mode 0600 because it contains the passwords as typed. |

#### `nexus-ssh`

The nexus-ssh module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. Must land on the "#" prompt: NX-OS has no "enable"; a ">" prompt is reported as an error. |
| `pass` | Mandatory. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `banner_timeout` | Optional. |
| `prompt_settle_ms` | Optional. Milliseconds to wait for output to go idle before matching the command prompt (default 150; 0 disables). |
| `fetch_timeout` | Optional. |
| `changes_only` | Optional. The "!Time:" header line of the running-config is the moment of the export and changes on every run; it is kept in the backup but ignored when comparing, so it alone never counts as a change. "!Running configuration last done at:" changes only when the configuration changed and does count. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. If specified, its value will replace the usual "show running-config" command. The pager is disabled with "terminal length 0" beforehand. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records to <repository>/<dev_id>.debug (mode 0600) first the ssh client's account of the SSH authentication and then the raw switch session. |

#### `mediant-sbc`

The mediant-sbc module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory. Login name (SSH or telnet). |
| `pass` | Mandatory. Login password. |
| `enable` | Mandatory. The "enable" password: the CLI lands on the unprivileged "hostname> " prompt and the config is read from the privileged "hostname# " prompt. A wrong enable password is reported as such. |
| `transport` | Optional. "ssh" (default), "telnet" or "auto". "auto" tries SSH first and falls back to telnet ONLY if no SSH service answers (connection refused, unreachable, timed out). It never falls back on an authentication, key-exchange or host-key failure: that would retry the password over a second channel (lockouts, alarms) and move a credential from an encrypted to a cleartext channel. A fallback is logged at info level so a downgrade is always visible. On native Windows the SSH path is unavailable, so use "telnet" (see [Platform support](#platform-support)). |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Optional, default 30 seconds (see the cisco-ios/ cisco-cat section). |
| `banner_timeout` | Optional. |
| `prompt_settle_ms` | Optional (SSH). Milliseconds to wait for output to go idle before matching the prompt (default 150). |
| `fetch_timeout` | Optional. The full configuration is long; raise this on slow links. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `show_cmd` | Optional. Replaces "show running-config" (settings that differ from the firmware defaults - the form the device's own CLI-script export produces and a restore via "copy cli-script from ..." is designed for). "show running-config full" lists every parameter including defaults: better for auditing default changes across firmware upgrades, riskier to replay on a newer firmware. For both, add a second device entry with its own dev_id, e.g. mediant-sbc SBC10 sbc10.example.com mediant-sbc SBC10-full sbc10.example.com show_cmd="show running-config full" The CLI pauses with " --MORE--" after each screen. The pager settings are under "configure system" -> "cli-settings": default-window-height is persistent (part of the running configuration) and the per-session override window-height exists only inside that configuration mode. A backup tool must not modify the configuration nor enter configuration mode, so the pager is driven: a space is sent at every marker and the marker and its erase sequence are removed from the saved configuration. |
| `pager_cmd` | Optional. A command to send before the show command to disable paging for the session, for a firmware that offers one. Its rejection ("Invalid command", "%", ...) aborts the fetch. Not needed on the observed Mediant 500Li. |
| `debug` | Optional. Boolean. debug=on records to <repository>/<dev_id>.debug (mode 0600); over SSH the ssh client's debug trace comes first, then the raw session. |

#### `procurve-snmp`

The procurve-snmp module recognizes the following options: (See above cisco-ios/cisco-cat section for descriptions of the common ones.)

| Option | Description |
|--------|-------------|
| `snmp_community` | Mandatory. The SNMP read-WRITE community. There is no user/pass for this model; the write access is what arms the TFTP export. Masked in logs. (Renamed from `community` in 9.80.) |
| `snmp_write_community` | Optional. A separate read-WRITE community, so inventory can read with an RO `snmp_community`; falls back to `snmp_community`. Masked. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `snmp_timeout` | Optional. Seconds, default **5** (was `timeout=30` before 9.80). Applied to both the SNMP session and the TFTP transfer; raise it for a slow TFTP export. |
| `snmp_version` | Optional. Default `2c`. |
| `oid` | Optional. The "copy/TFTP mode" trigger OID, set to 2 to enable the export and 1 to disable it. Default 1.3.6.1.4.1.11.2.14.11.5.1.7.1.5.6.0 (as used by the observed chassis); override only if a model uses a different sub-OID. |
| `remote_file` | Optional. The TFTP filename to fetch, default "browse". See [ProCurve SNMP backups](#procurve-snmp). |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records the SNMP sets and the TFTP transfer to <repository>/<dev_id>.debug. |

#### `tplink-web-sg105e`, `procurve-web-1700`

The tplink-web-sg105e and procurve-web-1700 modules recognize the following options: (See above cisco-ios/cisco-cat section for descriptions.)

| Option | Description |
|--------|-------------|
| `user` | Mandatory for tplink-web-sg105e: the web UI login name. Ignored by procurve-web-1700, whose web UI has only a manager password. |
| `pass` | Mandatory. The web UI password. |
| `repository` | Mandatory. |
| `keep` | Mandatory. |
| `timeout` | Mandatory. Applies to each HTTP request. |
| `fetch_timeout` | Optional. Applies to the config download request only; the web UI itself warns that the backup can take a while. |
| `changes_only` | Optional. |
| `on_fetch_run` | Optional. |
| `on_fetch_cat` | Optional. |
| `timezone` | Optional. |
| `filename_append_suffix` | Optional. |
| `debug` | Optional. Boolean. If specified as debug=on (default off), records every HTTP request and response of the run (password masked, binary bodies summarized by size) to <repository>/<dev_id>.debug for troubleshooting. |


### show_cmd (most CLI models)

If specified, replaces the model's usual show-config command — useful for older devices. The default is the model's native command (e.g. `show run` on `cisco-ios`/`cisco-cat`, `show running-config` on most others, `show running-config all` on `hirschmann`). On `cisco-ios`, `show_cmd=wrterm` is kept as a backward-compatible alias for `write term` in place of `show run`.

### debug

Boolean, available for **all** models (since v9.71). If `debug=on` (default off), records the raw telnet/SSH session (or, for the web UI models, every HTTP request and response; for `procurve-snmp`, the SNMP operations and TFTP transfer) to `<repository>/<dev_id>.debug` (mode 0600, login/enable passwords kept out) for troubleshooting. Overwritten on each run. Enable only while troubleshooting and delete the file afterwards, as it can still contain configuration secrets.

## Troubleshooting {#troubleshooting}

> [!warn] Legacy SSH key exchange
> Some older SSH implementations (e.g. older HP/Aruba ProCurve firmware) only offer legacy key exchange algorithms that modern OpenSSH clients disable by default. fetchconfig.pl itself already re-enables what it needs for its own SSH connections (see the `KexAlgorithms`/`HostKeyAlgorithms`/`Ciphers` `master_opts` in `ProCurveSSH.pm` and `ComwareSSH.pm`), so this only matters if you want to connect to the same device manually with the system's own `ssh` command — the same kind of algorithm may need to be re-enabled in the SSH client's own configuration:
>
> ```/etc/ssh_config
> Host *
>     KexAlgorithms +diffie-hellman-group1-sha1
> ```

## Security notes {#security}

See also the [Directory allowlist](#directory-allowlist), which restricts the directories a device table may reference — important when the table is edited through a less-trusted front end.

> [!warn] Debug files contain credentials
> With `debug=on`, `<repository>/<dev_id>.debug` records the session verbatim — for the telnet/SSH models that includes the login and enable passwords exactly as typed, and for `procurve-snmp` the SNMP read-write community. For the SSH models the file begins with the ssh client's debug trace (the same output as `ssh -v`: key exchange, host key, authentication methods tried); ssh never writes the password itself into that trace. Since v9.54 these files are created with mode `0600` regardless of the process umask. On native Windows these mode bits are a no-op (NTFS uses ACLs); confidentiality relies on the containing folder's ACLs — see [Platform support](#platform-support). Still, enable `debug=on` only while troubleshooting and delete the file afterwards. Backup files, their directories and the `.status` file are created with the process umask — an unprivileged reader such as fetchconfig-web (running as `nobody` for `-l`/`-g`) must be able to read them, so they are deliberately **not** forced owner-only (parallel-fetch worker scratch files, in a private temp dir, are owner-only). Backups contain configuration secrets — and not always hashed: SNMP communities and some routing/VPN keys (BGP, OSPF, RADIUS/TACACS, IPsec pre-shared keys) are cleartext, and Cisco “type 7” passwords are reversible. Restrict the repository directory on a shared host and treat every backup as sensitive.

**SSH host keys are not verified.** The SSH models use `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null`: any host key is accepted and none remembered. This is deliberate — fetchconfig runs unattended, and a switch’s host key changes on every hardware swap, which would otherwise halt backups until someone edited `known_hosts`. The trade-off is that an on-path attacker could impersonate a device and capture the login password. Run fetchconfig on a trusted management network.

**Device IDs are validated.** A `dev_id` may contain letters, digits, underscore, dot and dash (hostnames like `sw01.example.com` are fine) but may not consist only of dots, since `.` or `..` would resolve to the repository itself or its parent.

**SMTP.** `AUTH LOGIN` sends the password base64-encoded, not encrypted — see the `tls` option under [E-mail notifications](#email-notifications). Header fields (From, To, Subject) have line breaks stripped before sending, so a device-table value cannot inject extra mail headers.

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
| `backup_changed` | `initial` for a device's first-ever backup (no previous config to compare, whatever `changes_only` is); then `unchanged` or `changed` for a `changes_only=1` device; `forced` for a `changes_only=0` device (saved regardless of any comparison); `unknown` when the state is failed or skipped. |
| `inventory` / `inventory_*` | Present only when [SNMP device inventory](#snmp-inventory) is enabled for the device: `inventory=disabled\|successful\|failed`, plus — on a successful or failed read — the headline keys `inventory_source`, `inventory_vendor`, `inventory_model`, `inventory_serial`, `inventory_os_version`, `inventory_sysname`, `inventory_syslocation`, `inventory_syscontact`, `inventory_member_count`, `inventory_hw_set` (empty values omitted). |

## Backup file naming {#backup-file-naming} {nav: Backup file naming}

Backups are named `<dev_id>.run.YYYYMMDD.HHMMSS[<tz>][<suffix>]`, i.e. with one-second resolution, where `<suffix>` is the optional `filename_append_suffix` (must start with a “.”; see the [Options reference](#options)). They are stored in a three-level dated tree under the repository: `<repository>/YYYYMM/YYYYMMDD/<dev_id>/`.

`<tz>` is whatever `strftime` produced on the backup host and so differs by platform and changes with daylight saving time: a numeric offset (`+0200`, `-0500`) on Linux and modern Windows; a bare name (`CEST` in summer, `CET` in winter; `NFT`/`DFT` on older AIX) on AIX; `-CEST` on Solaris; a multi-word name such as `W. Europe Standard Time` (or a localized one) on older Windows; or nothing with `timezone=hide`. Since v9.55 every operation that orders backups (“latest” for `changes_only`, `keep=N` expiry, `-g`/`-n`/`-m`, `-l`, `-z`/`-Z`, `-s`/`-S`) orders them by the **parsed** timestamp `YYYYMMDD.HHMMSS` rather than by a plain string sort of the whole name, so neither the tz token nor a suffix can disturb the order.

Two backups of the same device completed within the same second would get the same name. Rather than let the second silently overwrite the first (and then compare the file with itself), the backup is written with `O_EXCL`: the second run fails to create the file and is reported, leaving the first intact. This essentially never happens for a real fetch (login, pager, full configuration and logout take well over a second, and scheduled runs are minutes apart), and device locking (`lock=on`) prevents concurrent same-device runs outright; it only arises in artificial back-to-back test runs.
