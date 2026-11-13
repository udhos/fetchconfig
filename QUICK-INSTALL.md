# fetchconfig -- Quick Install

The shortest path to a working backup run. For anything beyond the basics -- platform
notes, every option, e-mail, the dashboard DB, SNMP inventory, exit codes -- see the
full [README](README.md).

## 1. Requirements

- **Perl 5.26 or later** -- at `/usr/bin/perl` on UNIX/Linux, or on the `PATH` on Windows.
- **Always needed:** `Net::Telnet` (drives both telnet and SSH sessions) and `Net::SMTP`
  (core since 5.7.3 -- already present). Everything else is core.
- **Only if you use those devices:** `Net::OpenSSH` (any `*-ssh` model), `LWP::UserAgent`
  + `HTTP::Request::Common` (the two web-UI models), `Net::SNMP` and `Net::TFTP`
  (`procurve-snmp` and SNMP device inventory).

Native Windows runs telnet, web-UI and `procurve-snmp` devices only (no SSH); Cygwin/WSL
behaves like Linux.

## 2. Unpack

```shell
cd /usr/local
tar xzf /path/to/fetchconfig-<version>.tar.gz
ln -s fetchconfig-<version> fetchconfig      # now under /usr/local/fetchconfig
```

(`<version>` is whatever the release you downloaded is named.)

## 3. Install the Perl modules you need

```shell
cpan install Net::Telnet                 # always
cpan install Net::OpenSSH                # SSH devices
cpan install LWP::UserAgent HTTP::Request::Common   # web-UI models
cpan install Net::SNMP Net::TFTP         # procurve-snmp / SNMP inventory
```

Skip the lines for transports you do not use. (SNMPv3 additionally needs `Digest::HMAC`
and `Crypt::DES`/`Crypt::Rijndael`.)

## 4. Write a device table

```shell
cd /usr/local/fetchconfig
cp device_table.example device_table
$EDITOR device_table
```

A minimal table -- shared options on `default:` lines per model, then one line per device:

```
default:   cisco-ios   user=backup,pass=secret,enable=secret
default:   cisco-ios   repository=/var/fetchconfig/save,keep=30,changes_only=1

cisco-ios   core-rtr   10.0.0.1
cisco-ios   edge-rtr   10.0.0.2
```

Device-line format is `<model>  <dev_id>  <host>  [extra,options]`; fields are separated by
whitespace, options within a field by commas. `cp` the example and delete the models you do
not use -- it lists every supported model with its options.

## 5. First run

```shell
./fetchconfig.pl -devices=device_table
```

It contacts each device and saves its config under `repository` in a dated tree
(`<repository>/YYYYMM/YYYYMMDD/<dev_id>/`). With `changes_only=1`, a second run keeps a new
file only when the config actually changed. A relative `-devices=` name is also looked for
beside `fetchconfig.pl`, so cron needs no `cd`.

## 6. Schedule it (cron)

```cron
0 2 * * *   /usr/local/fetchconfig/fetchconfig.pl -devices=/usr/local/fetchconfig/device_table
```

Add `-P 10` to fetch ten devices at once when the run is slow with many devices.

## Add later, when you want it

- **E-mail summary** -- add an `email:` line. See [E-mail notifications](README.md#email-notifications).
- **Web dashboard + change history** -- add a `db:` line (PostgreSQL). See [Backup-history database](README.md#backup-history).
- **SNMP hardware inventory** (vendor/model/serial/OS) -- add `snmp_community=...` (or SNMPv3 `snmp_user=...`). See [SNMP device inventory](README.md#snmp-inventory).
- **Reusable credentials** -- define them once with `pw:` and reference `$Alias` on every line. See [Credential aliases](README.md#credential-aliases).

## If a device fails

Put `debug=on` on that device's line and re-run; a raw session dump is written to a
`.debug` file next to its backups -- usually the prompt or pager string needs a tweak.
`./fetchconfig.pl -h` lists every mode and option.
