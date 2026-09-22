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
# TP-Link Easy Smart switches (TL-SG105E, TL-SG105PE and siblings) have
# no CLI at all - no telnet, no SSH - so this model talks HTTP to the
# device's web UI instead of chatting with a shell. The common part
# (user agent with cookie jar, debug trace, response checks, uuencoded
# storage) lives in AbstractHTTP.pm; this file holds the three
# requests specific to the device. Everything below was taken from real
# packet captures of browser sessions against a TL-SG105E and a
# TL-SG105PE v2 plus the HTML source of the "Config Backup" page:
#
#   - login is "POST /logon.cgi" with the four form fields the login
#     page submits (username, password, an empty cpassword, and
#     logon=Login). The device answers 200 with a page whose first
#     lines are "var logonInfo = new Array(<code>, ...)"; the login
#     page's own JavaScript maps <code> 0 to success and 1-6 to the
#     error texts reproduced in %LOGON_ERROR below.
#   - the session is tracked in two different ways depending on the
#     firmware, so the client has to support both:
#       * TL-SG105E (2019 firmware): NO session cookie - that capture
#         contains not a single Set-Cookie/Cookie header. The device
#         binds the session to the client's IP address, which is also
#         why it only allows a limited number of concurrent logins. A
#         second plain request from the same host is already "logged
#         in".
#       * TL-SG105PE v2 (2023 firmware): a session cookie, "H_P_SSID=
#         tplink_<hex>;Max-Age=600", set on the logon.cgi reply and
#         expected back on every later request. Without it the backup
#         URL answers with the login page (seen in a real debug trace
#         of the first version of this module, which had no cookie
#         jar). Hence the cookie jar in AbstractHTTP.pm: it carries the
#         cookie for the PE and is simply never filled for the E.
#   - the backup itself is the "Config Backup" page's form:
#     <form name=backup action=config_back.cgi> with a submit button
#     named btnBackup - no method attribute, so a GET with the button
#     as its only query parameter. The reply is the binary config as
#     an attachment. When NOT logged in the same URL answers with the
#     login page (text/html) instead, so the reply is checked for
#     that before it is accepted as a config.
#   - logout is "GET /Logout.htm" (the menu frame's Logout() does
#     location.href="/Logout.htm"). It is always sent once login
#     succeeded, even after a failed download, so a run never leaves
#     the device's single IP-bound session occupied.
#
# The config is an opaque binary structure (2258 bytes on the sample
# device, low entropy, not compressed - hostname and VLAN names are
# visible in clear). See AbstractHTTP.pm for how it is stored.
#
# $Id: TPLinkWebSG105E.pm,v 1.2 2026/09/08 16:00:00 tammer Exp $

package fetchconfig::model::TPLinkWebSG105E; # fetchconfig/model/TPLinkWebSG105E.pm

use strict;
use warnings;
use HTTP::Request::Common qw(GET POST);
use fetchconfig::model::AbstractHTTP;

@fetchconfig::model::TPLinkWebSG105E::ISA = qw(fetchconfig::model::AbstractHTTP);

#
# logonInfo[0] codes and their meaning, verbatim from the error texts
# the device's own login page shows for each one (t_error1..t_error6
# in the page's JavaScript). 6 is the forced-password-change prompt
# the device shows while the factory default password is still set.
#
my %LOGON_ERROR = (
    1 => 'the user name or the password is wrong',
    2 => 'the user is not allowed to login',
    3 => 'the number of the user that allowed to login has been full',
    4 => 'the number of the login user has been full (16 concurrent logins)',
    5 => 'the session is timeout',
    6 => 'the device demands a password change before it can be used',
);

########################################
# Implement model::AbstractHTTP - Begin
#

sub label {
    'tplink-web-sg105e';
}

sub http_login {
    my ($self, $ua, $base, $dev_opt_tab) = @_;

    my $dev_user = $self->dev_option($dev_opt_tab, "user");
    if (!defined($dev_user)) {
	$self->log_error("login username needed but not provided");
	return undef;
    }

    my $dev_pass = $self->dev_option($dev_opt_tab, "pass");
    if (!defined($dev_pass)) {
	$self->log_error("login password needed but not provided");
	return undef;
    }

    my $req = POST("$base/logon.cgi",
		   [ username  => $dev_user,
		     password  => $dev_pass,
		     cpassword => '',
		     logon     => 'Login' ]);

    my $res = $self->http_request($ua, $req, "login") or return undef;

    if ($self->response_body($res) !~ /logonInfo\s*=\s*new\s+Array\(\s*(\d+)/) {
	$self->log_error("could not find logonInfo in login response");
	return undef;
    }

    my $code = $1;

    if ($code != 0) {
	my $reason = $LOGON_ERROR{$code};
	$reason = "unknown logon error code" unless defined($reason);
	$self->log_error("login refused: $reason (logonInfo=$code)");
	return undef;
    }

    $self->log_debug("logged in");

    1;
}

sub http_backup {
    my ($self, $ua, $base, $dev_id, $dev_opt_tab) = @_;

    my $req = GET("$base/config_back.cgi?btnBackup=Backup+Config",
		  Referer => "$base/");

    my $res = $self->http_request($ua, $req, "config backup",
				  $self->dev_option($dev_opt_tab, "fetch_timeout"));

    return unless defined($res);

    # .cfg is what the "Config Restore" page insists on.
    $self->accept_binary_response($res, "$dev_id.cfg");
}

sub http_logout {
    my ($self, $ua, $base) = @_;

    my $req = GET("$base/Logout.htm");

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
