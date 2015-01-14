# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2006 Everton da Silva Marques
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
# $Id: Logger.pm,v 1.1 2006/06/08 20:28:39 evertonm Exp $

package fetchconfig::Logger; # fetchconfig/Logger.pm

use strict;
use warnings;

sub new {
    my ($proto, $options) = @_;
    my $class = ref($proto) || $proto;

    # defaults
    my $self = {
	          prefix => '?'
		};

    # user options
    if (@_ > 1) {
	foreach (keys %$options) {
	    $self->{$_} = $options->{$_};
	}
    }

    bless $self, $class;
}

sub prefix {
    my ($self, $prefix) = @_;

    my $old = $self->{prefix};

    if (defined($prefix)) {
	$self->{prefix} = $prefix;
    }

    $old;
}

sub info {
    my ($self, $msg) = @_;

    warn $self->{prefix}, ": info: ", $msg, "\n";
}

sub debug {
    my ($self, $msg) = @_;

    warn $self->{prefix}, ": debug: ", $msg, "\n";
}

sub error {
    my ($self, $msg) = @_;

    warn $self->{prefix}, ": error: ", $msg, "\n";
}

1;
