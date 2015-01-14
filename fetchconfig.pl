#! /usr/bin/perl -w
#
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
# $Id: fetchconfig.pl,v 1.8 2012/11/27 21:42:28 evertonm Exp $

use strict;
use fetchconfig::Logger;
use fetchconfig::Constants;
use fetchconfig::model::Detector;

sub basename {
    my ($path) = @_;

    my @list;

    if ($^O eq 'MSWin32') {
	@list = split /\\/, $path;
    }
    else {
	@list = split /\//, $path;
    }

    pop @list;
}

my $me = basename($0);

my $log = fetchconfig::Logger->new({ prefix => $me });

$log->info('version ' . fetchconfig::Constants::version);

my @device_file_list;
my @line_list;

foreach my $opt (@ARGV) {
    if ($opt eq '-v') {
	exit; # only show version
    }
    if ($opt =~ /^-devices=(.+)$/) {
	push @device_file_list, $1;
	next;
    }
    if ($opt =~ /^-line=(.+)$/) {
	push @line_list, $1;
	next;
    }
    $log->error("unexpected argument: $opt");
    &usage;
    die;
}

if ((@device_file_list < 1) && (@line_list < 1)){
    $log->error("at least one -devices=filename or one -line=string is required");
    &usage;
    die;
}

fetchconfig::model::Detector->init($log);

foreach my $dev_file (@device_file_list) {
    &load_device_list($dev_file);
}

my $line_num = 0;
foreach my $line (@line_list) {
    ++$line_num;
    &load_line($line, $line_num);
}

$log->info("done");

exit;

sub usage {
    warn "usage: $me [-v] [-devices=file] [-line=string]\n";
}

sub load_device_list {
    my ($filename) = @_;
    
    local *IN;
    
    if (!open(IN, "<$filename")) {
	$log->error("could not read device list: $filename: $!");
	return;
    }
    
    $log->debug("loading device list: $filename");

    my $line_num = 0;
    
    while (<IN>) {
	chomp;

	++$line_num;

	#$log->debug("[$line_num] $_");

	next if (/^\s*(#|$)/);

        fetchconfig::model::Detector->parse($filename, $line_num, $_);
    }
		 
    close IN;
}

sub load_line {
    my ($line, $num) = @_;
    
    $log->debug("loading line: line=$num [$line]");

    return if ($line =~ /^\s*(#|$)/);

    fetchconfig::model::Detector->parse('<cmdline>', $num, $line);
}
