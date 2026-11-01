#!/usr/bin/perl
# gen-template-docs.pl - generate a state-machine reference doc for each
# generic-model template, and the template index in README.template_engine.md.
#
# For every <name>.tmpl it writes <name>.md beside it: the template settings, a
# Mermaid stateDiagram-v2 (with a plain-text ASCII twin), and a states table. The
# template is parsed with the authoritative fetchconfig parser
# (fetchconfig::model::GenericTemplateParser), so the diagram is exactly 1:1 with
# the file. It also refreshes the "Model state machines" index table in
# README.template_engine.md (between the TEMPLATE-INDEX markers), so the index
# stays in sync. Re-run after editing a template, then tools/gen-mermaid-svg.py
# and "make doc".
#
#   Usage:  perl tools/gen-template-docs.pl [FILE.tmpl | DIR ...]
#     e.g.  perl tools/gen-template-docs.pl templates
#
# Diagram edge labels are short human glosses (trigger + action); the exact
# expect patterns and actions are in the states table under each diagram.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/..";   # repo root, so fetchconfig::model::* loads
use fetchconfig::model::GenericTemplateParser;

my @args = @ARGV ? @ARGV : ('templates');
my @files;
for my $a (@args) {
    if    (-d $a)                     { push @files, sort glob("$a/*.tmpl"); }
    elsif (-f $a && $a =~ /\.tmpl$/)  { push @files, $a; }
    else  { warn "gen-template-docs.pl: skip (not a .tmpl or dir): $a\n"; }
}
die "gen-template-docs.pl: no .tmpl files found\n" unless @files;

my @index;
for my $file (@files) {
    (my $out = $file) =~ s/\.tmpl$/.md/;
    my ($md, $meta) = gen_doc($file);
    open my $fh, '>', $out or die "cannot write $out: $!";
    print $fh $md;
    close $fh;
    print "wrote $out\n";
    (my $link = $out) =~ s/\.md$/.html/;
    push @index, { name => $meta->{name}, transports => $meta->{transports},
                   status => $meta->{status}, link => $link };
}
update_index("$FindBin::RealBin/../README.template_engine.md", \@index);

# ---------------------------------------------------------------------------
sub slurp { my ($p) = @_; open my $f, '<', $p or die "read $p: $!"; local $/; <$f> }

sub gen_doc {
    my ($file) = @_;
    my $text = slurp($file);
    my $t = fetchconfig::model::GenericTemplateParser->parse($text);
    (my $base = $file) =~ s{.*/}{}; $base =~ s/\.tmpl$//;
    my ($desc, $status) = header_bits($text, $base);
    my $status_short = $status =~ /verified/i ? 'verified'
                     : $status =~ /draft/i    ? 'draft'
                     : ($status ne '' ? $status : '-');

    my @o;
    push @o, "# $base template -- state machine";
    push @o, "";
    push @o, "State machine of the `$base` generic-model template (selected with";
    push @o, "`model=$base`), parsed from `$file`.${desc} See";
    push @o, "[README.template_engine.html](../README.template_engine.html) for the engine";
    push @o, "and grammar and [README.generic-model.html](../README.generic-model.html) for";
    push @o, "selecting the model in the device table.";
    push @o, "";
    push @o, "## Template settings";
    push @o, "";
    push @o, @{ settings_bullets($t, $status) };
    push @o, "";
    push @o, "## State machine";
    push @o, "";
    push @o, '```text';
    push @o, @{ ascii_twin($t) };
    push @o, '```';
    push @o, "<!--MERMAID";
    push @o, @{ mermaid($t) };
    push @o, "MERMAID-->";
    push @o, "";
    push @o, "## States";
    push @o, "";
    push @o, @{ states_table($t) };
    my $note = states_note($t);
    if ($note) { push @o, ""; push @o, $note; }
    push @o, "";
    push @o, "## Template source";
    push @o, "";
    push @o, "Full source of `$file`:";
    push @o, "";
    push @o, '```';
    (my $src = $text) =~ s/\s+\z//;   # drop trailing blank lines before the fence
    push @o, $src;
    push @o, '```';
    push @o, "";
    push @o, "_Generated from `$file` by `tools/gen-template-docs.pl`._";
    push @o, "";
    my %meta = ( name => $base, transports => join(', ', @{$t->{transports}}),
                 status => $status_short );
    return (join("\n", @o), \%meta);
}

# ---- refresh the index table in README.template_engine.md ------------------
sub update_index {
    my ($readme, $idx) = @_;
    unless (-f $readme) { warn "gen-template-docs.pl: $readme not found; index not updated\n"; return; }
    my $text = slurp($readme);
    unless ($text =~ /<!-- TEMPLATE-INDEX -->.*?<!-- \/TEMPLATE-INDEX -->/s) {
        warn "gen-template-docs.pl: TEMPLATE-INDEX markers not found in $readme; index not updated\n";
        return;
    }
    my @rows = ("| Model | Transport | Status |", "|-------|-----------|--------|");
    for my $e (sort { $a->{name} cmp $b->{name} } @$idx) {
        push @rows, "| [$e->{name}]($e->{link}) | $e->{transports} | $e->{status} |";
    }
    my $table = join("\n", @rows);
    $text =~ s/(<!-- TEMPLATE-INDEX -->\n).*?(\n<!-- \/TEMPLATE-INDEX -->)/$1$table$2/s;
    open my $fh, '>', $readme or die "cannot write $readme: $!";
    print $fh $text;
    close $fh;
    print "updated index in $readme (" . scalar(@$idx) . " templates)\n";
}

# ---- header description + verification status ------------------------------
sub header_bits {
    my ($text, $base) = @_;
    my $desc = '';
    if ($text =~ /^#\s*\Q$base\E\.tmpl\s*[-,]\s*(.*)$/m) {
        my $d = $1;
        $d =~ s/\s*\(.*$//;        # drop a trailing parenthetical
        $d =~ s/\.\s.*$//;         # keep only the first sentence
        $d =~ s/[.,]\s*$//;        # drop trailing comma/period
        $d =~ s/\s+(and|or|via|through|over)\s*$//i;  # drop a dangling conjunction
        $d =~ s/\s+/ /g; $d =~ s/^\s+|\s+$//g;
        $d = ucfirst($d) if $d ne '';
        $desc = " ${d}." if $d ne '';
    }
    my $status = '';
    if ($text =~ /^#\s*Note:\s*(.*)$/m) { ($status = $1) =~ s/\s+$//; }
    return ($desc, $status);
}

# ---- settings bullets ------------------------------------------------------
sub settings_bullets {
    my ($t, $status) = @_;
    my $d = $t->{directives};
    my @b;
    push @b, "- status: $status" if $status ne '';
    push @b, "- transport: `" . join(' ', @{$t->{transports}}) . "`";
    my $ph = defined $d->{prompt_head} ? "`'$d->{prompt_head}'`" : "(default)";
    my $pt = defined $d->{prompt_tail} ? "`'$d->{prompt_tail}'`" : "(default)";
    push @b, "- prompt: head $ph, tail $pt (the bareword `prompt` = head + learned hostname + tail)";
    if (defined $d->{show_cmd}) {
        push @b, "- show command: `$d->{show_cmd}`";
    } else {
        push @b, "- show command: sent as a literal in the show state (see the table)";
    }
    push @b, "- saved file starts at: `capture_from /$d->{capture_from}/`" if defined $d->{capture_from};
    push @b, "- `skip_first $d->{skip_first}` (drop leading echoed line(s))" if defined $d->{skip_first};
    push @b, "- `strip_ansi $d->{strip_ansi}`" if defined $d->{strip_ansi};
    push @b, "- legacy SSH options: `ssh_extra_opts` set (old kex/cipher)" if defined $d->{ssh_extra_opts};
    my @timing;
    push @timing, "prompt_settle_ms $d->{prompt_settle_ms}" if defined $d->{prompt_settle_ms};
    push @timing, "type_delay_ms $d->{type_delay_ms}"       if defined $d->{type_delay_ms};
    push @b, "- timing: " . join(', ', @timing) if @timing;
    if (@{$t->{ignores}}) {
        push @b, "- volatile lines ignored in the compare: " .
                 join(', ', map { "`/$_->{regex}/`" } @{$t->{ignores}});
    }
    if (@{$t->{interrupts}}) {
        push @b, "- global interrupts (matched at any expect):";
        for my $i (@{$t->{interrupts}}) {
            push @b, "  - `/$i->{regex}/` -> `" . action_text($i->{action}) . "`";
        }
    }
    if (@{$t->{canons}}) {
        push @b, "- compare-only canon (salt/volatile field normalised before the compare):";
        for my $c (@{$t->{canons}}) {
            push @b, "  - `canon /$c->{pattern}/$c->{replacement}/`";
        }
    }
    my @to;
    push @to, "banner $d->{banner_timeout}s" if defined $d->{banner_timeout};
    push @to, "fetch $d->{fetch_timeout}s"   if defined $d->{fetch_timeout};
    push @to, "max_visits $d->{max_visits}"  if defined $d->{max_visits};
    push @b, "- timeouts: " . join(', ', @to) if @to;
    return \@b;
}

# ---- action / pattern rendering -------------------------------------------
sub action_text {   # exact, for the table / interrupt list
    my ($a) = @_;
    return 'nop'           if $a->{op} eq 'nop';
    return 'capture_start' if $a->{op} eq 'capture_start';
    return 'capture_stop'  if $a->{op} eq 'capture_stop';
    return 'send_match'    if $a->{op} eq 'send_match';
    if ($a->{kind} && $a->{kind} eq 'literal') { return qq{$a->{op} "$a->{text}"}; }
    if ($a->{kind} && $a->{kind} eq 'option')  { return "$a->{op} $a->{name}"; }
    return $a->{op};
}

sub action_gloss {  # short, for a diagram/ASCII edge label
    my ($a) = @_;
    return 'nop'           if $a->{op} eq 'nop';
    return 'capture_start' if $a->{op} eq 'capture_start';
    return 'capture_stop'  if $a->{op} eq 'capture_stop';
    return 'send_match'    if $a->{op} eq 'send_match';
    if ($a->{kind} && $a->{kind} eq 'option') {
        my $n = $a->{name};
        return 'send user'           if $n eq 'user';
        return 'send password'       if $n eq 'pass';
        return ($a->{op} eq 'send_secret' ? 'send enable secret' : 'send enable') if $n eq 'enable';
        return 'send show command'   if $n eq 'show_cmd';
    }
    if ($a->{kind} && $a->{kind} eq 'literal') {
        my $txt = $a->{text};
        return 'send key' if $txt =~ /^\s*$/;       # e.g. send_nolf " "
        $txt =~ s/"//g;
        return "send $txt";
    }
    return $a->{op};
}

sub pattern_text { my ($p) = @_; $p->{kind} eq 'prompt' ? 'prompt' : "/$p->{regex}/"; }

sub trigger_gloss {   # short human hint for an expect pattern
    my ($p) = @_;
    return 'at prompt' if $p->{kind} eq 'prompt';
    my $r = lc $p->{regex};
    return 'username'   if $r =~ /user/;
    return 'password'   if $r =~ /pass/;
    return 'login'      if $r =~ /login/;
    return 'menu'       if $r =~ /command line|\(cli\)|\bmenu\b/;
    return 'press key'  if $r =~ /press any key/;
    return 'pager'      if $r =~ /more--|--more/;
    return 'at prompt'  if $r =~ /[>#]\s*\$?$|\)\s*\\?\s*[>#]/;
    return '';
}

sub edge_label { my ($trig, $act) = @_; $trig ne '' ? "$trig, $act" : $act; }

sub mm_label {   # make a string safe as a Mermaid stateDiagram edge label
    my ($s) = @_;
    $s =~ s/["#;{}|]//g;
    $s =~ s/:/ -/g;
    $s =~ s/\s+/ /g; $s =~ s/^\s+|\s+$//g;
    return $s;
}

# target name for a step's transition (for Mermaid: '[*]' for done)
sub target_of {
    my ($step, $state) = @_;
    my $nk = $step->{next_kind} || 'stay';
    return '[*]'            if $nk eq 'done';
    return $step->{next}    if $nk eq 'goto';
    return $state->{name};  # stay / self
}

# ---- Mermaid state diagram -------------------------------------------------
sub mermaid {
    my ($t) = @_;
    my @m = ('stateDiagram-v2');
    for my $tr (@{$t->{transports}}) {
        my $entry = $tr eq 'ssh' ? 'state_login_ssh' : 'state_login_telnet';
        push @m, "    [*] --> $entry: transport $tr" if $t->{state_by}{$entry};
    }
    for my $st (@{$t->{states}}) {
        for my $step (@{$st->{steps}}) {
            next if $step->{op} eq 'capture_start';   # on-entry, not an edge
            next unless $step->{op} eq 'expect' || $step->{op} eq 'send_now';
            my $tgt = target_of($step, $st);
            my $label = $step->{op} eq 'expect'
                      ? edge_label(trigger_gloss($step->{pattern}), action_gloss($step->{action}))
                      : action_gloss($step->{action});
            push @m, "    $st->{name} --> $tgt: " . mm_label($label);
        }
    }
    return \@m;
}

# ---- ASCII twin ------------------------------------------------------------
sub ascii_target {
    my ($step, $state) = @_;
    my $nk = $step->{next_kind} || 'stay';
    return 'done'                       if $nk eq 'done';
    return "$state->{name} (loop)"      if $nk eq 'stay' || (defined $step->{next} && $step->{next} eq $state->{name});
    return $step->{next};
}

sub ascii_twin {
    my ($t) = @_;
    my @a;
    push @a, "  entry:";
    for my $tr (@{$t->{transports}}) {
        my $entry = $tr eq 'ssh' ? 'state_login_ssh' : 'state_login_telnet';
        push @a, sprintf("    transport %-6s -> %s", $tr, $entry) if $t->{state_by}{$entry};
    }
    push @a, "";
    for my $st (@{$t->{states}}) {
        push @a, "  $st->{name}";
        my $cap_start = 0;
        for my $step (@{$st->{steps}}) {
            if ($step->{op} eq 'capture_start') { $cap_start = 1; next; }
            next unless $step->{op} eq 'expect' || $step->{op} eq 'send_now';
            my $left = $step->{op} eq 'expect'
                     ? (trigger_gloss($step->{pattern}) || pattern_text($step->{pattern}))
                     : '(send)';
            my $act = action_gloss($step->{action});
            push @a, sprintf("      %-18s -> %-22s -> %s", $left, $act, ascii_target($step, $st));
        }
        push @a, "      (capture_start on entry)" if $cap_start;
    }
    if (@{$t->{interrupts}}) {
        push @a, "";
        push @a, "  (any expect may also match a global interrupt, handled automatically)";
    }
    return \@a;
}

# ---- states table ----------------------------------------------------------
sub cell { my ($s) = @_; $s =~ s/\|/\\|/g; return $s; }

sub next_cell {
    my ($step, $state) = @_;
    my $nk = $step->{next_kind} || 'stay';
    return '`done`'                        if $nk eq 'done';
    return "`$state->{name}` (loop)"       if $nk eq 'stay' || (defined $step->{next} && $step->{next} eq $state->{name});
    return "`$step->{next}`";
}

sub states_table {
    my ($t) = @_;
    my @r;
    push @r, "| State | Waits for (expect) | Action | Next |";
    push @r, "|-------|--------------------|--------|------|";
    for my $st (@{$t->{states}}) {
        my $cap_start = grep { $_->{op} eq 'capture_start' } @{$st->{steps}};
        my $first = 1;
        for my $step (@{$st->{steps}}) {
            next if $step->{op} eq 'capture_start';
            next unless $step->{op} eq 'expect' || $step->{op} eq 'send_now';
            my $name = $first ? "`$st->{name}`" : "";
            my $waits = $step->{op} eq 'expect' ? "`" . cell(pattern_text($step->{pattern})) . "`"
                                                : "(standalone send)";
            my $act_t = cell(action_text($step->{action}));
            my $act = ($cap_start && $step->{action}{op} eq 'capture_stop')
                    ? "`capture_start` on entry, then `capture_stop`"
                    : "`$act_t`";
            push @r, "| $name | $waits | $act | " . next_cell($step, $st) . " |";
            $first = 0;
        }
    }
    return \@r;
}

sub states_note {
    my ($t) = @_;
    my (@n, $multi, $loop);
    for my $st (@{$t->{states}}) {
        my $ex = grep { $_->{op} eq 'expect' } @{$st->{steps}};
        $multi = 1 if $ex > 1;
        for my $step (@{$st->{steps}}) {
            $loop = 1 if ($step->{next_kind} || '') eq 'stay'
                      || (defined $step->{next} && $step->{next} eq $st->{name});
        }
    }
    push @n, "States with more than one expect try them in order; the first match wins." if $multi;
    push @n, "A self-loop (a state that targets itself) is bounded by `max_visits`." if $loop;
    push @n, "Global interrupt patterns can match at any expect (they are not shown as edges); each sends a keystroke and re-enters the state." if @{$t->{interrupts}};
    return @n ? join(' ', @n) : '';
}
