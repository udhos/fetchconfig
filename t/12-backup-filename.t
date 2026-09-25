#!/usr/bin/perl
#
# 12-backup-filename.t - fetchconfig::model::Abstract::parse_backup_filename()
#                        and sort_backups_desc()
#
# Backup file names carry a timestamp and a platform-dependent timezone
# token: numeric offset (Linux, modern Windows), a bare name that changes
# with DST (AIX: CEST/CET), a dashed name (Solaris), or a multi-word name
# (older Windows). Because the token varies, NOTHING may order backups by
# string sort; parse_backup_filename extracts the timestamp and
# sort_backups_desc orders by it. These tests lock both the parse of each
# token form and the ordering property.
#
use strict;
use warnings;
use Test::More;

require_ok('fetchconfig::model::Abstract');

sub parse { fetchconfig::model::Abstract::parse_backup_filename($_[0], $_[1]) }

my $D = 'dev01';
sub name { "$D.run.$_[0]" }   # build a filename from the part after ".run."

# --- timezone token forms ---------------------------------------------
{
    my @r = parse($D, name('20260922.001000+0200'));
    is_deeply(\@r, ['20260922.001000', '+0200', ''], 'numeric offset (+0200)');
}
{
    my @r = parse($D, name('20260922.001000-0500'));
    is_deeply(\@r, ['20260922.001000', '-0500', ''], 'negative numeric offset (-0500)');
}
{
    my @r = parse($D, name('20260922.001000CEST'));
    is_deeply(\@r, ['20260922.001000', 'CEST', ''], 'bare name (AIX CEST)');
}
{
    my @r = parse($D, name('20260922.001000-CEST'));
    is_deeply(\@r, ['20260922.001000', '-CEST', ''], 'dashed name (Solaris -CEST)');
}
{
    my @r = parse($D, name('20260922.001000W. Europe Standard Time'));
    is_deeply(\@r, ['20260922.001000', 'W. Europe Standard Time', ''],
              'multi-word name (Windows)');
}
{
    my @r = parse($D, name('20260922.001000'));
    is_deeply(\@r, ['20260922.001000', '', ''], 'no timezone (timezone=hide)');
}

# --- suffix (filename_append_suffix) ----------------------------------
{
    my @r = parse($D, name('20260922.001000CEST.bak'));
    is_deeply(\@r, ['20260922.001000', 'CEST', '.bak'], 'suffix after a name tz');
}
{
    my @r = parse($D, name('20260922.001000+0200_v2'));
    is_deeply(\@r, ['20260922.001000', '+0200', '_v2'], 'underscore suffix after offset');
}
{
    # A token beginning with "-" followed by letters is read as a tz NAME
    # (the Solaris "-CEST" form), not as a suffix - the parser cannot tell
    # "-plain" from a zone. A real suffix therefore uses "." or "_", or
    # follows a recognised tz. This test pins that behaviour deliberately.
    my @r = parse($D, name('20260922.001000-plain'));
    is_deeply(\@r, ['20260922.001000', '-plain', ''],
              'a leading-dash alpha token parses as a tz name, not a suffix');
}
{
    my @r = parse($D, name('20260922.001000.bak'));
    is_deeply(\@r, ['20260922.001000', '', '.bak'],
              'dotted suffix with no tz');
}

# --- dev_id containing a dot (still a valid dev_id) --------------------
{
    my @r = parse('dev.01', 'dev.01.run.20260922.001000+0200');
    is_deeply(\@r, ['20260922.001000', '+0200', ''], 'dev_id with a dot');
}

# --- malformed / non-matching names return () -------------------------
is_deeply([parse($D, 'notmine.run.20260922.001000+0200')], [],
          'wrong dev_id -> ()');
is_deeply([parse($D, name('2026.bad'))], [],
          'short timestamp -> ()');
is_deeply([parse($D, name('20260922.001000CEST trailing lowercase'))], [],
          'lowercase words after a tz are not swallowed -> ()');
is_deeply([parse($D, "$D.backup.20260922.001000")], [],
          'wrong infix (.backup. not .run.) -> ()');

# --- sort_backups_desc: newest first, by PARSED time not string -------
{
    # Deliberately mix tz forms. String sort would put "+0200" before
    # "CEST"; time sort must put the later timestamp first regardless.
    my @files = (
        name('20260921.235900CEST'),        # older
        name('20260922.000100+0200'),        # newest
        name('20260922.000000-CEST'),        # middle
    );
    my @sorted = fetchconfig::model::Abstract::sort_backups_desc($D, \@files);
    is_deeply(\@sorted,
        [ name('20260922.000100+0200'),
          name('20260922.000000-CEST'),
          name('20260921.235900CEST') ],
        'sorted newest-first by parsed timestamp across mixed tz forms');
}

# --- sort_backups_desc: unparsable names kept and reported ------------
{
    my @files = (
        name('20260922.000100+0200'),
        'garbage-file',
        name('20260921.235900CEST'),
    );
    my @unparsed;
    my @sorted = fetchconfig::model::Abstract::sort_backups_desc($D, \@files, \@unparsed);
    is_deeply(\@unparsed, ['garbage-file'], 'unparsable name reported via the array ref');
    is($sorted[0], name('20260922.000100+0200'), 'newest parsable still first');
    ok((grep { $_ eq 'garbage-file' } @sorted), 'unparsable name still present in the result');
}

done_testing();
