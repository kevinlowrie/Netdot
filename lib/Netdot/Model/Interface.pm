package Netdot::Model::Interface;

use base 'Netdot::Model';
use warnings;
use strict;

my $IPV4 = Netdot->get_ipv4_regex();
my $IPV6 = Netdot->get_ipv6_regex();
my $MAC  = Netdot->get_mac_regex();
my $logger = Netdot->log->get_logger('Netdot::Model::Device');

#Be sure to return 1
1;

=head1 NAME

Netdot::Model::Interface

=head1 SYNOPSIS


=head1 CLASS METHODS
=cut

################################################################
=head2 insert - Insert Interface object

    We override the insert method for extra functionality

  Arguments: 
    Hash ref with Interface  fields
  Returns:   
    New Interface object
  Examples:

=cut
sub insert {
    my ($self, $argv) = @_;
    $self->isa_class_method('insert');
    
    # Set some defaults
    $argv->{speed}       ||= 0;
    $argv->{doc_status}  ||= 'manual';

    $argv->{snmp_managed} = $self->config->get('IF_SNMP') 
	unless defined $argv->{snmp_managed};
    
    $argv->{overwrite_descr} = $self->config->get('IF_OVERWRITE_DESCR') 
	unless defined $argv->{overwrite_descr};
    
    $argv->{monitored} = 0 unless defined $argv->{monitored};
    
    $argv->{auto_dns} = $self->config->get('UPDATE_DEVICE_IP_NAMES') 
	unless defined $argv->{auto_dns};
    
    my $unknown_status = (MonitorStatus->search(name=>"Unknown"))[0];
    $argv->{monitorstatus} = ($unknown_status)? $unknown_status->id : 0;
    
    return $self->SUPER::insert( $argv );
}

################################################################
=head2 - find_duplex_mismatches - Finds pairs of interfaces with duplex and/or speed mismatch

  Arguments: 
    None
  Returns:   
    Array of arrayrefs containing pairs of interface id's
  Examples:
    my @list = Interface->find_duplex_mismatches();
=cut
sub find_duplex_mismatches {
    my ($class) = @_;
    $class->isa_class_method('find_duplex_mismatches');
    my $dbh = $class->db_Main();
    my $mismatches = $dbh->selectall_arrayref("SELECT  i.id, r.id
                                               FROM    interface i, interface r
                                               WHERE   i.id<=r.id
                                                 AND   i.neighbor=r.id  
                                                 AND   i.oper_status='up'
                                                 AND   r.oper_status='up'
                                                 AND   i.oper_duplex!=r.oper_duplex");

    if ( $mismatches ){
	my @pairs = @$mismatches;
	#
	# Ignore devices that incorrectly report their settings
	my @results;
	if ( my $ignored_list = $class->config->get('IGNORE_DUPLEX') ){
	    my %ignored;
	    foreach my $id ( @$ignored_list){
		$ignored{$id} = 1;
	    }
	    foreach my $pair ( @pairs ){
		my $match = 0;
		foreach my $ifaceid ( @$pair ){
		    my $iface = Interface->retrieve($ifaceid) 
			|| $class->throw_fatal("Model::Interface::find_duplex_mismatches: Cannot retrieve Interface id $ifaceid");
		    if ( $iface->device && $iface->device->product 
			 && $iface->device->product->sysobjectid 
			 && exists $ignored{$iface->device->product->sysobjectid} ){
			$match = 1;
			last;
		    }
		}
		push @results, $pair unless $match;
	    }
	}else{
	    return \@pairs;
	}
	return \@results;
    }else{
	return;
    }
}

=head1 OBJECT METHODS
=cut
################################################################
=head2 delete - Delete object

    We override the delete method for extra functionality

  Arguments: 
    None
  Returns:   
    True if sucessful
  Examples:
    $interface->delete();

=cut
sub delete {
    my $self = shift;
    $self->isa_object_method('delete');
    
    foreach my $neighbor ( $self->neighbors ){
	$neighbor->SUPER::update({neighbor=>0, neighbor_fixed=>0, neighbor_missed=>0});
    }

    return $self->SUPER::delete();
}

############################################################################
=head2 add_neighbor
    
  Arguments:
    Hash with following key/value pairs:
    id        - Neighbor's Interface id
    score     - Optional score obtained from Topology discovery code (for logging)
    fixed     - (bool) Whether relationship should be removed by automated processes
  Returns:
    True if neighbor was successfully added
  Example:
    $interface->add_neighbor($id);

=cut
sub add_neighbor{
    my ($self, %argv) = @_;
    $self->isa_object_method('add_neighbor');
    my $nid   = $argv{id}    || $self->throw_fatal("Model::Interface::add_neighbor: Missing required argument: id");
    my $score = $argv{score} || 'n/a';
    my $fixed = $argv{fixed} || 0;

    if ( $nid == $self->id ){
	$self->throw_user(sprintf("%s: interface cannot be neighbor of itself", $self->get_label));
    }

    my $neighbor = Interface->retrieve($nid) 
	|| $self->throw_fatal("Model::Interface::add_neighbor: Cannot retrieve Interface id $nid");
    
    if ( int($self->neighbor) && int($neighbor->neighbor) 
	 && $self->neighbor->id == $neighbor->id 
	 && $neighbor->neighbor->id == $self->id ){
	
	return 1;
    }
    
    $logger->debug(sub{sprintf("Adding new neighbors: %s <=> %s, score: %s", 
			       $self->get_label, $neighbor->get_label, $score)});
    
    if ( $self->neighbor && $self->neighbor_fixed ){
	$self->throw_user(sprintf("%s has been manually linked to %s", 
				  $self->get_label, $self->neighbor->get_label));
	
    }elsif ( $neighbor->neighbor && $neighbor->neighbor_fixed ) {
	$self->throw_user(sprintf("%s has been manually linked to %s", 
				  $neighbor->get_label, $neighbor->neighbor->get_label));

    }else{
	# Make sure all neighbor relationships are cleared before going on
	$self->remove_neighbor();
	$neighbor->remove_neighbor();
	
	$self->SUPER::update({neighbor        => $neighbor->id, 
			      neighbor_fixed  => $fixed, 
			      neighbor_missed => 0});
	
	$neighbor->SUPER::update({neighbor        => $self->id, 
				  neighbor_fixed  => $fixed, 
				  neighbor_missed => 0});
	
	$logger->info(sprintf("Added new neighbors: %s <=> %s, score: %s", 
			      $self->get_label, $neighbor->get_label, $score));
	return 1;
    }
}


############################################################################
=head2 remove_neighbor
    
  Arguments:
    None
  Returns:
    See update method
  Example:
    $interface->remove_neighbor();

=cut
sub remove_neighbor{
    my ($self) = @_;

    my %args = (
	neighbor        => 0,
	neighbor_fixed  => 0, 
	neighbor_missed => 0
	);

    # Unset neighbor field in all interfaces that have
    # me as their neighbor
    map { $_->SUPER::update(\%args) } $self->neighbors;
    
    # Unset my own neighbor field
    return $self->SUPER::update(\%args);
}

############################################################################
=head2 update - Update Interface
    
  Arguments:
    Hash ref with Interface fields
  Returns:
    See Class::DBI::update()
  Example:
    $interface->update( \%data );

=cut
sub update {
    my ($self, $argv) = @_;
    $self->isa_object_method('update');    
    my $class = ref($self);
    
    if ( exists $argv->{neighbor} ){
	if ( int($argv->{neighbor}) == 0 ){
	    $self->remove_neighbor();
	}else{
	    $self->add_neighbor(id    => $argv->{neighbor},
				fixed => $argv->{neighbor_fixed});
	}
    }
    delete $argv->{neighbor};
    return $self->SUPER::update($argv);
}

############################################################################
=head2 snmp_update - Update Interface using SNMP info

  Arguments:  
    Hash with the following keys:
    info          - Hash ref with SNMP info about interface
    add_subnets   - Whether to add subnets automatically
    subs_inherit  - Whether subnets should inherit info from the Device
    ipv4_changed  - Scalar ref.  Set if IPv4 info changes
    ipv6_changed  - Scalar ref.  Set if IPv6 info changes
    stp_instances - Hash ref with device STP info
  Returns:    
    Interface object
  Example:
    $if->snmp_update(info         => $info->{interface}->{$newif},
		     add_subnets  => $add_subnets,
		     subs_inherit => $subs_inherit,
		     ipv4_changed => \$ipv4_changed,
		     ipv6_changed => \$ipv6_changed,
		     );
=cut
sub snmp_update {
    my ($self, %args) = @_;
    $self->isa_object_method('snmp_update');
    my $class = ref($self);
    my $newif = $args{info};
    my $label  = $self->get_label;
    # Remember these are scalar refs.
    my ( $ipv4_changed, $ipv6_changed ) = @args{'ipv4_changed', 'ipv6_changed'};

    my %iftmp = (doc_status => 'snmp');

    ############################################
    # Fill in standard fields
    my @stdfields = qw( number name type description speed admin_status 
		        oper_status admin_duplex oper_duplex stp_id 
   		        bpdu_guard_enabled bpdu_filter_enabled loop_guard_enabled root_guard_enabled
                        dp_remote_id dp_remote_ip dp_remote_port dp_remote_type
                      );
    
    foreach my $field ( @stdfields ){
	$iftmp{$field} = $newif->{$field} if exists $newif->{$field};
    }
    
    ############################################
    # Update PhysAddr
    if ( ! $newif->{physaddr} ){
	$iftmp{physaddr} = 0;
    }elsif ( my $addr = PhysAddr->validate($newif->{physaddr}) ){
	
	my $physaddr = PhysAddr->search(address=>$addr)->first;
	if ( $physaddr ){
	    $physaddr->update({last_seen=>$self->timestamp, static=>1});
	    $iftmp{physaddr} = $physaddr->id;
	}else{
	    eval {
		$physaddr = PhysAddr->insert({address=>$addr, static=>1}); 
	    };
	    if ( my $e = $@ ){
		$logger->debug(sub{"$label: Could not insert PhysAddr $addr: $e"});
	    }
	}
    }
    
    # Check if description can be overwritten
    delete $iftmp{description} if !($self->overwrite_descr) ;

    ############################################
    # Update

    my $r = $self->update( \%iftmp );
    $logger->debug(sub{ sprintf("%s: Interface %s (%s) updated", 
				$label, $self->number, $self->name) }) if $r;
    

    ##############################################
    # Update VLANs
    #
    # Get our current vlan memberships
    # InterfaceVlan objects
    #
    if ( exists $newif->{vlans} ){
	my %oldvlans;
	map { $oldvlans{$_->id} = $_ } $self->vlans();
	
	# InterfaceVlan STP fields and their methods
	my %IVFIELDS = ( stp_des_bridge => 'i_stp_bridge',
			 stp_des_port   => 'i_stp_port',
			 stp_state      => 'i_stp_state',
	    );
	
	foreach my $newvlan ( keys %{ $newif->{vlans} } ){
	    my $vid   = $newif->{vlans}->{$newvlan}->{vid} || $newvlan;
	    my $vname = $newif->{vlans}->{$newvlan}->{vname};
	    my $vo;
	    my %vdata;
	    $vdata{vid}   = $vid;
	    $vdata{name}  = $vname if defined $vname;
	    if ( $vo = Vlan->search(vid => $vid)->first ){
		# update in case named changed
		# (ignore default vlan 1)
		if ( defined $vdata{name} && $vo->vid ne "1" ){
		    if ( !(defined $vo->name) || 
			 (defined $vo->name && $vdata{name} ne $vo->name) ){
			my $r = $vo->update(\%vdata);
			$logger->debug(sub{ sprintf("%s: VLAN %s name updated: %s", $label, $vo->vid, $vo->name) })
			    if $r;
		    }
		}
	    }else{
		# create
		$vo = Vlan->insert(\%vdata);
		$logger->info(sprintf("%s: Inserted VLAN %s", $label, $vo->vid));
	    }
	    # Now verify membership
	    #
	    my %ivtmp = ( interface => $self->id, vlan => $vo->id );
	    my $iv;
	    if  ( $iv = InterfaceVlan->search( \%ivtmp )->first ){
		delete $oldvlans{$iv->id};
	    }else {
		# insert
		$iv = InterfaceVlan->insert( \%ivtmp );
		$logger->debug(sub{sprintf("%s: Assigned Interface %s (%s) to VLAN %s", 
					   $label, $self->number, $self->name, $vo->vid)});
	    }

	    # Insert STP information for this interface on this vlan
	    my $stpinst = $newif->{vlans}->{$newvlan}->{stp_instance};
	    next unless defined $stpinst;
	    my $instobj;
		# In theory, this happens after the STP instances have been updated on this device
	    $instobj = STPInstance->search(device=>$self->device, number=>$stpinst)->first;
	    unless ( $instobj ){
		$logger->warn("$label: Cannot find STP instance $stpinst");
		next;
	    }
	    my %uargs;
	    foreach my $field ( keys %IVFIELDS ){
		my $method = $IVFIELDS{$field};
		if ( exists $args{stp_instances}->{$stpinst}->{$method} &&
		     (my $v = $args{stp_instances}->{$stpinst}->{$method}->{$newif->{number}}) ){
		    $uargs{$field} = $v;
		}
	    }
	    if ( %uargs ){
		$iv->update({stp_instance=>$instobj, %uargs});
		$logger->debug(sub{ sprintf("%s: Updated STP info on VLAN %s", 
					    $label, $vo->vid) });
	    }
	}    
	# Remove each vlan membership that no longer exists
	#
	foreach my $oldvlan ( keys %oldvlans ) {
	    my $iv = $oldvlans{$oldvlan};
	    $logger->debug(sub{sprintf("%s: membership with VLAN %s no longer exists.  Removing.", 
				   $label, $iv->vlan->vid)});
	    $iv->delete();
	}
    }

    ################################################################
    # Update IPs
    #
    if ( exists( $newif->{ips} ) ) {

	# For Subnet->vlan assignments
	my $vlan = 0;
	my @ivs  = $self->vlans;
	$vlan = $ivs[0]->vlan if ( scalar(@ivs) == 1 ); 

	my $name = $self->name;

	# For layer3 switches with virtual VLAN interfaces
	if ( !$vlan && $name =~ /Vlan(\d+)/ ){
	    my $vid = $1;
	    $vlan = Vlan->search(vid=>$vid)->first;
	}

	foreach my $newip ( keys %{ $newif->{ips} } ){
	    if ( my $address = $newif->{ips}->{$newip}->{address} ){
		my %iargs   =  (address      => $address,
				mask         => $newif->{ips}->{$newip}->{mask},
				add_subnets  => $args{add_subnets},
				subs_inherit => $args{subs_inherit},
				ipv4_changed => $ipv4_changed,
				ipv6_changed => $ipv6_changed,
		    );
		$iargs{vlan} = $vlan if $vlan;
		if ( $self->ignore_ip ){
		    $logger->debug(sub{sprintf("%s: Ignoring IP information", $label)});
		}else{
		    $self->update_ip(%iargs);
		}
	    }
	}
    } 
    
    return $self;
}

############################################################################
=head2 update_ip - Update IP adddress for this interface

  Arguments:
    Hash with the following keys:
    address      - Dotted quad ip address
    mask         - Dotted quad mask
    add_subnets  - Flag.  Add subnet if necessary (only for routers)
    subs_inherit - Flag.  Have subnet inherit some Device information
    ipv4_changed - Scalar ref.  Set if IPv4 info changes
    ipv6_changed - Scalar ref.  Set if IPv6 info changes
    vlan         - Vlan ID (for Subnet to Vlan mapping)
    
  Returns:
    Updated Ipblock object
  Example:
    
=cut
sub update_ip {
    my ($self, %args) = @_;
    $self->isa_object_method('update_ip');

    my $address = $args{address};
    $self->throw_fatal("Model::Interface::update_ip: Missing required arguments: address") unless ( $address );
    # Remember these are scalar refs.
    my ( $ipv4_changed, $ipv6_changed ) = @args{'ipv4_changed', 'ipv6_changed'};

    my $label = $self->get_label;
    
    # Do not bother with loopbacks
    if ( Ipblock->is_loopback($address) ){
	$logger->debug(sub{"$label: IP $address is a loopback. Skipping."});
	return;
    }
	
    my $version = ($address =~ /^($IPV4)$/) ?  4 : 6;
    my $prefix  = ($version == 4)  ? 32 : 128;
    
    # If given a mask, we might have to add a subnet
    if ( (my $mask = $args{mask}) && $args{add_subnets} && $self->device->ipforwarding ){
	# Create a subnet if necessary
	my ($subnetaddr, $subnetprefix) = Ipblock->get_subnet_addr(address => $address, 
								   prefix  => $mask );
	if ( ($version == 4 && $subnetprefix == 31) || $subnetaddr ne $address ){
	    my %iargs;
	    $iargs{status} = 'Subnet' ;
	    
	    # If we have a VLAN, make the relationship
	    $iargs{vlan} = $args{vlan} if defined $args{vlan};
	    
	    if ( my $subnet = Ipblock->search(address => $subnetaddr, 
					      prefix  => $subnetprefix)->first ){
		
		$logger->debug(sub{ sprintf("%s: Block %s/%s already exists", 
					    $label, $subnetaddr, $subnetprefix)} );
		
		# Skip validation for speed, since the block already exists
		$iargs{validate} = 0;

		$subnet->update(\%iargs);
	    }else{
		$logger->debug(sub{ sprintf("Subnet %s/%s does not exist.  Inserting.", $subnetaddr, $subnetprefix) });
		
		# Check if subnet should inherit device info
		if ( $args{subs_inherit} ){
		    $iargs{owner}   = $self->device->owner;
		    $iargs{used_by} = $self->device->used_by;
		}

		$iargs{address} = $subnetaddr;
		$iargs{prefix}  = $subnetprefix;
		
		# We will update tree once at the end of all interface updates 
		# (in Device.pm)
		$iargs{no_update_tree} = 1;

		# Ipblock validation might throw an exception
		my $newblock;
		eval {
		    $newblock = Ipblock->insert(\%iargs);
		};
		if ( my $e = $@ ){
		    $logger->error(sprintf("%s: Could not insert Subnet %s/%s: %s", 
					   $label, $subnetaddr, $subnetprefix, $e));
		}else{
		    $logger->info(sprintf("%s: Created Subnet %s/%s", 
					  $label, $subnetaddr, $subnetprefix));
		    my $version = $newblock->version;
		    if ( $version == 4 ){
			$$ipv4_changed = 1;
		    }elsif ( $version == 6 ){
			$$ipv6_changed = 1;
		    }
		}
	    }
	}
    }
    
    my $ipobj;
    if ( $ipobj = Ipblock->search(address=>$address)->first ){

	# update
	$logger->debug(sub{ sprintf("%s: IP %s/%s exists. Updating", 
				    $label, $address, $prefix) });
	
	# Notice that this is basically to confirm that the IP belongs
	# to this interface and that the status is set to Static.  
	# Therefore, it's very unlikely that the object won't pass 
	# validation, so we skip it to speed things up.
	$ipobj->update({ status     => "Static",
			 interface  => $self,
			 validate   => 0,
		       });
    }else {
	# Create a new Ip
	# This could also go wrong, but we don't want to bail out
	eval {
	    $ipobj = Ipblock->insert({address => $address, prefix => $prefix, 
				      status  => "Static", interface  => $self,
				      no_update_tree => 1,
				     });
	};
	if ( my $e = $@ ){
	    $logger->warn(sprintf("%s: Could not insert IP %s: %s", 
				   $label, $address, $e));
	    return;
	}else{
	    $logger->info(sprintf("%s: Inserted new IP %s", $label, $ipobj->address));
	    my $version = $ipobj->version;
	    if ( $version == 4 ){
		$$ipv4_changed = 1;
	    }elsif ( $version == 6 ){
		$$ipv6_changed = 1;
	    }
	}
    }
    return $ipobj;
}

############################################################################
=head2 speed_pretty - Convert ifSpeed to something more readable

  Arguments:  
    None
  Returns:    
    Human readable speed string or n/a

=cut

sub speed_pretty {
    my ($self) = @_;
    $self->isa_object_method('speed_pretty');
    my $speed = $self->speed;

    my %SPEED_MAP = ('1536000'     => 'T1',
                     '1544000'     => 'T1',
                     '3072000'     => 'Dual T1',
                     '3088000'     => 'Dual T1',
                     '44210000'    => 'T3',
                     '44736000'    => 'T3',
                     '45045000'    => 'DS3',
                     '46359642'    => 'DS3',
                     '149760000'   => 'ATM on OC-3',
                     '155000000'   => 'OC-3',
                     '155519000'   => 'OC-3',
                     '155520000'   => 'OC-3',
                     '599040000'   => 'ATM on OC-12',
                     '622000000'   => 'OC-12',
                     '622080000'   => 'OC-12',
                     );

    if ( exists $SPEED_MAP{$speed} ){
	return $SPEED_MAP{$speed};
    }else{
	# ifHighSpeed (already translated to bps)
	my $fmt = "%d bps";
	if ( $speed > 9999999999999 ){
	    $fmt = "%d Tbps";
	    $speed /= 1000000000000;
	} elsif ( $speed > 999999999999 ){
	    $fmt = "%.1f Tbps";
	    $speed /= 1000000000000.0;
	} elsif ( $speed > 9999999999 ){
	    $fmt = "%d Gbps";
	    $speed /= 1000000000;
	} elsif ( $speed > 999999999 ){
	    $fmt = "%.1f Gbps";
	    $speed /= 1000000000.0;
	} elsif ( $speed > 9999999 ){
	    $fmt = "%d Mbps";
	    $speed /= 1000000;
	} elsif ( $speed > 999999 ){
	    $fmt = "%d Mbps";
	    $speed /= 1000000.0;
	} elsif ( $speed > 99999 ){
	    $fmt = "%d Kbps";
	    $speed /= 100000;
	} elsif ( $speed > 9999 ){
	    $fmt = "%d Kbps";
	    $speed /= 100000.0;
	}
	return sprintf($fmt, $speed);
    }
}

############################################################################
sub get_label{
    my ($self) = @_;
    $self->isa_object_method('get_label');
    return unless ( $self->id && $self->device );
    my $name = $self->name || $self->number;
    my $label = sprintf("%s [%s]", $self->device->get_label, $name);
    return $label;
}

=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2006 University of Oregon, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

