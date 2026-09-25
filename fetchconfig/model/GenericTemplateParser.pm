package fetchconfig::model::GenericTemplateParser;

# fetchconfig - Retrieving configuration for multiple devices
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; see the GNU General Public License v2+.
#
# GenericTemplateParser - parse and validate a generic-model template into
# a structure the generic model (GenericTemplate.pm) executes. Kept apart
# from the transport engine so it can be unit-tested with no device: parse
# text in, structure + validation errors out, no I/O.
#
# Template grammar (see README.generic-model):
#   # comment                          to end of line
#   <directive> <args>                 top-of-file settings
#   state <name> [max_visits N]        begins a state block
#     expect /regex/ -> <action> [-> goto <state> | -> done]
#     capture_start
#     capture_stop
#   interrupt /regex/ -> <action>      global, checked in every state
#   ignore /regex/                     volatile lines for config compare
#
# Actions: send "text" | send user|pass|enable | send_secret user|pass|enable
#          | send_nolf ... | nop | capture_start | capture_stop
# The bareword prompt token "prompt" in an expect means the learned prompt
# (prompt_head + quoted hostname + prompt_tail).

use strict;
use warnings;

my %DIRECTIVE_SCALAR = map { $_ => 1 } qw(
    banner_timeout fetch_timeout fetch_delay prompt_settle max_visits
    strip_ansi prompt_head prompt_tail ssh_extra_opts skip_first
);

sub parse {
    my ($class, $text) = @_;
    my %t = (
        directives => {},
        transports => [],
        interrupts => [],
        ignores    => [],
        states     => [],       # ordered
        state_by   => {},       # name -> state href
        errors     => [],
    );
    my $cur;                    # current state href
    my $lineno = 0;

    for my $raw (split /\n/, $text) {
        $lineno++;
        my $line = _strip_comment($raw);
        $line =~ s/^\s+//; $line =~ s/\s+$//;
        next if $line eq '';

        # state block: "state <name> [max_visits N]" or a reserved
        # per-transport entry header "state_login_ssh" etc.
        if ($line =~ /^(state_(?:login|password)_(?:ssh|telnet))$/
            || $line =~ /^state\s+(\S+)(?:\s+max_visits\s+(\d+))?$/) {
            my ($name, $mv) = ($1, $2);
            if ($t{state_by}{$name}) {
                push @{$t{errors}}, "line $lineno: duplicate state '$name'";
            }
            $cur = { name => $name, max_visits => $mv, steps => [],
                     capture_start => 0, capture_stop => 0, line => $lineno };
            push @{$t{states}}, $cur;
            $t{state_by}{$name} = $cur;
            next;
        }

        # transport (multi-value)
        if ($line =~ /^transport\s+(.+)$/) {
            @{$t{transports}} = grep { /^(ssh|telnet)$/ } split /\s+/, $1;
            my @bad = grep { !/^(ssh|telnet)$/ } split /\s+/, $1;
            push @{$t{errors}}, "line $lineno: bad transport(s): @bad" if @bad;
            next;
        }

        # interrupt (global)
        if ($line =~ m{^interrupt\s+/(.*)/\s*->\s*(.+)$}) {
            my ($re, $act) = ($1, $2);
            my ($action, $aerr) = _parse_action($act);
            push @{$t{errors}}, "line $lineno: $aerr" if $aerr;
            push @{$t{interrupts}}, { regex => $re, action => $action, line => $lineno };
            next;
        }

        # ignore (global)
        if ($line =~ m{^ignore\s+/(.*)/\s*$}) {
            push @{$t{ignores}}, { regex => $1, line => $lineno };
            next;
        }

        # capture_from (global): trim the captured config to start at the
        # first line matching this regex, dropping the echoed command and any
        # preamble (e.g. "Building configuration...") before the real config.
        if ($line =~ m{^capture_from\s+/(.*)/\s*$}) {
            $t{directives}{capture_from} = $1;
            next;
        }

        # scalar directive
        if ($line =~ /^(\w+)\s+(.*)$/ && $DIRECTIVE_SCALAR{$1}) {
            my ($k, $v) = ($1, $2);
            $v =~ s/^'(.*)'$/$1/;          # optional single-quotes
            $v =~ s/^"(.*)"$/$1/;          # or double-quotes
            $t{directives}{$k} = $v;
            next;
        }

        # in-state lines
        if ($cur) {
            if ($line eq 'capture_start') { $cur->{capture_start} = $lineno; push @{$cur->{steps}}, { op => 'capture_start', line => $lineno }; next; }
            if ($line eq 'capture_stop')  { $cur->{capture_stop}  = $lineno; push @{$cur->{steps}}, { op => 'capture_stop',  line => $lineno }; next; }

            # standalone action (no expect): "send ... [-> goto X | -> done]"
            # used when we are already at the prompt (e.g. right after capture)
            # and must send a command without waiting for the prompt again.
            if ($line =~ /^(send|send_secret|send_nolf|nop)\b/) {
                my $rest = $line;
                my ($next, $next_kind);
                if ($rest =~ /^(.*?)\s*->\s*goto\s+(\S+)$/) { ($rest, $next_kind, $next) = ($1, 'goto', $2); }
                elsif ($rest =~ /^(.*?)\s*->\s*done$/)      { ($rest, $next_kind)        = ($1, 'done'); }
                else { $next_kind = 'done'; }   # a bare send with no arrow ends the run
                my ($action, $aerr) = _parse_action($rest);
                push @{$t{errors}}, "line $lineno: $aerr" if $aerr;
                push @{$cur->{steps}}, {
                    op => 'send_now', action => $action,
                    next_kind => $next_kind, next => $next, line => $lineno,
                };
                next;
            }

            # expect /regex/ -> action [-> goto X | -> done]
            if ($line =~ m{^expect\s+(prompt|/(?:.*)/)\s*->\s*(.+)$}) {
                my ($pat_raw, $rest) = ($1, $2);
                my $pattern = ($pat_raw eq 'prompt') ? { kind => 'prompt' }
                            : do { (my $r = $pat_raw) =~ s{^/}{}; $r =~ s{/$}{}; { kind => 'regex', regex => $r } };
                # split trailing "-> goto X" or "-> done"
                my ($next, $next_kind);
                if ($rest =~ /^(.*?)\s*->\s*goto\s+(\S+)$/) { ($rest, $next_kind, $next) = ($1, 'goto', $2); }
                elsif ($rest =~ /^(.*?)\s*->\s*done$/)      { ($rest, $next_kind)        = ($1, 'done'); }
                else { $next_kind = 'stay'; }   # no explicit transition -> re-enter same state
                my ($action, $aerr) = _parse_action($rest);
                push @{$t{errors}}, "line $lineno: $aerr" if $aerr;
                push @{$cur->{steps}}, {
                    op => 'expect', pattern => $pattern, action => $action,
                    next_kind => $next_kind, next => $next, line => $lineno,
                };
                next;
            }
            push @{$t{errors}}, "line $lineno: unrecognised state line: $raw";
            next;
        }

        push @{$t{errors}}, "line $lineno: unrecognised directive: $raw";
    }

    _validate(\%t);
    return \%t;
}

# Strip a trailing "# comment", but not a "#" that sits inside a /regex/
# or a "quoted string". Walks the line tracking those two contexts.
sub _strip_comment {
    my ($s) = @_;
    my $out = '';
    my $in_re = 0; my $in_dq = 0; my $in_sq = 0;
    my @c = split //, $s;
    for (my $i = 0; $i < @c; $i++) {
        my $ch = $c[$i];
        my $prev = $i > 0 ? $c[$i-1] : '';
        if ($in_dq) { $out .= $ch; $in_dq = 0 if $ch eq '"' && $prev ne "\\"; next; }
        if ($in_sq) { $out .= $ch; $in_sq = 0 if $ch eq "'"; next; }
        if ($in_re) { $out .= $ch; $in_re = 0 if $ch eq '/' && $prev ne "\\"; next; }
        if ($ch eq '"')  { $in_dq = 1; $out .= $ch; next; }
        if ($ch eq "'")  { $in_sq = 1; $out .= $ch; next; }
        if ($ch eq '/')  { $in_re = 1; $out .= $ch; next; }
        last if $ch eq '#';         # a real comment starts here
        $out .= $ch;
    }
    return $out;
}

sub _parse_action {
    my ($s) = @_;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    return ({ op => 'nop' }, undef) if $s eq 'nop';
    return ({ op => 'capture_start' }, undef) if $s eq 'capture_start';
    return ({ op => 'capture_stop' }, undef)  if $s eq 'capture_stop';
    return ({ op => 'send_match' }, undef) if $s eq 'send_match';
    if ($s =~ /^(send|send_nolf|send_secret)\s+(.+)$/) {
        my ($verb, $arg) = ($1, $2);
        if ($arg =~ /^"(.*)"$/) { return ({ op => $verb, kind => 'literal', text => $1 }, undef); }
        if ($arg =~ /^(user|pass|enable)$/) { return ({ op => $verb, kind => 'option', name => $1 }, undef); }
        return (undef, "bad send argument: $arg");
    }
    return (undef, "unrecognised action: $s");
}

# validation: structural checks that can be done without a device
# The reserved per-transport entry states. The engine starts at
# state_login_<transport> for the chosen transport; the telnet and ssh
# login paths converge (via goto) on the shared states.
my @ENTRY_STATES = qw(state_login_ssh state_password_ssh
                      state_login_telnet state_password_telnet);
my %IS_ENTRY = map { $_ => 1 } @ENTRY_STATES;

sub entry_state {
    my ($t, $transport) = @_;
    return "state_login_$transport";
}

sub _validate {
    my ($t) = @_;
    my @e;

    push @e, "no states defined" unless @{$t->{states}};

    # at least one transport must have an entry state
    my $has_ssh    = $t->{state_by}{state_login_ssh}    ? 1 : 0;
    my $has_telnet = $t->{state_by}{state_login_telnet} ? 1 : 0;
    if (!$has_ssh && !$has_telnet) {
        push @e, "template must define at least one of "
               . "state_login_ssh or state_login_telnet (the per-transport entry state)";
    }
    $t->{has_ssh}    = $has_ssh;
    $t->{has_telnet} = $has_telnet;

    # capture start/stop present exactly once across the template, whether
    # written as a standalone line or as an expect action.
    my ($cs, $ce) = (0, 0);
    for my $st (@{$t->{states}}) {
        for my $step (@{$st->{steps}}) {
            my $op = $step->{op};
            $cs++, $ce++ if 0;   # (no-op, keeps structure clear)
            if ($op eq 'capture_start') { $cs++; }
            elsif ($op eq 'capture_stop') { $ce++; }
            elsif ($op eq 'expect' && $step->{action}) {
                $cs++ if $step->{action}{op} eq 'capture_start';
                $ce++ if $step->{action}{op} eq 'capture_stop';
            }
        }
    }
    push @e, "template must contain exactly one capture_start (found $cs)" if $cs != 1;
    push @e, "template must contain exactly one capture_stop (found $ce)"  if $ce != 1;

    # every goto targets an existing state; self-loops must be bounded
    my $global_mv = $t->{directives}{max_visits};
    for my $st (@{$t->{states}}) {
        my $self_loop = 0;
        my $has_exit  = 0;
        for my $step (@{$st->{steps}}) {
            next unless $step->{op} eq 'expect' || $step->{op} eq 'send_now';
            my $nk = $step->{next_kind};
            if ($nk eq 'goto') {
                push @e, "line $step->{line}: goto unknown state '$step->{next}'"
                    unless $t->{state_by}{$step->{next}};
                $self_loop = 1 if defined $step->{next} && $step->{next} eq $st->{name};
                $has_exit = 1 if !defined $step->{next} || $step->{next} ne $st->{name};
            }
            elsif ($nk eq 'done') { $has_exit = 1; }
            elsif ($nk eq 'stay') { $self_loop = 1; }
        }
        # a state that can loop to itself needs an effective max_visits cap
        if ($self_loop && !defined($st->{max_visits}) && !defined($global_mv)) {
            push @e, "state '$st->{name}' can loop to itself but has no max_visits "
                   . "(set per-state or a global max_visits) - would risk a hang";
        }
        # a state with no exit at all (only self-transitions) is suspicious
        if (!$has_exit && @{$st->{steps}}) {
            push @e, "state '$st->{name}' has no transition that leaves it";
        }
    }

    # reachability from each transport entry state that exists
    my @entries;
    push @entries, 'state_login_ssh'    if $has_ssh;
    push @entries, 'state_login_telnet' if $has_telnet;
    if (@entries) {
        my %seen; my @q = @entries;
        while (@q) {
            my $n = shift @q; next if $seen{$n}++;
            my $st = $t->{state_by}{$n} or next;
            for my $step (@{$st->{steps}}) {
                next unless ($step->{op} eq 'expect' || $step->{op} eq 'send_now') && $step->{next_kind} eq 'goto';
                push @q, $step->{next} if $step->{next} && !$seen{$step->{next}};
            }
        }
        for my $st (@{$t->{states}}) {
            # entry states for a transport that isn't used may be unreachable
            # from the other transport's entry - that's fine; skip them.
            next if $IS_ENTRY{$st->{name}};
            push @e, "state '$st->{name}' is unreachable from the transport entry state(s)"
                unless $seen{$st->{name}};
        }
    }

    push @{$t->{errors}}, @e;
}

1;
