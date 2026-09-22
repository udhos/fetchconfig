# fetchconfig - Retrieving configuration for multiple devices
# Copyright (c) 2026 Rainer Tammer
#
# fetchconfig is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# fetchconfig is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fetchconfig; see the file COPYING. If not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
# Base class for models that back up a device through its HTTP web UI
# instead of a telnet/SSH shell. Written for TPLinkWebSG105E.pm and
# ProCurveWeb1700.pm, which share everything except the three requests
# that differ per device; this class owns the common part:
#
#   - repository sanity checks and the LWP::UserAgent (with a cookie
#     jar: some firmwares track the session in a cookie, others bind
#     it to the client IP and never set one - the jar handles both);
#   - the debug=on trace of every request/response, written to
#     <repository>/<dev_id>.debug under the same convention as the
#     telnet models' dump_log, password masked in logged form bodies;
#   - one unified request wrapper with HTTP-level error reporting;
#   - acceptance checks for a downloaded config: a web UI answers the
#     download URL with a login page instead of the file when the
#     session is not (or no longer) valid, so a text/html reply, a body
#     that looks like markup, or an empty body is rejected;
#   - uuencode(1)-compatible storage of the binary config so it fits
#     the line-based repository, changes_only comparison, -g and the
#     web front-end unchanged; restore is "uudecode <backup>".
#
# A subclass implements label() and these three hooks, each receiving
# the LWP::UserAgent and the "http://host" base URL:
#
#   http_login($ua, $base, $dev_opt_tab)     -> true on success
#   http_backup($ua, $base, $dev_id, $dev_opt_tab)
#                                            -> ($filename, $binary), or
#                                               an empty list on error
#   http_logout($ua, $base)                  -> (return value ignored)
#
# All three log their own errors. http_logout() is called whenever
# http_login() succeeded, also after a failed download, so a run never
# leaves the device's (often single) session occupied.
#
# $Id: AbstractHTTP.pm,v 1.1 2026/09/08 16:00:00 tammer Exp $

package fetchconfig::model::AbstractHTTP; # fetchconfig/model/AbstractHTTP.pm

use strict;
use warnings;
use LWP::UserAgent;
use fetchconfig::model::Abstract;

@fetchconfig::model::AbstractHTTP::ISA = qw(fetchconfig::model::Abstract);

####################################
# Implement model::Abstract - Begin
#

# "sub label" must be provided by the subclass
# "sub new" fully inherited from fetchconfig::model::Abstract

sub fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    my $saved_prefix = $self->{log}->prefix; # save log prefix
    $self->{log}->prefix("$saved_prefix: dev=$dev_id host=$dev_host");

    my @conf = $self->do_fetch($file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab);

    # restore log prefix
    $self->{log}->prefix($saved_prefix);

    @conf;
}

#
# Implement model::Abstract - End
##################################

#############################
# Hooks for subclasses
#

sub http_login  { die ref($_[0]) . " does not implement http_login" }
sub http_backup { die ref($_[0]) . " does not implement http_backup" }
sub http_logout { die ref($_[0]) . " does not implement http_logout" }

#############################
# Debug trace
#

#
# Debug trace of one request/response pair. The telnet models get
# this for free from Net::Telnet's dump_log; there is no equivalent
# in LWP, so it is written by hand. The password is masked in the
# logged request body for the same reason mask_secrets() masks it in
# device table lines. A binary response body is summarized by its
# size; an HTML one (login page, error page) is written out, since
# that is exactly what one needs to see when the device did not hand
# over a config.
#
sub debug_http {
    my ($self, $req, $res) = @_;

    my $fh = $self->{debug_fh};
    return unless defined($fh);

    (my $req_text = $req->as_string) =~ s/(password=)[^&\r\n]*/$1***/;

    print $fh "----- request -----\n", $req_text;
    print $fh "----- response -----\n", $res->status_line, "\n", $res->headers->as_string;

    my $body = $res->decoded_content(charset => 'none');
    $body = '' unless defined($body);
    if ($res->content_type =~ m{text/} || $body =~ /^\s*</) {
	print $fh "\n", $body, "\n";
    }
    else {
	print $fh "\n<", length($body), " bytes of binary body>\n";
    }

    print $fh "\n";
}

sub open_debug {
    my ($self, $dev_opt_tab, $dev_repository, $dev_id) = @_;

    delete $self->{debug_fh};

    return unless $self->dev_option_flag($dev_opt_tab, "debug", 0);

    # Overwritten on every run, like the telnet models' dump_log.
    my $debug_path = "$dev_repository/$dev_id.debug";
    if (open(my $fh, '>', $debug_path)) {
	$self->secure_debug_file($fh);   # contains credentials -> 0600
	$self->{debug_fh} = $fh;
    }
    else {
	$self->log_error("could not write debug file: $debug_path: $!");
    }
}

sub close_debug {
    my ($self) = @_;

    if (defined($self->{debug_fh})) {
	close($self->{debug_fh});
	delete $self->{debug_fh};
    }
}

#############################
# Requests
#

#
# One request with unified error handling: returns the HTTP::Response
# on a 2xx status, undef (already logged) otherwise. An optional
# $timeout applies to this request only (used for the config download,
# which web UIs warn can take a while).
#
sub http_request {
    my ($self, $ua, $req, $what, $timeout) = @_;

    my $save_timeout;
    if (defined($timeout)) {
	$save_timeout = $ua->timeout;
	$ua->timeout($timeout);
    }

    my $res = $ua->request($req);

    $ua->timeout($save_timeout) if defined($timeout);

    $self->debug_http($req, $res);

    if (!$res->is_success) {
	$self->log_error("$what failed: " . $req->method . " " . $req->uri . ": " . $res->status_line);
	return undef;
    }

    $res;
}

#
# Body of a response, with any Content-Encoding (gzip etc.) undone but
# no charset conversion - the config is binary and must stay as is.
#
sub response_body {
    my ($self, $res) = @_;

    my $body = $res->decoded_content(charset => 'none');
    $body = '' unless defined($body);

    $body;
}

#
# Checks that a response to the config download really carries a
# config file and not a web page, and returns ($filename, $binary), or
# an empty list (already logged). The filename is the device's own,
# from Content-Disposition, restricted to filename-safe characters;
# otherwise $default_name.
#
sub accept_binary_response {
    my ($self, $res, $default_name) = @_;

    my $body = $self->response_body($res);

    # Not logged in (or session evicted meanwhile): web UIs answer the
    # download URL with their login page instead of the file.
    if ($res->content_type =~ m{text/html} || $body =~ /^\s*</) {
	$self->log_error("config download returned a web page instead of a config file (not logged in?)");
	return;
    }

    if (!length($body)) {
	$self->log_error("config download returned an empty body");
	return;
    }

    my $filename = $default_name;
    my $disp = $res->header('Content-Disposition');
    if (defined($disp) && $disp =~ /filename\*?=\s*"?([^";]+)"?/i) {
	(my $name = $1) =~ s/^.*[\\\/]//;
	$name =~ s/\s+$//;
	$filename = $name if $name =~ /^[\w.-]+$/;
    }

    $self->log_debug("fetched: " . length($body) . " bytes as $filename");

    ($filename, $body);
}

#############################
# Storage
#

#
# uuencode(1)-compatible text form of the binary: header line, the
# pack('u') lines (45 input bytes each), the "`" zero-length line
# every uuencode writes before "end", and "end".
#
sub uuencode_lines {
    my ($self, $filename, $binary) = @_;

    my @lines = ("begin 644 $filename");
    push @lines, split(/\n/, pack('u', $binary));
    push @lines, '`', 'end';

    # dump_config() now terminates every line with a newline, including
    # the last, so "end" is written as "end\n" and GNU uudecode accepts
    # the file (both from the repository and via "fetchconfig.pl -g ...
    # | uudecode"). Before 9.53 dump_config only put newlines
    # between lines, so an empty trailing element was pushed here to get
    # the terminating newline; that is no longer needed.

    @lines;
}

#############################
# The fetch itself
#

sub do_fetch {
    my ($self, $file, $line_num, $line, $dev_id, $dev_host, $dev_opt_tab) = @_;

    $self->log_debug("trying");

    my $dev_repository = $self->dev_option($dev_opt_tab, "repository");
    if (!defined($dev_repository)) {
	$self->log_error("undefined repository");
	return;
    }

    if (! -d $dev_repository) {
	$self->log_error("not a directory repository=$dev_repository at file=$file line=$line_num: $line");
	return;
    }

    if (! -w $dev_repository) {
	$self->log_error("unable to write to repository=$dev_repository at file=$file line=$line_num: $line");
	return;
    }

    my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");

    # HTTP only; none of these devices offers HTTPS. $dev_host may
    # carry a port ("host:8080"), LWP takes it as part of the URL.
    my $base = "http://$dev_host";

    # cookie_jar: firmwares that track the session in a cookie need it
    # echoed on every request; on firmwares that bind the session to
    # the client IP the jar simply stays empty. hide_cookie2 keeps
    # HTTP::Cookies from adding its RFC 2965 "Cookie2: $Version=1"
    # header, which no browser sends and which an embedded web server
    # with a minimal header parser has never seen.
    my $ua = LWP::UserAgent->new(timeout    => $dev_timeout,
				 agent      => 'fetchconfig',
				 cookie_jar => { hide_cookie2 => 1 });

    $self->open_debug($dev_opt_tab, $dev_repository, $dev_id);

    my @config;

    if ($self->http_login($ua, $base, $dev_opt_tab)) {
	my ($filename, $binary) = $self->http_backup($ua, $base, $dev_id, $dev_opt_tab);

	if (defined($binary)) {
	    @config = $self->uuencode_lines($filename, $binary);
	}

	$self->http_logout($ua, $base);
    }

    $self->close_debug;

    return unless @config;

    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

1;
