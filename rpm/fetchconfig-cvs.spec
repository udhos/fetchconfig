Summary: fetchconfig device configuration retrieval software
Name: fetchconfig
Version: 0.15
Release: 1.rhfc5
Group: Applications/System
Url: http://savannah.nongnu.org/projects/fetchconfig
#Url: http://www.nongnu.org/fetchconfig
Source0: http://download.savannah.nongnu.org/releases/fetchconfig/fetchconfig-%{version}.tar.gz
BuildArch: noarch
BuildRoot: /var/tmp/%{name}-root
License: GPL

%description
fetchconfig is a Perl script for retrieving the configuration of
multiple devices. It has been tested under Linux and Windows, and
currently supports a variety of devices.

With some simple Perl programming, it is easily adaptable to any
network devices which provides functionality similar to Cisco's
"show running-config" command.

This package was developed for and tested on Fedora Core 5.

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

%doc CHANGES COPYING CREDITS README

%changelog
* Wed Jan 10 2007 Doug Schaapveld <djschaap@gmail.com>
- Initial release of fetchconfig SPEC file

