#!/usr/bin/perl
#############################################################################
# Authors: Eric G. Wolfe <wolfe21 (at) marshall (dot) edu>                  #
#          Gerald Hevener <hevenerg (at) marshall (dot) edu>                #
# Program: dnsnarf.pl 1.4b                                                  #
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
my $password = q/Really_Strong_Password!!!/;
my $domain   = q/CONTOSO.COM/;

# Primary DNS Server Section
my $primary_dns = q/kdc01.contoso.com/;
my $registry_branch
    = q/"\\HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\DNS Server\\Zones"/;
our $optionsconf   = "/etc/named.options";
our $rndcconf      = "/etc/named.rndc";
our $roothintsconf = "/etc/named.root.hints";
our $rfc1912conf   = "/etc/named.rfc1912.zones";

# Global variable which will be used in print_named_conf subprocedure
our $master_dns     = 'default';
our $sysconfdir     = '/etc';
our $zone_file_path = 'slaves';

# Global variable for exceptions
# special cases such as stub zones,
# which cannot be transferred by a slave.
# Use regex conventions for this variable.
our $exceptions = q/(foo.com|bar.net)/;

# CODE SECTION

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
    return @zone_array;
}

# Subprocedure, takes an array of zones
# and writes out a named.conf file
sub print_named_conf(@) {

    my @dnszones = @_;

    # Open file handle to build named.conf file
    open( ZONES, ">$sysconfdir/named.conf" ) or die $!;

    # includes at top of named.conf
    print ZONES "include \"$optionsconf\";\n";
    print ZONES "include \"$rndcconf\";\n";
    print ZONES "include \"$roothintsconf\";\n";
    print ZONES "include \"$rfc1912conf\";\n\n";

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

# Define our pid for use in the log message
my $pid = getppid();

# Log dnsnarf to /var/log/messages with prefix dnsnarf[$pid]
# Define our logfile object
my $logfile = Log::Dispatch::Syslog->new(
    name      => 'logfile',
    min_level => 'info',
    ident     => "dnsnarf[$pid]"
);

# If we were able to read zones from the remote server
# then try to build an appropriate named.conf file
if (@zones) {

    # Call print_named_conf to build named.conf file.
    # Build new named.conf file.
    print_named_conf(@zones);

    # Log the configuration update
    $logfile->log( level => 'info', message => "named.conf updated." );

    # RNDC reload
    system('/usr/sbin/rndc reload');

    $logfile->log( level => 'info', message => "rndc reload successful" );

    # If no zones were returned by the read_remote_registry
    # function, then log the error and kill dnsnarf.
}
else {

    $logfile->log(
        level   => 'error',
        message => "Error reading zones, not creating named.conf"
    ) and die("Error reading zones, not creating named.conf\n");

}
