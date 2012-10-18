use strict;
use warnings;
use English;
use Test::More;
plan tests => 7;

use OpenXPKI::Debug;
if ($ENV{DEBUG_LEVEL}) {
    $OpenXPKI::Debug::LEVEL{'.*'} = $ENV{DEBUG_LEVEL};
}

diag "OpenXPKI::Server::Log: interface of log function\n" if $ENV{VERBOSE};
use OpenXPKI::Server::Log;

`mkdir -p 't/var/openxpki/session/'`;
ok (-d 't/var/openxpki/session/');

my $filename = "t/var/openxpki/openxpki.log";
ok (!-e $filename || unlink ($filename), 'Remove old logfile if any');

my $log = OpenXPKI::Server::Log->new( CONFIG => 't/28_log/log4perl.conf' );

# Not logged 
ok (! $log->log (FACILITY => "auth",
               PRIORITY => "debug",
               MESSAGE  => "Test."), 'Test message');

ok (! -s $filename, 'Log file has zero size');

# error
eval {
    $log->log();
};
ok ($EVAL_ERROR, 'Empty log call throws error');

# loggged

ok ($log->log (FACILITY => "auth",
               PRIORITY => "info",
               MESSAGE  => "Test."), 'Test message');

ok (-s $filename, 'Log file exists and is non-empty');

1;
