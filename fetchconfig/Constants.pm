# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2007 Everton da Silva Marques
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
# $Id: Constants.pm,v 1.17 2012/11/28 14:17:28 evertonm Exp $

package fetchconfig::Constants; # fetchconfig/Constants.pm

use strict;
use warnings;

my $version = '0.23';

sub version {
    $version;
}

1;
