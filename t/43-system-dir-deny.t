#!/usr/bin/perl
#
# 43-system-dir-deny.t - repository=, template_dir= and the on_fetch_run
# program may never be a system directory, AND a directory: allowlist line
# may not declare one either (9.68). Tests the _system_dir_path predicate
# directly so it needs no transport modules.
#
use strict;
use warnings;
use Test::More;

# load just the predicate + its table out of Detector.pm, without pulling
# in the model tree (which needs CPAN transport modules).
my $src = do { local (@ARGV,$/) = ('fetchconfig/model/Detector.pm'); <> };
my ($tbl)  = $src =~ /(my \@SYSTEM_DIRS = qw\(.*?\);)/s     or die "no \@SYSTEM_DIRS";
my ($func) = $src =~ /(sub _system_dir_path \{.*?\n\})/s    or die "no _system_dir_path";
eval "$tbl\n$func\n1" or die $@;

# rejected: the system dirs themselves and anything under them, and "/"
for my $p (qw(/ /bin /sbin /lib /usr/bin /usr/sbin /usr/lib /usr/lib64
              /usr/share /usr/share/x /usr/include /etc /etc/cron.d /boot
              /dev /proc /sys /run /var/run /var/lock)) {
    ok(_system_dir_path($p), "rejected: $p");
}

# accepted: ordinary backup/template/script locations, and look-alikes that
# merely share a prefix with a system dir name
for my $p (qw(/usr/local/fetchconfig/config /home/backup /opt/scripts
              /usr/local/bin /usr/sharexyz /etcetera /var/backups
              /data/fetchconfig)) {
    ok(!_system_dir_path($p), "accepted: $p");
}

# trailing slash and // are normalised before the check
ok(_system_dir_path('/etc/'),      'trailing slash still rejected');
ok(_system_dir_path('/usr//lib'),  'doubled slash still rejected');

done_testing();
