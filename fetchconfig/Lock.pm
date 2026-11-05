# fetchconfig - Retrieving configuration for multiple devices
# Copyright (C) 2007 Everton da Silva Marques
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
# fetchconfig::Lock - a small advisory lock on a device-table file.
#
# The lock object is a SIDECAR file "<devices>.lock", never the device table
# itself: --rename-device-id rewrites the table via a temp file + rename(),
# which swaps the table's inode, so a lock held on the table's own descriptor
# would not cover the swap. Both sides lock the stable sidecar instead.
#
#   - a normal fetch/lookup run takes a SHARED lock while it reads the table,
#     with a short bounded wait; on timeout it aborts rather than run against a
#     table that a rename is in the middle of changing;
#   - --rename-device-id / --replay-db-change take an EXCLUSIVE lock.
#
# acquire() returns (handle, status):
#   ('<handle>', 'ok')      the lock is held; keep the handle in scope, it is
#                           released when the handle is closed or goes out of
#                           scope (release() does so explicitly).
#   (undef,      'timeout') a conflicting lock is held and the wait elapsed.
#   (undef,      'nolock')  the sidecar could not even be opened/created (e.g.
#                           a read-only or permission-denied directory): the
#                           caller decides whether to proceed (a run does, so
#                           locking never breaks an otherwise-fine deployment)
#                           or abort (a rename does, for safety).
#

package fetchconfig::Lock;

use strict;
use warnings;
use Fcntl qw(:flock O_RDWR O_CREAT);

sub sidecar_path {
    my ($class, $table_path) = @_;
    return "$table_path.lock";
}

sub acquire {
    my ($class, $table_path, %opt) = @_;
    my $exclusive = $opt{exclusive} ? 1 : 0;
    my $timeout   = defined($opt{timeout}) ? $opt{timeout} : 2;

    my $sidecar = $class->sidecar_path($table_path);

    my $fh;
    # O_CREAT so the first run/rename on a table makes the sidecar; no O_EXCL,
    # concurrent openers share it. We never write to it - it is a pure token.
    if (!sysopen($fh, $sidecar, O_RDWR | O_CREAT, 0644)) {
        return (undef, 'nolock');
    }

    my $mode = ($exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB;

    my $waited = 0;
    my $step   = 0.1;   # poll interval (seconds)
    while (1) {
        if (flock($fh, $mode)) {
            return ($fh, 'ok');
        }
        last if $waited >= $timeout;
        select(undef, undef, undef, $step);   # portable sub-second sleep
        $waited += $step;
    }

    close($fh);
    return (undef, 'timeout');
}

sub release {
    my ($class, $fh) = @_;
    return unless defined $fh;
    # Closing the descriptor releases the flock; do it explicitly so the caller
    # need not rely on scope/GC timing.
    flock($fh, LOCK_UN);
    close($fh);
}

1;
