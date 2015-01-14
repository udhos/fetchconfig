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
# $Id: Detector.pm,v 1.28 2013/10/16 03:29:11 evertonm Exp $

package fetchconfig::model::Detector; # fetchconfig/model/Detector.pm

use strict;
use warnings;
use fetchconfig::model::CiscoIOS;
use fetchconfig::model::CiscoCAT;
use fetchconfig::model::CiscoASA;
use fetchconfig::model::FortiGate;
use fetchconfig::model::ProCurve;
use fetchconfig::model::Parks;
use fetchconfig::model::Riverstone;
use fetchconfig::model::Dell;
use fetchconfig::model::Terayon;
use fetchconfig::model::DmSwitch;
use fetchconfig::model::3ComMSR;
use fetchconfig::model::MikroTik;
use fetchconfig::model::CiscoPIX;
use fetchconfig::model::TellabsMSR;
use fetchconfig::model::JunOS;
use fetchconfig::model::Acme;
use fetchconfig::model::Mediant;

my $logger;
my %model_table;
my %dev_id_table;

sub parse {
    my ($class, $file, $num, $line) = @_;

    if (ref $class) { die "class method called as object method"; }
    unless (@_ == 4) { die "usage: $class->parse(\$logger, \$line_num, \$line)"; }

    #$logger->debug("Detector->parse: $line");

    if ($line =~ /^\s*default:/) {
	#
       ## global        model           options
        # default:       cisco-ios       user=backup,pass=san,enable=san
	#
	if ($line !~ /^\s*(\S+)\s+(\S+)\s+(\S.*)$/) {
	    $logger->error("unrecognized default at file=$file line=$num: $line");
	    return;
	}

	my @row = ($1, $2, $3);
	my $model_label = shift @row;

	$model_label = $row[0];
	my $mod = $model_table{$model_label};
	if (ref $mod) {
	    shift @row;
	    $mod->default_options($file, $num, $line, @row);
	    return;
	}

	$logger->error("unknown model '$model_label' at file=$file line=$num: $line");

	return;
    }

    #
    ## model         dev-unique-id   hostname        device-specific-options
    #cisco-ios       spo2            10.0.0.1 user=backup,pass=san,enable=fran
    #

    if ($line !~ /^\s*(\S+)\s+(\S+)\s+(\S+)\s*(.*)$/) {
	$logger->error("unrecognized device at file=$file line=$num: $line");
	return;
    }

    my @row = ($1, $2, $3, $4);
    my $model_label = shift @row;

    my $mod = $model_table{$model_label};
    if (! ref $mod) {
	$logger->error("unknown model '$model_label' at file=$file line=$num: $line");
	return;
    }

    my $dev_id = shift @row;

    my $dev_id_linenum = $dev_id_table{$dev_id};
    if (defined($dev_id_linenum)) {
	$logger->error("duplicated dev_id=$dev_id at file=$file line=$num: $line (previous at line $dev_id_linenum)");
	return;
    }

    $dev_id_table{$dev_id} = $num;

    my $dev_host = shift @row;

    my $dev_opt_tab = {};

    $mod->parse_options("dev=$dev_id",
			$file, $num, $line,
			$dev_opt_tab,
			@row);

    my ($latest_dir, $latest_file);

    #
    # "changes_only" is true: configuration is saved only when changed
    # "changes_only" is false: configuration is always saved
    #
    my $dev_changes_only = $mod->dev_option($dev_opt_tab, "changes_only");

    my $dev_run = $mod->dev_option($dev_opt_tab, "on_fetch_run");
    my $dev_cat = $mod->dev_option($dev_opt_tab, "on_fetch_cat");

    #
    # Do we need to locate the latest backup?
    # - changes_only means we need to compare in order to detect change
    # - on_fetch_run means we need to pass it to the external program
    # - on_fetch_cat means we need to copy it to stdout
    #
    if ($dev_changes_only || $dev_run || $dev_cat) {
	($latest_dir, $latest_file) = $mod->find_latest($dev_id, $dev_opt_tab);
    }

    my $fetch_ts_start = time;
    $logger->info("dev=$dev_id host=$dev_host: retrieving config at " . scalar(localtime($fetch_ts_start)));

    my ($config_dir, $config_file) = $mod->fetch($file, $num, $line, $dev_id, $dev_host, $dev_opt_tab);

    my $fetch_elap = time - $fetch_ts_start;
    $logger->info("dev=$dev_id host=$dev_host: config retrieval took $fetch_elap secs");

    return unless defined($config_dir);

    my $cfg_equal = 0; # false

    if (defined($latest_dir)) {
	$cfg_equal = $mod->config_equal($latest_dir, $latest_file, $config_dir, $config_file);
    }

    my $curr = "$config_dir/$config_file";

    if ($dev_run) {
	$ENV{FETCHCONFIG_DEV_ID} = $dev_id;
	$ENV{FETCHCONFIG_DEV_HOST} = $dev_host;
	if (defined($latest_dir)) {
	    $ENV{FETCHCONFIG_PREV} = "$latest_dir/$latest_file" ;
	}
	else {
	    delete $ENV{FETCHCONFIG_PREV};
	}
	$ENV{FETCHCONFIG_CURR} = $curr;
	system($dev_run);
	delete $ENV{FETCHCONFIG_DEV_ID};
	delete $ENV{FETCHCONFIG_DEV_HOST};
	delete $ENV{FETCHCONFIG_PREV};
	delete $ENV{FETCHCONFIG_CURR};
    }

    if ($dev_cat) {
	local *IN;
    
	if (!open(IN, "<$curr")) {
	    $logger->error("could not read current config: $curr: $!");
	    return;
	}

	my @cfg = <IN>;
	chomp @cfg;

	print STDOUT @cfg;

	close IN;
    }

    if ($dev_changes_only && $cfg_equal) {
	$logger->debug("dev=$dev_id host=$dev_host: discarding config unchanged since last run");
	$mod->config_discard($config_dir, $config_file);
    }

    $mod->purge_ancient($dev_id, $dev_opt_tab);
}

sub register {
    my ($class, $mod) = @_;

    $logger->debug("registering model: " . $mod->label);

    $model_table{$mod->label} = $mod;
}

sub init {
    my ($class, $log) = @_;

    $logger = $log;

    $class->register(fetchconfig::model::CiscoIOS->new($log));
    $class->register(fetchconfig::model::CiscoCAT->new($log));
    $class->register(fetchconfig::model::CiscoASA->new($log));
    $class->register(fetchconfig::model::FortiGate->new($log));
    $class->register(fetchconfig::model::ProCurve->new($log));
    $class->register(fetchconfig::model::Parks->new($log));
    $class->register(fetchconfig::model::Riverstone->new($log));
    $class->register(fetchconfig::model::Dell->new($log));
    $class->register(fetchconfig::model::Terayon->new($log));
    $class->register(fetchconfig::model::DmSwitch->new($log));
    $class->register(fetchconfig::model::3ComMSR->new($log));
    $class->register(fetchconfig::model::MikroTik->new($log));
    $class->register(fetchconfig::model::CiscoPIX->new($log));
    $class->register(fetchconfig::model::TellabsMSR->new($log));
    $class->register(fetchconfig::model::JunOS->new($log));
    $class->register(fetchconfig::model::Acme->new($log));
    $class->register(fetchconfig::model::Mediant->new($log));
}

1;
