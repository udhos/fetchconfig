#!/usr/bin/perl
# 51-telnet-debug.t - the shared open_telnet_debug_file (9.71) attaches a
# 0600 .debug session log to a telnet model when debug=on, and passwords
# sent via print_secret() do not reach it. Every telnet model now calls it.
use strict; use warnings; use Test::More;
use File::Temp qw(tempdir);

my $loadable = eval { require fetchconfig::Logger; require fetchconfig::model::CiscoIOS; 1 };
plan skip_all => 'model not loadable here' unless $loadable;

my $log = fetchconfig::Logger->new({ prefix => 't' });
{ no warnings 'redefine','once'; *fetchconfig::Logger::debug=sub{}; *fetchconfig::Logger::info=sub{}; *fetchconfig::Logger::error=sub{}; }
my $m = fetchconfig::model::CiscoIOS->new($log);

# a minimal fake Net::Telnet: dump_log + print
{ package FakeTelnet;
  sub new { bless { log => undef }, shift }
  sub dump_log  { my $s=shift; $s->{log}=$_[0] if @_; defined $s->{log} ? $s->{log} : '' }
  sub input_log { '' }
  sub print     { my ($s,$t)=@_; print {$s->{log}} $t if $s->{log}; 1 }
}

my $repo = tempdir(CLEANUP => 1);
my $t = FakeTelnet->new;

# debug off -> no file, no log attached
is($m->open_telnet_debug_file($t, { debug => 'off' }, $repo, 'd0', 'h'), undef, 'debug=off -> no debug file');
ok(! -e "$repo/d0.debug", 'no .debug written when debug is off');

# debug on -> file created 0600, dump_log attached
my $fh = $m->open_telnet_debug_file($t, { debug => 'on' }, $repo, 'd1', 'h');
ok(defined $fh, 'debug=on -> debug fh returned');
ok(-e "$repo/d1.debug", '.debug file created');
is((stat("$repo/d1.debug"))[2] & 0777, 0600, '.debug is 0600');

# normal output is logged; a password via print_secret is NOT
$t->print("show running-config\n");
$m->print_secret($t, 'SuperSecretPW123');
$t->print("end\n");
close($fh);

my $c = do { open my $r, '<', "$repo/d1.debug"; local $/; <$r> };
like($c,   qr/show running-config/,           'normal commands are captured');
unlike($c, qr/SuperSecretPW123/,              'password is NOT in the debug log');
like($c,   qr/secret sent - not logged/,      'password send leaves a masked marker');

done_testing();
