Summary: fetchconfig device configuration retrieval software
Name: fetchconfig
Version: 9.72
Release: 1
Group: Applications/System
Url: http://savannah.nongnu.org/projects/fetchconfig
#Url: http://www.nongnu.org/fetchconfig
Source0: http://download.savannah.nongnu.org/releases/fetchconfig/fetchconfig-%{version}.tar.gz
BuildArch: noarch
BuildRoot: /var/tmp/%{name}-root
License: GPL

# Base runtime: Perl plus Net::Telnet (every telnet model, and the pty for
# every SSH model). The other transport modules are loaded only when a model
# that needs them is used, so they are optional and are NOT hard Requires --
# install per the DEPENDENCIES file for the device types in use:
#   SSH models:  perl(Net::OpenSSH), perl(IO::Pty)
#   web models:  perl(LWP::UserAgent), perl(HTTP::Request::Common)
#                (+ perl(LWP::Protocol::https), perl(IO::Socket::SSL),
#                   perl(Net::SSLeay) for HTTPS)
#   procurve-snmp: perl(Net::SNMP), perl(Net::TFTP)
#   SMTP over TLS: perl(IO::Socket::SSL), perl(Net::SSLeay)
Requires: perl
Requires: perl(Net::Telnet)

# Keep the "install only what you use" property: do not let rpmbuild's
# automatic Perl dependency generator turn the optional transport modules
# (used by individual model files) into hard Requires on the base package.
%global __requires_exclude ^perl\\((Net::OpenSSH|IO::Pty|IO::Tty|LWP::|HTTP::|URI|Net::SNMP|Net::TFTP|IO::Socket::SSL|Net::SSLeay|Try::Tiny)

%description
fetchconfig is a Perl script for retrieving the configuration of
multiple devices. It has been tested under Linux, AIX and Windows (on
native Windows: telnet, web-UI and SNMP devices only, no SSH), and
currently supports a variety of devices (see the Device Support section
of the README, and DEPENDENCIES for the per-feature module requirements).

With a template file (the generic model) or some simple Perl programming,
it is easily adaptable to any network device which provides functionality
similar to Cisco's "show running-config" command.

%prep
%setup

%build
echo "Perl scripts do not need compilation."
#%configure
#make

%install
rm -rf $RPM_BUILD_ROOT

mkdir -p $RPM_BUILD_ROOT/usr/lib/fetchconfig/fetchconfig/model
cp fetchconfig.pl $RPM_BUILD_ROOT/usr/lib/fetchconfig
cp fetchconfig/*.pm $RPM_BUILD_ROOT/usr/lib/fetchconfig/fetchconfig
cp fetchconfig/model/*.pm $RPM_BUILD_ROOT/usr/lib/fetchconfig/fetchconfig/model

# Templates for the generic model
mkdir -p $RPM_BUILD_ROOT/usr/lib/fetchconfig/templates
cp templates/*.tmpl $RPM_BUILD_ROOT/usr/lib/fetchconfig/templates

mkdir -p $RPM_BUILD_ROOT/usr/bin
#ln -sf ../lib/fetchconfig/fetchconfig.pl $RPM_BUILD_ROOT/usr/bin/fetchconfig
cp rpm/fetchconfig $RPM_BUILD_ROOT/usr/bin

mkdir -p $RPM_BUILD_ROOT/var/fetchconfig
chmod 700 $RPM_BUILD_ROOT/var/fetchconfig

mkdir -p $RPM_BUILD_ROOT/etc/cron.daily
cp rpm/fetchconfig-daily $RPM_BUILD_ROOT/etc/cron.daily/fetchconfig

mkdir -p $RPM_BUILD_ROOT/etc/sysconfig
cp rpm/fetchconfigtab $RPM_BUILD_ROOT/etc/fetchconfigtab
cp rpm/fetchconfig-sysconfig $RPM_BUILD_ROOT/etc/sysconfig/fetchconfig

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)

%attr(755,root,root) /usr/bin/fetchconfig

/usr/lib/fetchconfig

%dir %attr(700,root,root) /var/fetchconfig

%attr(755,root,root) /etc/cron.daily/fetchconfig

%config(noreplace) %attr(600,root,root) /etc/fetchconfigtab
%config(noreplace) %attr(600,root,root) /etc/sysconfig/fetchconfig

%doc CHANGES COPYING CREDITS README DEPENDENCIES

%changelog
* Mon Oct 19 2026 Rainer Tammer <tammer@tammer.net> 9.72-1
- Model-framework code-review fixes: MikroTik escape_brackets() call (fatal),
  ProCurveSSH empty-config guard, JunOS chat_login() failure return,
  generic-model ssh_extra_opts now passed to ssh, mediant-sbc prompt_settle_ms
  honoured on SSH, Detector community= log masking.
- Removed the unused generic-template prompt_settle directive (parser,
  template generators and shipped templates); prompt_settle_ms is unaffected.
- Removed dead code (%holding, %started, entry_state()).

* Mon Oct 19 2026 Rainer Tammer <tammer@tammer.net> 9.71-1
- Update spec to 9.71: base Requires perl + perl(Net::Telnet) (optional
  transport modules documented in DEPENDENCIES, excluded from auto-Requires),
  ship templates/ for the generic model, add DEPENDENCIES to %%doc.

* Wed Jan 10 2007 Doug Schaapveld <djschaap@gmail.com>
- Initial release of fetchconfig SPEC file
