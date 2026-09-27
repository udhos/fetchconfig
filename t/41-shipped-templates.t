#!/usr/bin/perl
#
# 41-shipped-templates.t - every template under templates/ must parse and
# validate clean.
#
# This is a release guard, not a behavioural test: it confirms the shipped
# templates are structurally sound (no unbounded self-loop, unknown goto,
# missing/duplicate capture marker, unreachable state, missing transport
# entry, bad transport or directive), so a broken template can never ship.
# It does NOT and can not check that a template actually drives a device
# correctly - that needs the real device (or a replay).
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::GenericTemplateParser');
my $P = 'fetchconfig::model::GenericTemplateParser';

my $dir = 'templates';
unless (-d $dir) {
    plan skip_all => "$dir directory not found";
}

my @tmpl = sort glob("$dir/*.tmpl");
unless (@tmpl) {
    plan skip_all => "no templates found under $dir";
}

for my $path (@tmpl) {
    open(my $fh, '<', $path) or do { fail("open $path: $!"); next; };
    local $/;
    my $text = <$fh>;
    close $fh;
    my $t = $P->parse($text);
    my $errs = $t->{errors} || [];
    ok(scalar(@$errs) == 0, "$path parses and validates clean")
        or diag("$path errors:\n  " . join("\n  ", @$errs));
}

done_testing();
