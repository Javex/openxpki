# OpenXPKI::Server::Workflow::Activity::DataExchange::PrepareEnv.pm
# Written by Michael Bell for the OpenXPKI project 2006
# Copyright (c) 2006 by The OpenXPKI Project

package OpenXPKI::Server::Workflow::Activity::DataExchange::PrepareEnv;

use strict;
use warnings;
use English;
use base qw( OpenXPKI::Server::Workflow::Activity OpenXPKI::FileUtils );

## FIXME: why does the inheritance from Activity does not work?
use OpenXPKI::Server::Context qw( CTX );
use Workflow::Exception qw( workflow_error );

sub execute
{
    my $self = shift;
    my $workflow = shift;

    ## set needed informations
    my $context = $workflow->context();

    ## device
    if (defined $self->param ('device'))
    {
        $context->param('device' => $self->param('device'));
    } else {
        $context->param('device' => '/dev/fd0');
    }

    ## dirs of dataexchange
    $context->param ('local_export_dir' => CTX('config')->get('system.server.data_exchange.export') );
    $context->param ('local_import_dir' => CTX('config')->get('system.server.data_exchange.import') );

    ## name of archive and export directory
    my $filename = CTX('config')->get('system.server.tmpdir');
    $context->param ('archive_directory' => $self->get_safe_tmpdir ({TMP => $filename}));
    $context->param ('tmpdir'  => $self->get_safe_tmpdir ({TMP => $filename}));
    $context->param ('archive_filename' => "export.tar.gz");

    ## who am I
    $context->param ('who_am_i' => CTX('config')->get('system.server.node.id') );
                
}

1;
__END__

=head1 Name

OpenXPKI::Server::Workflow::Activity::DataExchange::PrepareEnv

=head1 Description

This activity prepares the environment for an export. The only accepted parameter
is device where you can specify a device which should be used during the export
of the archive.

