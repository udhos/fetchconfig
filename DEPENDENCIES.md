# fetchconfig -- Dependencies

Two views are given: Perl core-vs-CPAN status per Perl release, and the
distribution package to install on RHEL 9, SLES 15 and Ubuntu 24.04 LTS.

Perl releases used as reference points:

| Perl | Platform |
|------|----------|
| 5.26 | SLES 15 SP7 |
| 5.28 | AIX 7.2 TL5 |
| 5.40 | current |

"core" = ships with that Perl; "CPAN" = install separately. None of the CPAN
modules below has ever been core, and none becomes core in 5.40 -- the
network/web/SNMP transport libraries are CPAN in every release. Everything
fetchconfig needs that is NOT a transport is core in all three releases,
unchanged between 5.26 and 5.40.

fetchconfig loads a model's transport module only when that model is used
(one "use" per model file), so a site installs only what its device types
require. The base install (telnet models) needs exactly one CPAN module,
Net::Telnet.


## Runtime dependencies by feature (Perl core vs CPAN)

### Base (always) -- core except Net::Telnet

| Module | 5.26 | 5.28 | 5.40 | Used for |
|--------|------|------|------|----------|
| `Net::Telnet` | CPAN | CPAN | CPAN | every telnet model, and the pty for every SSH model (31 models) |
| `POSIX` | core | core | core | strftime (timestamps) |
| `Text::ParseWords` | core | core | core | quoted device-table values |
| `File::Path` | core | core | core | make_path (repository dirs) |
| `File::Compare` | core | core | core | default config comparison |
| `File::Basename` | core | core | core | path handling |
| `File::Temp` | core | core | core | parallel-fetch temp files |
| `FindBin` | core | core | core | locate the library tree |
| `IO::Handle` | core | core | core | autoflush |
| `Time::HiRes` | core | core | core | prompt_settle_ms (sub-second) |
| `Getopt::Long` | core | core | core | command-line option parsing |
| `Digest::SHA` | core | core | core | sha256_hex (change detection / lock keys) |

Net::Telnet in turn uses only core modules (Socket, IO::Socket::INET,
Errno, Fcntl).

### E-mail summary (Mailer) -- all core

The reporting code is loaded on every run (it writes the per-device status
file even when no e-mail is configured), so Net::SMTP must be present
regardless of whether `email:` is set. No SMTP connection is made unless an
`email:` line is configured.

| Module | 5.26 | 5.28 | 5.40 | Used for |
|--------|------|------|------|----------|
| `Net::SMTP` | core | core | core | sending the summary mail (libnet) |
| `MIME::Base64` | core | core | core | mail encoding |

STARTTLS/SSL additionally needs `IO::Socket::SSL` + `Net::SSLeay` (CPAN),
only when `email: tls=starttls` or `tls=ssl` is configured.

### SSH models (cisco-ios-ssh, cisco-asa-ssh, comware-ssh, procurve-ssh, planet-ssh, aruba-cx-ssh, nexus-ssh, mediant-sbc)

| Module | 5.26 | 5.28 | 5.40 | Used for |
|--------|------|------|------|----------|
| `Net::OpenSSH` | CPAN | CPAN | CPAN | SSH transport |
| `IO::Pty` | CPAN | CPAN | CPAN | pseudo-terminal (Net::OpenSSH dependency) |

Also the `ssh` client binary at runtime; core File::Spec/POSIX/Fcntl.

### Web-UI models (tplink-web-sg105e, procurve-web-1700)

| Module | 5.26 | 5.28 | 5.40 | Used for |
|--------|------|------|------|----------|
| `LWP::UserAgent` | CPAN | CPAN | CPAN | HTTP client |
| `HTTP::Request::Common` | CPAN | CPAN | CPAN | request construction |

Pulls in (all CPAN): HTTP::Request, HTTP::Response, HTTP::Headers,
HTTP::Message, HTTP::Date, HTTP::Cookies, URI, LWP::Protocol, Try::Tiny
(HTTP::Tiny is core). HTTPS additionally needs `LWP::Protocol::https`,
`IO::Socket::SSL`, `Net::SSLeay` (all CPAN).

### SNMP+TFTP model (procurve-snmp)

| Module | 5.26 | 5.28 | 5.40 | Used for |
|--------|------|------|------|----------|
| `Net::SNMP` | CPAN | CPAN | CPAN | SNMP (arm the TFTP export) |
| `Net::TFTP` | CPAN | CPAN | CPAN | fetch the exported file |

Net::SNMP's own prerequisites: Carp, Errno, Exporter, IO::Socket,
Math::BigInt, Digest::MD5 are core. SNMPv3 is loaded at runtime only:
`Crypt::DES` (DES privacy) and `Digest::HMAC` (HMAC auth) are CPAN; AES
privacy additionally needs `Crypt::Rijndael` (CPAN). SNMP v1/v2c load none
of them. Net::SNMP 6.x uses core `Digest::SHA` for SNMPv3 SHA auth, so the
old `Digest::SHA1` module is not required (and is no longer packaged on
Debian/Ubuntu). `Crypt::DES`/`Crypt::Rijndael` are loaded by name --
CryptX does not provide those namespaces and cannot substitute for them.


## OS packages by feature (RHEL 9 / SLES 15 / Ubuntu 24.04 LTS)

Core modules (everything marked "core" above) are pulled in by the default
meta `perl` package on all three distros -- see the base-package note below.
Only the CPAN modules need their own package:

| Module | RHEL 9 (repo) | SLES 15 (repo) | Ubuntu 24.04 (component) |
|--------|---------------|----------------|-------------------------|
| `Net::Telnet` | perl-Net-Telnet (EPEL) | perl-Net-Telnet (PackageHub) | libnet-telnet-perl (universe) |
| `Net::OpenSSH` | perl-Net-OpenSSH (EPEL) | perl-Net-OpenSSH (PackageHub) | libnet-openssh-perl (universe) |
| `IO::Pty` | perl-IO-Tty (CRB) | perl-IO-Tty (PackageHub) | libio-pty-perl (main) |
| `LWP::UserAgent` | perl-libwww-perl (AppStream) | perl-libwww-perl (Basesystem) | libwww-perl (main) |
| `HTTP::Request::Common` | perl-HTTP-Message (AppStream) | perl-HTTP-Message (Basesystem) | libhttp-message-perl (main) |
| `LWP::Protocol::https` | perl-LWP-Protocol-https (AppStream) | perl-LWP-Protocol-https (Basesystem) | liblwp-protocol-https-perl (main) |
| `IO::Socket::SSL` | perl-IO-Socket-SSL (AppStream) | perl-IO-Socket-SSL (Basesystem) | libio-socket-ssl-perl (main) |
| `Net::SSLeay` | perl-Net-SSLeay (AppStream) | perl-Net-SSLeay (Basesystem) | libnet-ssleay-perl (main) |
| `Net::SNMP` | perl-Net-SNMP (EPEL) | perl-Net-SNMP (PackageHub) | libnet-snmp-perl (universe) |
| `Net::TFTP` | not packaged -- CPAN | perl-Net-TFTP (PackageHub) | libnet-tftp-perl (universe) |
| `Crypt::DES` | perl-Crypt-DES (EPEL) | perl-Crypt-DES (PackageHub) | libcrypt-des-perl (universe) |
| `Crypt::Rijndael` | perl-Crypt-Rijndael (EPEL) | perl-Crypt-Rijndael (PackageHub) | libcrypt-rijndael-perl (universe) |
| `Digest::HMAC` | perl-Digest-HMAC (AppStream) | perl-Digest-HMAC (PackageHub) | libdigest-hmac-perl (main) |

Notes:
- RHEL 9 / Rocky 9 / Alma 9: the CPAN transport modules are split across
  EPEL and CRB (CodeReady Builder). Net::Telnet, Net::OpenSSH, Net::SNMP and
  the SNMPv3 crypto are in EPEL; IO::Pty (perl-IO-Tty) is in CRB, not EPEL.
  Net::TFTP is not packaged for RHEL at all -- install it from CPAN for the
  procurve-snmp model.
- SLES 15: register SUSE Package Hub for the CPAN set. The LWP/TLS stack
  (libwww-perl, HTTP-Message, LWP-Protocol-https, IO-Socket-SSL, Net-SSLeay)
  is in the Basesystem Module and needs no Package Hub.
- Ubuntu 24.04: "universe" is enabled by default. Net::SNMP's SNMPv3 SHA auth
  uses core Digest::SHA; libdigest-sha1-perl does not exist on Ubuntu.

### Base perl package per distro

Installing the default meta `perl` package pulls in every "core" module
above on all three distros:

```
RHEL 9     dnf install perl       (full meta package; perl-interpreter is minimal)
SLES 15    zypper install perl
Ubuntu     apt install perl       (perl-base + perl-modules-5.38)
```

RHEL caveat: if something pulled the minimal `perl-interpreter` instead of
`perl`, the split core subpackages are missing and must be added
explicitly: perl-PathTools, perl-libnet, perl-Getopt-Long, perl-Time-HiRes,
perl-MIME-Base64, perl-Digest-MD5, perl-Digest-SHA, perl-File-Path,
perl-File-Temp, perl-Text-ParseWords.


## AIX 7.2

Two Perls exist on AIX, and the choice decides how modules install:

- System Perl (`perl.rte`): the default `/usr/bin/perl`. On AIX 7.2 TL5 this
  is Perl 5.28 -- the interpreter fetchconfig uses out of the box.
- AIX Toolbox Perl (`dnf install perl`): a separate, newer Perl (5.30+) under
  `/opt/freeware`, managed by dnf.

They do NOT share a module path: the Toolbox `perl-*` RPMs install into the
Toolbox perl's @INC (`/opt/freeware/lib/perl5/...`), which `perl.rte` does
not search. A Toolbox `perl-Net-SSLeay` is therefore invisible to
`/usr/bin/perl`. Pick one interpreter and install all non-core modules for
that one (and make fetchconfig's `#!` line point at it).

All "core" modules above ship with both Perls; only the non-core modules
below need installing (same set as the Linux matrix):

| Module | Type | Feature |
|--------|------|---------|
| `Net::Telnet` | pure-Perl | base (telnet + SSH pty) |
| `Net::OpenSSH` | pure-Perl | SSH models (+ `ssh` binary) |
| `IO::Pty` (`IO::Tty`) | XS | SSH models |
| `LWP::UserAgent` + `HTTP::Request::Common` | pure-Perl | web models |
| `LWP::Protocol::https` | pure-Perl | web models (HTTPS) |
| `IO::Socket::SSL` | pure-Perl | web HTTPS, SMTP TLS |
| `Net::SSLeay` | XS | web HTTPS, SMTP TLS |
| `Net::SNMP` | pure-Perl | procurve-snmp |
| `Net::TFTP` | pure-Perl | procurve-snmp |
| `Digest::HMAC` | pure-Perl | procurve-snmp (SNMPv3 auth) |
| `Crypt::DES` | XS | procurve-snmp (SNMPv3 DES) |
| `Crypt::Rijndael` | XS | procurve-snmp (SNMPv3 AES) |

XS modules must be compiled; pure-Perl modules install without a compiler.
Net::SMTP (libnet) and Digest::SHA are core in both Perls, so the e-mail
summary needs no extra module -- only TLS adds Net::SSLeay + IO::Socket::SSL.

### Option A -- system Perl (/usr/bin/perl, perl.rte 5.28)

The Toolbox `perl-*` RPMs do not apply here; install every non-core module
from CPAN against the system perl. XS modules need a C compiler (IBM XL C,
or gcc from the AIX Toolbox) and, for Net::SSLeay, OpenSSL development
headers (IBM `openssl.base`, or `openssl-devel` from the Toolbox).

```
# one-time: compiler + OpenSSL headers for the XS modules
dnf install gcc make openssl-devel           # Toolbox; or use IBM XL C

# telnet-only (minimum)
cpan install Net::Telnet
# + SSH models                                (IO::Tty provides IO::Pty, XS)
cpan install Net::OpenSSH IO::Tty
# + web-UI models (HTTPS)
cpan install LWP::UserAgent LWP::Protocol::https IO::Socket::SSL Net::SSLeay
# + procurve-snmp (SNMPv3 crypto as needed)
cpan install Net::SNMP Net::TFTP Digest::HMAC Crypt::DES Crypt::Rijndael
# + SMTP over TLS: IO::Socket::SSL + Net::SSLeay (as above)
```

### Option B -- AIX Toolbox Perl (dnf perl, 5.30+)

Run fetchconfig with the Toolbox perl (point the `#!` line at
`/opt/freeware/bin/perl`, or invoke it explicitly). The Toolbox can supply
the TLS XS modules precompiled, so the hardest XS build (Net::SSLeay) needs
no compiler; the transport modules still come from CPAN, built with gcc.

```
dnf install perl gcc make

# TLS stack precompiled from the Toolbox (avoids building Net::SSLeay)
dnf install perl-Net-SSLeay perl-IO-Socket-SSL
#   perl-libwww-perl / perl-LWP-Protocol-https too if your Toolbox has them,
#   otherwise add them via cpan below.

# telnet-only (minimum)
cpan install Net::Telnet
# + SSH models                                (IO::Tty is XS -> needs gcc)
cpan install Net::OpenSSH IO::Tty
# + web-UI models (HTTPS)
cpan install LWP::UserAgent LWP::Protocol::https
# + procurve-snmp (SNMPv3 crypto as needed)
cpan install Net::SNMP Net::TFTP Digest::HMAC Crypt::DES Crypt::Rijndael
```


## Install commands (layered)

Prerequisites (run once):

```
# RHEL 9 / Rocky 9 / Alma 9 -- enable EPEL and CRB
dnf install -y epel-release
dnf config-manager --set-enabled crb        # Rocky/Alma: 'crb enable'

# SLES 15 -- register Package Hub (use 15.7 on SP7)
SUSEConnect -p PackageHub/15.6/x86_64

# Ubuntu 24.04 -- 'universe' is default; enable if missing
add-apt-repository universe && apt update
```

RHEL 9 / Rocky 9 / Alma 9:

```
# (a) telnet-only
dnf install perl perl-Net-Telnet
# (b) + SSH models
dnf install perl-Net-OpenSSH perl-IO-Tty
# (c) + web-UI models (HTTPS)
dnf install perl-libwww-perl perl-HTTP-Message perl-LWP-Protocol-https perl-IO-Socket-SSL perl-Net-SSLeay
# (d) + SNMP model (Net::TFTP from CPAN; SNMPv3 crypto as needed)
dnf install perl-Net-SNMP perl-Crypt-DES perl-Digest-HMAC perl-Crypt-Rijndael
cpan install Net::TFTP
# (e) + SMTP over TLS (Net::SMTP is core; add the TLS stack)
dnf install perl-IO-Socket-SSL perl-Net-SSLeay
```

SLES 15 SP6/SP7:

```
# (a) telnet-only
zypper install perl perl-Net-Telnet
# (b) + SSH models
zypper install perl-Net-OpenSSH perl-IO-Tty
# (c) + web-UI models (HTTPS) -- from the Basesystem Module
zypper install perl-libwww-perl perl-HTTP-Message perl-LWP-Protocol-https perl-IO-Socket-SSL perl-Net-SSLeay
# (d) + SNMP model (SNMPv3 crypto as needed)
zypper install perl-Net-SNMP perl-Net-TFTP perl-Crypt-DES perl-Digest-HMAC perl-Crypt-Rijndael
# (e) + SMTP over TLS
zypper install perl-IO-Socket-SSL perl-Net-SSLeay
```

Ubuntu 24.04:

```
# (a) telnet-only
apt install perl libnet-telnet-perl
# (b) + SSH models
apt install libnet-openssh-perl libio-pty-perl
# (c) + web-UI models (HTTPS)
apt install libwww-perl libhttp-message-perl liblwp-protocol-https-perl libio-socket-ssl-perl libnet-ssleay-perl
# (d) + SNMP model (SNMPv3 crypto as needed)
apt install libnet-snmp-perl libnet-tftp-perl libcrypt-des-perl libdigest-hmac-perl libcrypt-rijndael-perl
# (e) + SMTP over TLS
apt install libio-socket-ssl-perl libnet-ssleay-perl
```

`Crypt::Rijndael` is only needed for SNMPv3 AES privacy; drop it for
DES-only or v1/v2c.


## Development only (not needed to run fetchconfig)

| Tool | 5.26 | 5.28 | 5.40 | Used for |
|------|------|------|------|----------|
| `Test::More` / `prove` | core | core | core | the t/ test suite |
| `ExtUtils::MakeMaker` | -- | -- | -- | NOT used; Makefile.PL writes the Makefile itself (no dependency) |

tools/md2html.py and tools/render-doc.py are Python (2.7/3.x), unrelated to
the Perl runtime.


## Summary: minimum CPAN modules to install

```
telnet-only site     Net::Telnet
+ SSH models         Net::OpenSSH, IO::Pty          (+ ssh binary)
+ web models         LWP::UserAgent stack           (libwww-perl, URI, ...)
+ web models HTTPS   LWP::Protocol::https, IO::Socket::SSL, Net::SSLeay
+ procurve-snmp      Net::SNMP, Net::TFTP           (+ Crypt::DES, Digest::HMAC,
                                                     Crypt::Rijndael for SNMPv3)
+ SMTP over TLS      IO::Socket::SSL, Net::SSLeay
```
