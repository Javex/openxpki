use strict;
use warnings;
use English;
use Test::More;
plan tests => 4;

diag "OpenXPKI::Server::Authentication::External (static role)\n" if $ENV{VERBOSE};

use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Server::Init;
use OpenXPKI::Server::Session;
use OpenXPKI::Server::Authentication;

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
my $auth = OpenXPKI::Server::Authentication::External->new('auth.handler.External Static Role');
ok($auth, 'Auth object creation');

my ($user, $role, $reply) = $auth->login_step({
    STACK   => 'External Dynamic',
    MESSAGE => {
        'SERVICE_MSG' => 'GET_PASSWD_LOGIN',
        'PARAMS'      => {
            'LOGIN'  => 'John Doe',
            'PASSWD' => 'User',
        },
    },
});

is($user, 'John Doe', 'Correct user');
is($role, 'RA Operator', 'Correct role');
is($reply->{'SERVICE_MSG'}, 'SERVICE_READY', 'Service ready.');    
1;
