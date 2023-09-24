# --
# Copyright (C) 2001-2021 OTRS AG, https://otrs.com/
# Copyright (C) 2021 Znuny GmbH, https://znuny.org/
# Copyright (C) 2023 mo-azfar, https://github.com/mo-azfar/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::PostMaster::Filter::ConfigItemSNRecognition;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::Config',
	'Kernel::System::CustomerUser',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    $Self->{ParserObject} = $Param{ParserObject} || die "Got no ParserObject";

    # Get communication log object and MessageID.
    $Self->{CommunicationLogObject} = $Param{CommunicationLogObject} || die "Got no CommunicationLogObject!";

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;
	
	$Self->{FilterName} = 'ConfigItemSNRecognition';

	for my $Needed (qw(JobConfig GetParam)) {
        if ( !$Param{$Needed} ) {
            $Self->{CommunicationLogObject}->ObjectLog(
                ObjectLogType => 'Message',
                Priority      => 'Error',
                Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
                Value         => "Need $Needed!",
            );
            return;
        }
    }

    return 1 if !$Param{GetParam}->{From};

    my $SerialNumberRegExp = $Param{JobConfig}->{SerialNumberRegExp};

	my @MultiSNs;
	
    # search in the body 
    if ( $Param{JobConfig}->{SearchInBody} ) {

        # split the body into separate lines
        my @BodyLines = split /\n/, $Param{GetParam}->{Body};

        # traverse lines and return first match
        LINE:
        for my $Line (@BodyLines) {
            if ( $Line =~ m{$SerialNumberRegExp}ms ) {

                # get the found element value
				push @MultiSNs, $1;
                #$Self->{SerialNumber} = $1;
                #last LINE;
            }
        }
    }

	my $MultiSN = join(', ', @MultiSNs);
	
    # we need to have found an serial number to proceed.
    if ( !@MultiSNs ) {
        $Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
            Value         => "Could not find serial number => Ignoring",
        );
        return 1;
    }
    else {
        $Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
            Value         => "Found mention serial number ($MultiSN) in body",
        );
    }
	
	my $ConfigItemObject = $Kernel::OM->Get('Kernel::System::ITSMConfigItem');
	
	#search serial number in whole cmdb
	my $ConfigItemIDs = $ConfigItemObject->ConfigItemSearchExtended(
		What => [                                               
			# each array element is a and condition
			{
				# or condition in hash
				"[%]{'SerialNumber'}[%]{'Content'}" => [ @MultiSNs ],
			},
		], 
		PreviousVersionSearch => 0,
		UsingWildcards => 0,
	);
	
	#if not found at all.
	if ( !@{$ConfigItemIDs} ) {
        $Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
            Value         => "Could not find config item by serial number ($MultiSN)..Ignoring",
        );
        return 1;
    }
	
	# get configured dynamic field
	my %ConfiguredDynamicField = %{ $Param{JobConfig}->{DynamicField} };
	
	my $DynamicFieldObject = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

	my $FoundDF = {};
	my $DropdownCounter = 0;
	
	for my $ConfigItemID ( @{$ConfigItemIDs})
	{
		my $ConfigItem = $ConfigItemObject->ConfigItemGet(
			ConfigItemID => $ConfigItemID,
			Cache        => 0,    # (optional) default 1 (0|1)
		);
		
		my $ConfigItemDynamicField = 0;
		
		#get target dynamic field for each found config item
		foreach my $DynamicField ( keys %ConfiguredDynamicField )
		{
			next if $ConfiguredDynamicField{$DynamicField} ne $ConfigItem->{Class};
			$ConfigItemDynamicField = $DynamicField;
			last;
		}
		
		#if found config item not within dynamic field configuration
		if ( !$ConfigItemDynamicField )
		{
			$Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
            Value         => "No dynamic field is set for this Config Item Class $ConfigItem->{Class} in the configuration..skipping",
			);
			
			next;
		}
		
		#check dynamic field validity
		my $DynamicFieldConfig = $DynamicFieldObject->DynamicFieldGet(
			Name => $ConfigItemDynamicField,
		);
		
		#if configured dynamic field name invalid / not found
		if ( !$DynamicFieldConfig->{Name} )
		{
			$Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
            Value         => "Configured dynamic field $ConfigItemDynamicField not found in the system",
			);
			
			next;
		}
		
		#dropdown dynamic field config item only support single value.
		#record counter
		if ( $DynamicFieldConfig->{FieldType} eq 'ConfigItemDropdown' )
		{
			$DropdownCounter++;
		}
		
		#dropdown counter more than 1, ignore this value.
		#accept single value only.
		if ( $DynamicFieldConfig->{FieldType} eq 'ConfigItemDropdown' && $DropdownCounter > 1 )
		{
			$Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::Filter::'.$Self->{FilterName},
            Value         => "Configured dynamic field $DynamicFieldConfig->{Name} is a dropdown. Expected field is multiselect..skipping multiple assignment",
			);
			
			next;
		}
		
		$FoundDF->{$ConfigItemDynamicField}->{FieldType} = $DynamicFieldConfig->{FieldType};
		push @{$FoundDF->{$ConfigItemDynamicField}->{ConfigItem}} , $ConfigItemID;
		#$Param{GetParam}->{'X-OTRS-DynamicField-'.$ConfigItemDynamicField}  = $ConfigItemID;
		
	}  
	
	if ( $FoundDF )
	{
		foreach my $Header ( keys %{$FoundDF} )
		{
			if ( $FoundDF->{$Header}->{FieldType} eq 'ConfigItemDropdown' )
			{
				$Param{GetParam}->{'X-OTRS-DynamicField-'.$Header}  = $FoundDF->{$Header}->{ConfigItem}[0];
			}
			elsif ( $FoundDF->{$Header}->{FieldType} eq 'ConfigItemMultiselect' )
			{
				$Param{GetParam}->{'X-OTRS-DynamicField-'.$Header}  = [ @{$FoundDF->{$Header}->{ConfigItem}} ];
			}
			else
			{
				next;
			}
		}
	}
	
	return 1;

}

1;