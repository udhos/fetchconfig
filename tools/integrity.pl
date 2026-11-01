#!/usr/bin/perl
# integrity.pl - write templates/integrity.sha1: a SHA-1 manifest of the stock
# templates, so fetchconfig-web can tell a shipped, unchanged template from one a
# user edited or added. Informational only - it neither protects nor alters
# templates. Uses core Digest::SHA (works on AIX, where sha1sum is absent). Line
# endings are normalised to LF before hashing; the verifier must do the same.
#
#   Usage:  perl tools/integrity.pl [TEMPLATE_DIR]   (default: templates)

use strict;
use warnings;
use Digest::SHA qw(sha1_hex);

my $dir = $ARGV[0] || 'templates';
my $out = "$dir/integrity.sha1";

opendir(my $dh, $dir) or die "integrity.pl: cannot read $dir: $!\n";
my @tmpl = sort grep { /\.tmpl$/ } readdir $dh;
closedir $dh;
die "integrity.pl: no .tmpl files in $dir\n" unless @tmpl;

open(my $ofh, '>', $out) or die "integrity.pl: cannot write $out: $!\n";
binmode $ofh;                        # LF output, no platform translation
for my $name (@tmpl) {
    open(my $fh, '<', "$dir/$name") or die "integrity.pl: cannot read $dir/$name: $!\n";
    binmode $fh; local $/; my $data = <$fh>; close $fh;
    $data =~ s/\r\n/\n/g; $data =~ s/\r/\n/g;         # canonical: LF
    printf $ofh "%s  %s\n", sha1_hex($data), $name;   # sha1sum-style, two spaces
}
close $ofh;
print "wrote $out (" . scalar(@tmpl) . " templates)\n";
