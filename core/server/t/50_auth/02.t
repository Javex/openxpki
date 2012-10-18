use strict;
use warnings;
use English;
use Test::More;
BEGIN { plan tests => 2 };

print STDERR "OpenXPKI::Server::Authentication\n" if $ENV{VERBOSE};

use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Server::Init;
use OpenXPKI::Server::Session;
use OpenXPKI::Server::Authentication;
ok(1);


## create context

## init XML cache
OpenXPKI::Server::Init::init(
    {	
	TASKS => [
	    'config_test',     
        'log',
        'dbi_backend',        
    ],
	SILENT => 1,
    });

## load authentication configuration
ok(OpenXPKI::Server::Authentication->new ());

1;
