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
# HP ProCurve 1700 series (1700-8, 1700-24) are web-managed only: no
# telnet, no SSH, so unlike ProCurve.pm/ProCurveSSH.pm this model talks
# HTTP to the device's web UI. The common part (user agent, debug
# trace, response checks, uuencoded storage) lives in AbstractHTTP.pm;
# this file holds the three requests specific to the device, all
# taken from a real packet capture of a browser session against a
# 1700-8 (HTTP/1.0 server, "Connection: close" on every reply):
#
#   - login is "POST /login.html" with a single form field, "password"
#     - the 1700 has just the manager password, no user name. There is
#     no cookie: the capture shows the switch never sets one (the
#     Cookie headers in the browser's requests were the browser's own
#     analytics cookies for the site's domain, nothing from the
#     switch), so the session is bound to the client IP. On success
#     the reply is the frameset page ("menu.html"/"blank.html"); the
#     login page itself carries 'var showFailedLogin = "false"' in its
#     JavaScript and is what the switch serves again, with "true", on
#     a wrong password. Both are checked: the frameset for success,
#     the flag for a readable failure reason.
#   - the download is the "Configuration File" tool on
#     system_confxfr.html: "POST /system/cfgdownload.htm" with the
#     form's one field, "_submit=Apply". The reply is the binary
#     config as an attachment, "Content-Disposition: attachment;
#     filename=switch.cfg", application/octet-stream. (The tools page
#     system_config.html has a different form - factory/warm/tool_sel -
#     that only selects the tool; it is not the download.)
#   - logout: "GET /logout.html" is merely a page whose onload POSTs
#     "tmp=0" to /logout.html after a confirm dialog; the POST is what
#     ends the session and is what this module sends.
#
# The config is a proprietary binary (848 bytes on the sample device):
# "CONF" magic, then TLV blocks introduced by 0xBABE. Hostname,
# location and SNMP communities are in clear, and so, it seems, is the
# manager password - treat the repository accordingly. See
# AbstractHTTP.pm for how it is stored.
#
# $Id: ProCurveWeb1700.pm,v 1.1 2026/09/08 16:00:00 tammer Exp $

package fetchconfig::model::ProCurveWeb1700; # fetchconfig/model/ProCurveWeb1700.pm

use strict;
use warnings;
use HTTP::Request::Common qw(GET POST);
use fetchconfig::model::AbstractHTTP;

@fetchconfig::model::ProCurveWeb1700::ISA = qw(fetchconfig::model::AbstractHTTP);

########################################
# Implement model::AbstractHTTP - Begin
#

sub label {
    'procurve-web-1700';
}

sub http_login {
    my ($self, $ua, $base, $dev_opt_tab) = @_;

    # "user" is accepted for uniformity with the other models but has
    # no meaning on this device, which has only a manager password.
    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
    if (!defined($dev_pass)) {
	$self->log_error("login password needed but not provided");
	return undef;
    }

    my $req = POST("$base/login.html",
		   [ password => $dev_pass ],
		   Referer => "$base/login.html");

    my $res = $self->http_request($ua, $req, "login") or return undef;

    my $body = $self->response_body($res);

    if ($body =~ /showFailedLogin\s*=\s*"true"/) {
	$self->log_error("login refused: wrong password");
	return undef;
    }

    # The switch answers a good login with the frameset that loads
    # menu.html; anything else (the login page again, an error page)
    # is not a session.
    if ($body !~ /<frame[^>]*\bsrc\s*=\s*"?menu\.html/i) {
	$self->log_error("login did not return the main frameset (not logged in)");
	return undef;
    }

    $self->log_debug("logged in");

    1;
}

sub http_backup {
    my ($self, $ua, $base, $dev_id, $dev_opt_tab) = @_;

    my $req = POST("$base/system/cfgdownload.htm",
		   [ _submit => 'Apply' ],
		   Referer => "$base/system/system_confxfr.html");

    my $res = $self->http_request($ua, $req, "config download",
				  $self->dev_option($dev_opt_tab, "fetch_timeout"));

    return unless defined($res);

    # switch.cfg is what the device itself names the attachment.
    $self->accept_binary_response($res, "$dev_id.cfg");
}

sub http_logout {
    my ($self, $ua, $base) = @_;

    my $req = POST("$base/logout.html",
		   [ tmp => '0' ],
		   Referer => "$base/logout.html");

    # A failed logout must not turn an otherwise good backup into a
    # failure; it is logged and that is all.
    if ($self->http_request($ua, $req, "logout")) {
	$self->log_debug("logged out");
    }
}

#
# Implement model::AbstractHTTP - End
######################################

1;
