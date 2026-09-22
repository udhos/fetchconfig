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
# HP ProCurve ProVision switches, including the older chassis (4000M,
# 8000M) whose only remote management is the VT100 menu - unusable for
# scripted backup - but which will export a text copy of their
# configuration over TFTP when told to by SNMP. That is what this
# module does, and it is a transport unlike any other model here:
# neither a shell (telnet/SSH) nor the device's web UI, but SNMP plus
# TFTP. There is therefore no user/pass; the credential is the SNMP
# read-WRITE community (the write is needed to arm the export).
#
# The sequence, taken from a working standalone script:
#   1. SNMP set of the "copy" trigger OID to 2 (=enable): the switch
#      starts a TFTP server and makes the config available under a
#      well-known remote filename.
#   2. TFTP get of that filename (default "browse") from the switch to
#      the backup host.
#   3. SNMP set of the same OID to 1 (=disable): the switch stops its
#      TFTP server. THIS MUST RUN EVEN IF THE TRANSFER FAILED, so the
#      switch is never left with its TFTP server open; do_fetch calls
#      snmp_set_tftp_mode(1) on every path out once the enable
#      succeeded.
#
# Notes:
#   - "browse" yields a human-readable report (the "System Information
#     / Port Settings / ..." listing) - a DISPLAY export, good for
#     backup and change tracking but not a file that can be TFTP'd
#     back to restore the switch. Later ProVision models also accept
#     remote_file=running-config, a replayable config; set the
#     remote_file option accordingly.
#   - the switch pushes the file to the backup host over TFTP (UDP/69
#     inbound, then a data port), so a host firewall can block it;
#     that shows up here as a TFTP get failure/timeout, not a hang,
#     because Net::TFTP has its own timeout.
#   - the export carries no timestamp or uptime in the sample seen, so
#     changes_only compares byte-for-byte with no volatile-line
#     override.
#
# $Id: ProCurveSNMP.pm,v 1.1 2026/09/11 12:00:00 tammer Exp $

package fetchconfig::model::ProCurveSNMP; # fetchconfig/model/ProCurveSNMP.pm

use strict;
use warnings;
use Net::SNMP;
use Net::TFTP;
use File::Temp qw(tempfile);
use fetchconfig::model::Abstract;

@fetchconfig::model::ProCurveSNMP::ISA = qw(fetchconfig::model::Abstract);

# ProVision "copy" trigger OID; 2 = enable TFTP export, 1 = disable.
# Overridable per device with the "oid" option.
my $DEFAULT_OID          = '1.3.6.1.4.1.11.2.14.11.5.1.7.1.5.6.0';
my $DEFAULT_REMOTE_FILE  = 'browse';
my $DEFAULT_SNMP_VERSION = 'snmpv2c';

my $TFTP_ENABLE  = 2;
my $TFTP_DISABLE = 1;

####################################
# Implement model::Abstract - Begin
#

sub label {
    'procurve-snmp';
}

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

sub debug_line {
    my ($self, $text) = @_;

    my $fh = $self->{debug_fh};
    return unless defined($fh);

    print $fh $text, "\n";
}

#
# SNMP set of the trigger OID; returns true on success (already
# logged on failure).
#
sub snmp_set_tftp_mode {
    my ($self, $session, $oid, $value, $what) = @_;

    $self->debug_line("SNMP set $oid = INTEGER $value ($what)");

    my $result = $session->set_request(-varbindlist => [$oid, INTEGER, $value]);

    if (!defined($result)) {
	my $err = $session->error;
	$self->debug_line("SNMP set error: $err");
	$self->log_error("SNMP set failed ($what): $err");
	return undef;
    }

    $self->debug_line("SNMP set ok");

    1;
}

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

    # The credential here is the SNMP read-write community, not
    # user/pass: the write is what arms the TFTP export.
    my $dev_community = $self->dev_option($dev_opt_tab, "community");
    if (!defined($dev_community)) {
	$self->log_error("SNMP read-write community needed but not provided (community=...)");
	return;
    }

    my $dev_timeout = $self->dev_option($dev_opt_tab, "timeout");
    # (a missing timeout is defaulted to 30 s centrally by dev_option)

    my $dev_version = $self->dev_option($dev_opt_tab, "snmp_version");
    $dev_version = $DEFAULT_SNMP_VERSION unless defined($dev_version);

    my $dev_oid = $self->dev_option($dev_opt_tab, "oid");
    $dev_oid = $DEFAULT_OID unless defined($dev_oid);

    my $dev_remote = $self->dev_option($dev_opt_tab, "remote_file");
    $dev_remote = $DEFAULT_REMOTE_FILE unless defined($dev_remote);

    # debug=on: SNMP sets and the TFTP transfer are logged to
    # <repository>/<dev_id>.debug, overwritten on every run.
    delete $self->{debug_fh};
    if ($self->dev_option_flag($dev_opt_tab, "debug", 0)) {
	my $debug_path = "$dev_repository/$dev_id.debug";
	if (open(my $fh, '>', $debug_path)) {
	    $self->secure_debug_file($fh);   # contains the R/W community -> 0600
	    $self->{debug_fh} = $fh;
	}
	else {
	    $self->log_error("could not write debug file: $debug_path: $!");
	}
    }

    $self->debug_line("host=$dev_host version=$dev_version oid=$dev_oid remote_file=$dev_remote timeout=$dev_timeout");

    my ($session, $error) = Net::SNMP->session(
	-hostname  => $dev_host,
	-community => $dev_community,
	-version   => $dev_version,
	-timeout   => $dev_timeout);

    if (!defined($session)) {
	$self->debug_line("SNMP session error: $error");
	$self->log_error("could not open SNMP session: $error");
	$self->close_debug;
	return;
    }

    my @config;

    # Arm the export. Only if this succeeds do we touch TFTP, and only
    # then must we disable again.
    if ($self->snmp_set_tftp_mode($session, $dev_oid, $TFTP_ENABLE, "enable TFTP export")) {

	# Everything from here is wrapped so the disable set always
	# runs, transfer success or not.
	my $binary = $self->tftp_fetch($dev_host, $dev_remote, $dev_timeout);

	$self->snmp_set_tftp_mode($session, $dev_oid, $TFTP_DISABLE, "disable TFTP export");

	if (defined($binary)) {
	    # The export is text; normalize CRLF and split into lines.
	    $binary =~ s/\r//g;
	    @config = split /\n/, $binary;
	}
    }

    $session->close;
    $self->close_debug;

    return unless @config;

    $self->dump_config($dev_id, $dev_opt_tab, \@config);
}

#
# TFTP get of $remote from the switch into a temp file; returns the
# file's contents, or undef on error (already logged). A zero-length
# file is treated as an error (a corrupted/empty export), matching the
# standalone script's validation.
#
sub tftp_fetch {
    my ($self, $dev_host, $remote, $timeout) = @_;

    $self->debug_line("TFTP get $remote from $dev_host (timeout $timeout)");

    my $tftp = Net::TFTP->new($dev_host, Timeout => $timeout, BlockSize => 512);
    if (!$tftp) {
	$self->debug_line("TFTP init failed");
	$self->log_error("could not init TFTP client for $dev_host");
	return undef;
    }

    my ($fh, $tmp) = tempfile("fetchconfig-snmp-XXXXXX", TMPDIR => 1, UNLINK => 1);
    close($fh);

    if (!$tftp->get($remote, $tmp)) {
	my $err = $tftp->error;
	$self->debug_line("TFTP get failed: $err");
	$self->log_error("TFTP get failed: $err");
	return undef;
    }

    my $size = -s $tmp;
    if (!defined($size) || $size == 0) {
	$self->debug_line("TFTP get produced an empty file");
	$self->log_error("TFTP get produced an empty file (corrupted export?)");
	return undef;
    }

    my $content;
    if (open(my $in, '<', $tmp)) {
	local $/;
	$content = <$in>;
	close($in);
    }
    else {
	$self->log_error("could not read TFTP result $tmp: $!");
	return undef;
    }

    $self->debug_line("TFTP get ok: $size bytes");
    $self->log_debug("fetched: $size bytes");

    $content;
}

sub close_debug {
    my ($self) = @_;

    if (defined($self->{debug_fh})) {
	close($self->{debug_fh});
	delete $self->{debug_fh};
    }
}

1;
