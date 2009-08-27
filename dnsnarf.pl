#!/usr/bin/perl
#############################################################################
# Authors: Eric G. Wolfe <wolfe21 (at) marshall (dot) edu>                  #
#          Gerald Hevener <hevenerg (at) marshall (dot) edu>                #
# Program: dnsnarf.pl 1.3b                                                  #
# Purpose: Grabs DNS zones from a Windows Primary DNS server's              #
#          remote registry.  Writes a formatted named.conf for use with     #
#          ISC BIND DNS server.                                             #
#                                                                           #
# Copyright (c) 2007-2008                                                   #
# All rights reserved.                                                      #
#                                                                           #
# This application is free software; you can redistribute it and/or         #
# modify it under the same terms as Perl itself. See <perlartistic>.        #
#                                                                           #
# This program is distributed in the hope that it will be useful,           #
# but WITHOUT ANY WARRANTY; without even the implied warranty of            #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.                      #
#############################################################################
use strict;
use warnings;
use Log::Dispatch::Syslog;

# CONFIGURATION SECTION

# Credential Section
my $username = q/DNSDataAccess/;
my $password = q/ReallyStrongPassword!!!/;
my $domain   = q/CONTOSO.COM/;

# Primary DNS Server Section
my $primary_dns = q/kdc01.marshall.edu/;
my $registry_branch
    = q/"\\HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\DNS Server\\Zones"/;

# Any lines you want included in the top of named.conf
our @include_lines = (
    "/etc/named.options",    "/etc/named.rndc",
    "/etc/named.root.hints", "/etc/named.rfc1912.zones"
);

# Global variable which will be used for the print_named_conf subprocedure
our $master_dns      = 'default';
our $sysconfdir      = '/etc';
our $zone_file_path  = 'slaves';
our $zone_count_file = "$sysconfdir/dnsnarf.zonecount";

# Global variable for exceptions
# special cases such as stub zones,
# which cannot be transferred by a slave.
# Use regex conventions for this variable.
our $exceptions = q/(foo.com|bar.net)/;

# CODE SECTION

# Pass $level, $message, and $code (1 to exit with error, 0 to exit with success)
sub log_and_exit($$$) {

    my $level   = shift;
    my $message = shift;
    my $code    = shift;

    # Define our pid for use in the log message
    my $pid = getppid();

    # Log dnsnarf to /var/log/messages with prefix dnsnarf[$pid]
    # Define our logfile object
    my $logfile = Log::Dispatch::Syslog->new(
        name      => 'logfile',
        min_level => 'info',
        ident     => "dnsnarf[$pid]"
    );

    $logfile->log(
        level   => $level,
        message => $message,
    ) and exit $code;
}

# Subprocedure connect to Windows Server
# and returns zones in an array
# ($username, $password, $domain, primary_dns, $registry_branch)
sub read_remote_registry($$$$$) {

    my $user   = shift;
    my $pass   = shift;
    my $dom    = shift;
    my $server = shift;
    my $leaf   = shift;
    my @zone_array;

    # Samba net rpc command
    my $net_rpc_registry
        = qq/net -S $server -U $user%$pass -W $dom rpc registry enumerate $leaf/;

    # Zone line pattern
    my $zone_line = qr/^Keyname/;

    open( DCERPC, "$net_rpc_registry |" );
    while (<DCERPC>) {
        if ( $_ =~ m/$zone_line/ ) {
            my @tmp_line = split( /\s=\s/, $_ );
            chomp $tmp_line[-1];
            push @zone_array, $tmp_line[-1];
        }
    }
    close DCERPC;

    my $last_zone_count = 0;

    # If zone_count_file exists and not zero length
    if ( -e $zone_count_file && ( -s $zone_count_file != 0 ) ) {
        open( ZONECOUNT_RO, "<$zone_count_file" ) or die $!;
        chomp( $last_zone_count = <ZONECOUNT_RO> );
        close ZONECOUNT_RO;

        # Assume the file does not exist, or zone count is 0
    }
    else {
        $last_zone_count = 0;
    }

    # If there are more zones than last count, then
    # write a new zone count to the file.
    if ( $#zone_array > $last_zone_count ) {
        open( ZONECOUNT_RW, ">$zone_count_file" ) or die $!;
        print ZONECOUNT_RW $#zone_array;
        close ZONECOUNT_RW;

        # Return the zone name structure to main procedure.
        return @zone_array;
    }
    else {

        # There must be no new zones, reloading named is unnecessary.
        # We'll log and exit with success here.
        log_and_exit( 'info', "Config not updated, no reloading necessary.",
            0 );
    }

}

# Subprocedure, takes an array of zones
# and writes out a named.conf file
sub print_named_conf(@) {

    my @dnszones = @_;

    # Open file handle to build named.conf file
    open( ZONES, ">$sysconfdir/named.conf" ) or die $!;

    # includes at top of named.conf
    foreach my $include_line (@include_lines) {
        print ZONES "include \"$include_line\";\n";
    }
    print ZONES "\n";    # One empty line for separation.

    # Build zones section of named.conf, dynamically
    foreach my $zone (@dnszones) {
        if (   ( ( defined $exceptions ) && ( $zone !~ $exceptions ) )
            || ( $exceptions eq '' ) )
        {
            print ZONES "zone $zone in {\n";
            print ZONES "\ttype slave;\n";
            print ZONES "\tfile \"$zone_file_path/db.$zone\";\n";
            print ZONES "\tmasters { $master_dns; };\n";
            print ZONES "};\n\n";
        }
    }
    close ZONES;
}

# Main program logic

# Set @zones variable to a list of DNS Zones on remote server
my @zones = read_remote_registry( $username, $password, $domain, $primary_dns,
    $registry_branch );

# If we were able to read zones from the remote server
# then try to build an appropriate named.conf file
if (@zones) {

    # Call print_named_conf to build named.conf file.
    # Build new named.conf file.
    print_named_conf(@zones);

    # RNDC reload
    system('/usr/sbin/rndc reload');

    # Log the configuration update
    log_and_exit( 'info', "named.conf updated, rndc reload called", 0 );

}

# If no zones were returned by the read_remote_registry
# function, then log the error and kill dnsnarf.
else {
    log_and_exit( 'error', "Error reading zones, not creating named.conf",
        1 );
}
