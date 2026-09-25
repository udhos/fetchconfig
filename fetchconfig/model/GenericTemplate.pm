package fetchconfig::model::GenericTemplate;

# fetchconfig - Retrieving configuration for multiple devices
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; see the GNU General Public License v2+.
#
# GenericTemplate - a model whose device interaction is described by a
# template (see GenericTemplateParser and README.generic-model) instead of
# a hand-written Perl model. The device table selects it with:
#
#     generic  <dev_id>  <host>  model=<name>,transport=ssh|telnet,user=...,...
#
# and the template templates/<name>.tmpl supplies the state machine, the
# prompt, the timeouts, the interrupt screens and the ignore lines. Every
# standard option (user, pass, enable, repository, timeout, keep,
# changes_only, on_fetch_run, on_fetch_cat, timezone,
# filename_append_suffix, comment, debug) is handled here via dev_option;
# a device-table option OVERRIDES the template value of the same name.
#
# The transport, prompt handling, escape stripping and SSH connection all
# reuse model::Abstract (ssh_open, wait_for_command_prompt, stripansi,
# regexp_quote_keep_bytes), so this model adds the template engine only.
#
# NOTE: the execution engine below drives a live telnet/SSH session and
# has NOT been verified against a device in this build; the template
# PARSER (GenericTemplateParser) is fully tested. Verify a template with
# a real device (or the replay harness) before relying on it.

use strict;
use warnings;

use fetchconfig::model::Abstract;
use fetchconfig::model::GenericTemplateParser;

require Exporter;
our @ISA = qw(fetchconfig::model::Abstract);

my $LABEL = 'generic';

# defaults for the top-of-template timing directives
my %TIMING_DEFAULT = (
    banner_timeout => 30,
    fetch_timeout  => undef,   # undef -> use base timeout
    fetch_delay    => 0,
    prompt_settle  => undef,   # undef -> Abstract default settle
    max_visits     => 8,
);

sub label { $LABEL }

sub new {
    my ($class, $log) = @_;
    my $self = $class->SUPER::new($log);
    $self->{tmpl_cache} = {};
    bless $self, $class;
}

# --- template loading ------------------------------------------------------

sub template_dir {
    # Where templates/<name>.tmpl is looked for. An explicit template_dir
    # device-table option wins (absolute, or relative to the current working
    # directory). Otherwise the default is the templates/ directory that
    # ships beside fetchconfig.pl, located via FindBin so the generic model
    # works regardless of the working directory the script is run from -
    # the same mechanism fetchconfig.pl uses to find its own modules.
    my ($self, $dev_opt_tab) = @_;
    my $dir = $self->dev_option($dev_opt_tab, 'template_dir');
    return $dir if defined $dir;
    require FindBin;
    return "$FindBin::Bin/templates";
}

sub load_template {
    my ($self, $dev_opt_tab) = @_;
    my $name = $self->dev_option($dev_opt_tab, 'model');
    if (!defined($name) || $name eq '') {
        $self->log_error("generic model requires model=<name> (the template to load)");
        return undef;
    }
    if ($name =~ m{[/\\]} || $name !~ /^[\w.-]+$/) {
        $self->log_error("illegal template name: $name");
        return undef;
    }
    my $path = $self->template_dir($dev_opt_tab) . "/$name.tmpl";
    if (my $c = $self->{tmpl_cache}{$path}) { return $c; }
    if (! -f $path) {
        $self->log_error("template not found: $path");
        return undef;
    }
    open(my $fh, '<', $path) or do { $self->log_error("cannot read $path: $!"); return undef; };
    local $/; my $txt = <$fh>; close $fh;
    my $t = fetchconfig::model::GenericTemplateParser->parse($txt);
    if (@{$t->{errors}}) {
        $self->log_error("template $path has errors:");
        $self->log_error("  $_") for @{$t->{errors}};
        return undef;
    }
    $self->{tmpl_cache}{$path} = $t;
    return $t;
}

# an effective directive value: device-table option overrides template,
# template overrides built-in default.
sub eff {
    my ($self, $dev_opt_tab, $tmpl, $name, $default) = @_;
    my $v = $self->dev_option($dev_opt_tab, $name);        # device table wins
    return $v if defined $v;
    $v = $tmpl->{directives}{$name};                        # then template
    return $v if defined $v;
    return $default;                                        # then default
}

# --- hooks fed from the template ------------------------------------------

# interrupt_screens: template interrupts become [regex, keystroke, note]
# triples for Abstract::wait_for_command_prompt. Stored per-fetch.
sub interrupt_screens {
    my ($self) = @_;
    return @{ $self->{cur_interrupts} || [] };
}

# --- fetch contract --------------------------------------------------------

sub fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;
    my $saved_prefix = $self->{log}->prefix;
    $self->{log}->prefix("$saved_prefix: dev=$dev_id host=$dev_host");
    my @conf = $self->do_fetch($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);
    $self->{log}->prefix($saved_prefix);
    @conf;
}

sub do_fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;
    my $tmpl = $self->load_template($dev_opt_tab);
    return unless defined $tmpl;

    # transport: device-table option, else template's first-listed transport
    my $transport = $self->dev_option($dev_opt_tab, "transport");
    if (!defined $transport) { $transport = $tmpl->{transports}[0]; }
    if (!defined $transport || $transport !~ /^(ssh|telnet)$/) {
        $self->log_error("transport must be ssh or telnet (got " . (defined $transport ? $transport : "undef") . ")");
        return;
    }
    $self->log_debug("trying (generic template), transport $transport");

    # the template must have an entry state for the chosen transport
    if (!$tmpl->{state_by}{"state_login_$transport"}) {
        $self->log_error("template has no state_login_$transport - it does not support transport=$transport");
        return;
    }

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
    if (!defined($dev_repository)) { $self->log_error("undefined repository"); return; }
    if (! -d $dev_repository) { $self->log_error("not a directory repository=$dev_repository"); return; }
    if (! -w $dev_repository) { $self->log_error("cannot write repository=$dev_repository"); return; }

    # interrupts for wait_for_command_prompt (regex, keystroke, note)
    $self->{cur_interrupts} = [ map { [ $_->{regex}, _keystroke($_->{action}), undef ] }
                                @{$tmpl->{interrupts}} ];

    # ignore-lines regex from the template, stashed for config_equal (which
    # Abstract calls without $dev_opt_tab).
    if (@{$tmpl->{ignores}}) {
        my $re = join('|', map { "(?:$_->{regex})" } @{$tmpl->{ignores}});
        $self->{cur_ignore_re} = qr/$re/;
    } else {
        $self->{cur_ignore_re} = undef;
    }

    my $dev_timeout = $self->eff($dev_opt_tab, $tmpl, "timeout", undef);

    require Net::Telnet;
    my ($t, $ssh, $pid, $warn_guard);

    if ($transport eq 'ssh') {
        my $dev_user = $self->dev_option($dev_opt_tab, "user");
        my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
        if (!defined $dev_user) { $self->log_error("ssh: login username needed but not provided"); return; }
        if (!defined $dev_pass) { $self->log_error("ssh: login password needed but not provided"); return; }
        my $debug_fh = $self->open_ssh_debug_file($dev_opt_tab, $dev_repository, $dev_id, $dev_host);
        ($t, $ssh, $pid, $warn_guard) = $self->ssh_open($dev_host, $dev_user, $dev_pass, $dev_timeout, $debug_fh);
        return unless defined $t;
    }
    else {
        my ($host, $port) = ($dev_host, 23);
        ($host, $port) = ($1, $2) if $dev_host =~ /^(.+):(\d+)$/;
        my @telnet_args = (Errmode => 'return',
                           (defined $dev_timeout ? (Timeout => $dev_timeout) : ()),
                           Telnetmode => 1);
        # debug=on: write the verbatim session (dump_log) to a 0600 file,
        # same convention as the telnet models.
        if ($self->dev_option_flag($dev_opt_tab, "debug", 0)) {
            push @telnet_args, (dump_log => "$dev_repository/$dev_id.debug");
        }
        $t = Net::Telnet->new(@telnet_args);
        if ($self->dev_option_flag($dev_opt_tab, "debug", 0)) {
            $self->secure_debug_file("$dev_repository/$dev_id.debug");   # credentials -> 0600
        }
        if (!$t->open(Host => $host, Port => $port)) {
            $self->log_error("could not connect (telnet): " . $t->errmsg);
            return;
        }
    }

    my $fetch_delay = $self->eff($dev_opt_tab, $tmpl, "fetch_delay", $TIMING_DEFAULT{fetch_delay});
    select(undef, undef, undef, $fetch_delay) if $fetch_delay;

    my @config;
    my $ok = $self->run_template($t, $tmpl, $dev_id, $dev_host, $dev_opt_tab, $transport, \@config);

    $t->close;
    waitpid($pid, 0) if defined $pid;
    $self->log_debug("disconnected");

    # If the configuration was captured, save it even when a later step
    # (typically logout) failed: a clean logout is cosmetic, the config is
    # the deliverable. run_template sets {capture_done} once capture_stop
    # has run with content.
    if ($ok || ($self->{capture_done} && @config)) {
        if (!$ok) {
            $self->log_error("continuing despite a post-capture failure (logout); config was captured");
        }
        # Trim leading noise from the capture: the echoed command and any
        # preamble ("Building configuration..."). Two mechanisms, applied in
        # order: skip_first N drops a fixed number of leading lines;
        # capture_from /regex/ drops everything before the first matching
        # line. The number actually dropped is logged, and so is the final
        # saved line count.
        my $orig_n = scalar(@config);
        my $dropped = 0;

        my $sf = $tmpl->{directives}{skip_first};
        if (defined $sf && $sf =~ /^\d+$/ && $sf > 0 && @config) {
            my $n = $sf < @config ? $sf : scalar(@config);
            splice(@config, 0, $n);
            $dropped += $n;
        }


        my $cf = $tmpl->{directives}{capture_from};
        if (defined $cf && @config) {
            my $re = qr/$cf/;
            my $start;
            for my $i (0 .. $#config) { if ($config[$i] =~ $re) { $start = $i; last; } }
            if (defined $start) {
                if ($start > 0) { splice(@config, 0, $start); $dropped += $start; }
            } else {
                $self->log_error("capture_from /$cf/ matched no captured line; saving full capture");
            }
        }

        $self->log_debug("dropped $dropped leading noise line(s) before start of configuration")
            if $dropped;
        $self->log_debug("fetched: " . scalar(@config) . " lines");

        return $self->dump_config($dev_id, $dev_opt_tab, \@config);
    }
    return;
}

# turn a template send action into the keystroke wait_for_command_prompt sends
sub _keystroke {
    my ($action) = @_;
    return ' ' unless $action;
    return $action->{text} if $action->{kind} && $action->{kind} eq 'literal';
    return ' ';
}

# --- the state-machine engine ---------------------------------------------

sub run_template {
    my ($self, $t, $tmpl, $dev_id, $dev_host, $dev_opt_tab, $transport, $conf_ref) = @_;

    my $strip = lc($self->eff($dev_opt_tab, $tmpl, "strip_ansi", "no")) eq 'yes';
    my $prompt_head = $self->eff($dev_opt_tab, $tmpl, "prompt_head", '');
    my $prompt_tail = $self->eff($dev_opt_tab, $tmpl, "prompt_tail", '#');
    my $global_mv   = $self->eff($dev_opt_tab, $tmpl, "max_visits", $TIMING_DEFAULT{max_visits});
    my $banner_to   = $self->eff($dev_opt_tab, $tmpl, "banner_timeout", $TIMING_DEFAULT{banner_timeout});
    my $fetch_to    = $self->eff($dev_opt_tab, $tmpl, "fetch_timeout", undef);

    my $learned_prompt;      # set once we first match a prompt
    my %visits;              # per-state visit counter
    my $capturing = 0;
    $self->{capture_done} = 0;

    my $state = "state_login_$transport";   # per-transport entry state
    my $steps_budget = 1000; # absolute cap against a pathological template

    while (defined $state) {
        if (--$steps_budget < 0) {
            $self->log_error("template exceeded step budget (possible loop) in state=$state");
            return 0;
        }
        my $st = $tmpl->{state_by}{$state};
        my $mv = defined $st->{max_visits} ? $st->{max_visits} : $global_mv;
        if (++$visits{$state} > $mv) {
            $self->log_error("state '$state' exceeded max_visits ($mv) - giving up");
            return 0;
        }

        # A standalone capture_start marker in this state turns capturing ON
        # before the expect runs. capture_stop is handled as the expect's
        # action (after the prematch is captured), NOT here - scanning both
        # up front would cancel out and capture nothing.
        for my $step (@{$st->{steps}}) {
            $capturing = 1 if $step->{op} eq 'capture_start';
        }

        # send_now: a state that SENDS without waiting for a prompt (we are
        # already at it - e.g. right after capture). Execute and transition
        # immediately; no waitfor, so no 30s logout hang.
        my ($send_now) = grep { $_->{op} eq 'send_now' } @{$st->{steps}};
        if ($send_now) {
            if ($send_now->{action}) {
                my $r = $self->_do_action($t, $send_now->{action}, $dev_opt_tab, $dev_id);
                return 0 unless $r;
            }
            my $nk = $send_now->{next_kind};
            if    ($nk eq 'done') { $state = undef; }
            elsif ($nk eq 'goto') { $state = $send_now->{next}; }
            else                  { $state = undef; }
            next;
        }

        my @expects = grep { $_->{op} eq 'expect' } @{$st->{steps}};

        # if there is no expect in this state, it's a pure marker state; the
        # validator guarantees an exit exists, so move on via the first goto
        if (!@expects) {
            $self->log_error("state '$state' has nothing to wait for");
            return 0;
        }

        # Build the match. Each expect contributes a pattern; the prompt
        # pattern uses the learned hostname if known, else a generic form.
        my $matched_step;
        my $prematch;
        my $timeout = $banner_to;   # default; capture uses fetch_to when set
        $timeout = $fetch_to if $capturing && defined $fetch_to;

        ($matched_step, $prematch) = $self->_expect_one(
            $t, \@expects, $tmpl, \$learned_prompt,
            $prompt_head, $prompt_tail, $strip, $timeout, $state);

        return 0 unless defined $matched_step;   # timed out / error already logged

        # capture: accumulate prematch lines while capturing
        if ($capturing && defined $prematch) {
            push @$conf_ref, split /\r?\n/, $strip ? fetchconfig::model::Abstract::stripansi($prematch) : $prematch;
        }

        # perform the step's action
        my $act = $matched_step->{action};
        if ($act) {
            my $r = $self->_do_action($t, $act, $dev_opt_tab, $dev_id, $matched_step->{_capture});
            return 0 unless $r;
            $capturing = 1 if $act->{op} eq 'capture_start';
            $capturing = 0 if $act->{op} eq 'capture_stop';
        $self->{capture_done} = 1 if $act->{op} eq 'capture_stop';
        }

        # transition
        my $nk = $matched_step->{next_kind};
        if    ($nk eq 'done') { $state = undef; }
        elsif ($nk eq 'goto') { $state = $matched_step->{next}; }
        else                  { $state = $state; }   # 'stay' - re-enter (bounded)
    }
    return 1;
}

# wait for any of a state's expects (first-match-wins) plus interrupts
sub _expect_one {
    my ($self, $t, $expects, $tmpl, $lp_ref, $phead, $ptail, $strip, $timeout, $state) = @_;

    # Build an ordered alternation. For the learned prompt we use the
    # byte-safe quoted hostname when known; before it is learned, a prompt
    # expect matches a generic "non-space run + tail".
    my @alts;
    my @map;    # parallel: which expect each alternative belongs to
    my $tail_junk = '(?:\x1b\[[\d;?]*[A-Za-z]|\s)*$';   # trailing VT100 escapes/space
    for my $e (@$expects) {
        my $pat;
        if ($e->{pattern}{kind} eq 'prompt') {
            if (defined $$lp_ref) {
                $pat = $phead . fetchconfig::model::Abstract::regexp_quote_keep_bytes($$lp_ref) . $ptail . $tail_junk;
            } else {
                # learn: capture the hostname-ish token before the tail
                $pat = $phead . '(\S+?)' . $ptail . $tail_junk;
            }
        } else {
            $pat = $e->{pattern}{regex};
        }
        push @alts, "(?:$pat)";
        push @map, $e;
    }
    # global interrupts appended (lowest precedence)
    my @intr = @{$tmpl->{interrupts}};
    for my $i (@intr) { push @alts, "(?:$i->{regex})"; push @map, { __interrupt => $i }; }

    my $save_to = $t->timeout;
    $t->timeout($timeout) if defined $timeout;

    my $combined = join('|', @alts);
    my ($prematch, $match) = $t->waitfor(Match => "/$combined/");
    $t->timeout($save_to) if defined $timeout;

    if (!defined $match) {
        my @names = map { $_->{pattern} ? ($_->{pattern}{kind} eq 'prompt' ? 'prompt' : "/$_->{pattern}{regex}/") : 'interrupt' } @$expects;
        $self->log_error("state '$state': timed out waiting for: @names");
        return (undef, undef);
    }

    $match = fetchconfig::model::Abstract::stripansi($match) if $strip;

    # figure out which alternative matched. Re-test in order (first wins).
    for (my $k = 0; $k < @map; $k++) {
        my $e = $map[$k];
        my $pat;
        if ($e->{__interrupt}) {
            $pat = $e->{__interrupt}{regex};
            if ($match =~ /$pat/) {
                # send the interrupt keystroke, stay in the same state
                my $ks = _keystroke($e->{__interrupt}{action});
                $t->put($ks);
                # signal "handled, re-enter state" by returning a synthetic step
                return ({ action => undef, next_kind => 'stay' }, $prematch);
            }
            next;
        }
        if ($e->{pattern}{kind} eq 'prompt') {
            if (defined $$lp_ref) {
                $pat = $phead . fetchconfig::model::Abstract::regexp_quote_keep_bytes($$lp_ref) . $ptail . $tail_junk;
                return ($e, $prematch) if $match =~ /$pat/;
            } else {
                $pat = $phead . '(\S+?)' . $ptail . $tail_junk;
                if ($match =~ /$pat/) { $$lp_ref = $1; $self->log_debug("learned prompt=[$1]"); return ($e, $prematch); }
            }
        } else {
            if ($match =~ /$e->{pattern}{regex}/) { $e->{_capture} = $1; return ($e, $prematch); }
        }
    }
    # matched the combined but not any individual (shouldn't happen)
    $self->log_error("state '$state': matched but could not classify");
    return (undef, undef);
}

# perform a send / send_secret / send_nolf / nop / capture_* action
sub _do_action {
    my ($self, $t, $act, $dev_opt_tab, $dev_id, $capture) = @_;
    my $op = $act->{op};
    return 1 if $op eq 'nop' || $op eq 'capture_start' || $op eq 'capture_stop';
    if ($op eq 'send_match') {
        # send the captured regex group ($1 from the expect) as a keystroke,
        # no newline - used to pick a menu item by its shown number so a
        # renumbered menu still works.
        if (!defined $capture) { $self->log_error("send_match: nothing captured"); return 0; }
        my $ok = $t->put($capture);
        if (!$ok) { $self->log_error("send_match: could not send"); return 0; }
        return 1;
    }

    my $text;
    if ($act->{kind} && $act->{kind} eq 'literal') {
        $text = $act->{text};
    } elsif ($act->{kind} && $act->{kind} eq 'option') {
        $text = $self->dev_option($dev_opt_tab, $act->{name});
        if (!defined $text) {
            $self->log_error("$op: option '$act->{name}' needed but not provided");
            return 0;
        }
    } else {
        $self->log_error("internal: bad action");
        return 0;
    }

    my $ok;
    if ($op eq 'send')        { $ok = $t->print($text); }        # with newline
    elsif ($op eq 'send_secret') { $ok = $self->print_secret($t, $text); }  # masked in debug log
    elsif ($op eq 'send_nolf')   { $ok = $t->put($text); }       # no newline
    else { $self->log_error("internal: unknown send op $op"); return 0; }

    if (!$ok) { $self->log_error("$op: could not send"); return 0; }
    return 1;
}

# config_equal honouring the template's ignore lines. Abstract calls this
# as config_equal($prev_dir,$prev_file,$curr_dir,$curr_file) - it does NOT
# pass $dev_opt_tab, so the ignore regex is stashed by do_fetch (which has
# the template) into $self->{cur_ignore_re}.
sub config_equal {
    my ($self, $prev_dir, $prev_file, $curr_dir, $curr_file) = @_;
    my $re = $self->{cur_ignore_re};
    if (!defined $re) {
        return $self->SUPER::config_equal($prev_dir, $prev_file, $curr_dir, $curr_file);
    }
    return $self->config_equal_ignoring_lines($prev_dir, $prev_file, $curr_dir, $curr_file, $re);
}

# ssh_extra_opts fed from the template (legacy crypto for old switches)
sub ssh_extra_opts {
    my ($self) = @_;
    return @{ $self->{cur_ssh_extra} || [] };
}

1;
