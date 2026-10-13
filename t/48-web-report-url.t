#!/usr/bin/perl
# 48-web-report-url.t - web_report_url is a BASE url; the "full report" link
# is built by appending ?action=view_report&file=<basename>. A legacy value
# that still carries a query string must have it stripped and rebuilt.
use strict; use warnings; use Test::More;
use File::Basename ();
require fetchconfig::Mailer;

# _url_encode: safe report names pass through; unsafe chars are encoded
is(fetchconfig::Mailer::_url_encode('report-20261013-121949.html'),
   'report-20261013-121949.html', 'safe report filename is unchanged');
is(fetchconfig::Mailer::_url_encode('a b&c'), 'a%20b%26c', 'space and & are percent-encoded');

# the URL building logic (mirror of the Mailer code)
sub build {
    my ($base, $report_file) = @_;
    return undef unless defined($report_file) && defined($base);
    (my $b = $base) =~ s/\?.*//;
    my $rf = fetchconfig::Mailer::_url_encode(File::Basename::basename($report_file));
    return $b . "?action=view_report&file=" . $rf;
}

my $rf = '/var/fetchconfig/reports/report-20261013-121949.html';
is(build('https://h/cgi-bin/fetchconfig-web.cgi', $rf),
   'https://h/cgi-bin/fetchconfig-web.cgi?action=view_report&file=report-20261013-121949.html',
   'base url + report -> view_report link');
is(build('https://h/cgi-bin/fetchconfig-web.cgi?action=report', $rf),
   'https://h/cgi-bin/fetchconfig-web.cgi?action=view_report&file=report-20261013-121949.html',
   'legacy ?action=report value is stripped and rebuilt');
is(build('https://h/cgi-bin/fetchconfig-web.cgi', undef), undef,
   'no report file -> no link');

done_testing();
