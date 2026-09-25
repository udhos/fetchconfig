#!/usr/bin/perl
#
# 40-template-parser.t - GenericTemplateParser: parse + validate.
#
# The template parser/validator is pure (text in, structure + errors out),
# so it is fully testable with no device. This locks the grammar and the
# structural checks that keep a template from hanging a real fetch.
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::GenericTemplateParser');
my $P = 'fetchconfig::model::GenericTemplateParser';

# --- the shipped cisco-ios template parses clean ----------------------
{
    my $path = 'templates/cisco-ios.tmpl';
  SKIP: {
        skip("$path not found", 4) unless -f $path;
        open(my $fh, '<', $path); local $/; my $txt = <$fh>; close $fh;
        my $t = $P->parse($txt);
        is(scalar(@{$t->{errors}}), 0, 'cisco-ios.tmpl: no errors') or diag(join "\n", @{$t->{errors}});
        is($t->{directives}{prompt_tail}, '#', 'prompt_tail parsed (# not eaten as comment)');
        is_deeply([sort @{$t->{transports}}], ['ssh','telnet'], 'transports parsed');
        ok(scalar(@{$t->{ignores}}) >= 1, 'ignore lines parsed');
    }
}

# --- comment stripping respects regex and quotes ----------------------
{
    my $t = $P->parse(qq{prompt_tail '#'\nstate a\n  expect /a[>#] \$/ -> nop -> done\ncapture_start\ncapture_stop\n});
    is($t->{directives}{prompt_tail}, '#', '# inside single-quotes kept');
    my $re = $t->{states}[0]{steps}[0]{pattern}{regex};
    like($re, qr/\[>#\]/, '# inside a /regex/ kept');
}

# --- action forms -----------------------------------------------------
{
    my $t = $P->parse(qq{max_visits 5\nstate_login_ssh\n  expect /U/ -> send user -> goto b\n  expect /P/ -> send_secret pass -> goto b\n  expect /X/ -> send_nolf " " -> goto b\ncapture_start\nstate b\n  expect prompt -> capture_stop -> done\n});
    is(scalar(@{$t->{errors}}), 0, 'valid multi-action template: no errors') or diag(join "\n",@{$t->{errors}});
    my $s = $t->{states}[0]{steps};
    is($s->[0]{action}{op}, 'send',        'send action');
    is($s->[0]{action}{name}, 'user',      'send option name');
    is($s->[1]{action}{op}, 'send_secret', 'send_secret action');
    is($s->[2]{action}{op}, 'send_nolf',   'send_nolf action');
    is($s->[2]{action}{text}, ' ',         'send_nolf literal');
}

# --- validator catches structural faults ------------------------------
sub errs { my $t = $P->parse($_[0]); return @{$t->{errors}}; }

ok( (grep /max_visits/, errs("state_login_ssh\n  expect /x/ -> nop -> goto state_login_ssh\ncapture_start\nstate b\n  expect prompt -> capture_stop -> done\n")),
    'unbounded self-loop caught');
ok( (grep /unknown state/, errs("max_visits 5\nstate_login_ssh\n  expect /x/ -> nop -> goto nowhere\ncapture_start\ncapture_stop\n")),
    'goto unknown state caught');
ok( (grep /capture_start/, errs("state_login_ssh\n  expect prompt -> send \"x\" -> done\n")),
    'missing capture caught');
ok( (grep /unreachable/, errs("max_visits 5\nstate_login_ssh\n  expect prompt -> nop -> done\ncapture_start\ncapture_stop\nstate orphan\n  expect /y/ -> nop -> done\n")),
    'unreachable state caught');
ok( (grep /duplicate state/, errs("state_login_ssh\n  expect prompt -> nop -> done\nstate_login_ssh\n  expect prompt -> nop -> done\n")),
    'duplicate state caught');

# --- bad transport flagged --------------------------------------------
ok( (grep /bad transport/, errs("transport ssh rlogin\nstate_login_ssh\n  expect prompt -> nop -> done\ncapture_start\ncapture_stop\n")),
    'bad transport caught');

# --- per-transport entry states ---------------------------------------
ok( (grep /state_login_ssh or state_login_telnet/, errs("state a\n  expect prompt -> nop -> done\ncapture_start\ncapture_stop\n")),
    'template without any transport entry state caught');
{
    my $t = $P->parse(qq{state_login_ssh\n  expect prompt -> nop -> goto cap\nstate cap\n  capture_start\n  expect prompt -> capture_stop -> done\n});
    is($t->{has_ssh}, 1, 'has_ssh set from state_login_ssh');
    is($t->{has_telnet}, 0, 'has_telnet 0 when only ssh entry present');
    is(scalar(@{$t->{errors}}), 0, 'ssh-only template valid') or diag(join "\n",@{$t->{errors}});
}

# --- standalone send step (send_now) ----------------------------------
{
    my $t = $P->parse(qq{state_login_ssh\n  expect prompt -> nop -> goto cap\nstate cap\n  capture_start\n  expect prompt -> capture_stop -> goto bye\nstate bye\n  send "exit" -> done\n});
    is(scalar(@{$t->{errors}}), 0, 'standalone send step: valid') or diag(join "\n",@{$t->{errors}});
    my $bye = $t->{state_by}{bye};
    is($bye->{steps}[0]{op}, 'send_now', 'send with no expect -> send_now step');
    is($bye->{steps}[0]{next_kind}, 'done', 'send_now -> done');
}

# --- send_match action --------------------------------------------------
{
    my $t = $P->parse(qq{state_login_ssh\n  expect /(\\d+)\\. CLI/ -> send_match -> goto cap\nstate cap\n  capture_start\n  expect prompt -> capture_stop -> goto bye\nstate bye\n  send "exit" -> done\n});
    is(scalar(@{$t->{errors}}), 0, 'send_match: valid template') or diag(join "\n",@{$t->{errors}});
    is($t->{state_by}{state_login_ssh}{steps}[0]{action}{op}, 'send_match', 'send_match action parsed');
}

# --- capture_from directive ---------------------------------------------
{
    my $t = $P->parse(qq{capture_from /^version /\nstate_login_ssh\n  expect prompt -> nop -> goto cap\nstate cap\n  capture_start\n  expect prompt -> capture_stop -> goto bye\nstate bye\n  send "exit" -> done\n});
    is(scalar(@{$t->{errors}}), 0, 'capture_from: valid') or diag(join "\n",@{$t->{errors}});
    is($t->{directives}{capture_from}, '^version ', 'capture_from regex parsed');
}

# --- skip_first directive -----------------------------------------------
{
    my $t = $P->parse(qq{skip_first 3\nstate_login_ssh\n  expect prompt -> nop -> goto cap\nstate cap\n  capture_start\n  expect prompt -> capture_stop -> goto bye\nstate bye\n  send "exit" -> done\n});
    is(scalar(@{$t->{errors}}), 0, 'skip_first: valid') or diag(join "\n",@{$t->{errors}});
    is($t->{directives}{skip_first}, '3', 'skip_first value parsed');
}

done_testing();
