#!/usr/bin/perl
#
# 045_activity_tools.t
#
# Tests misc workflow tools like WFObject, etc.
#
# Note: these tests are non-destructive. They create their own instance
# of the tools workflow, which is exclusively for such test purposes.

use strict;
use warnings;

use lib qw(
  /usr/lib/perl5/ 
  ../../lib
);

use Carp;
use English;
use Data::Dumper;
use Config::Std;
use File::Basename;

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);

use OpenXPKI::Test::More;
use TestCfg;

my $dirname = dirname($0);

our @cfgpath = ( $dirname );
our %cfg = ();

my $testcfg = new TestCfg;
$testcfg->read_config_path( '9x_nice.cfg', \%cfg, @cfgpath );

my $test = OpenXPKI::Test::More->new(
    {
        socketfile => $cfg{instance}{socketfile},
        realm => $cfg{instance}{realm},
    }
) or die "Error creating new test instance: $@";

$test->set_verbose($cfg{instance}{verbose});

$test->plan( tests => 13 );

$test->connect_ok(
    user => $cfg{user}{name},
    password => $cfg{user}{role},
) or die "Error - connect failed: $@";

my $serializer = OpenXPKI::Serialization::Simple->new();

my $sSubject = sprintf "nicetest-%01x.openxpki.test", rand(10000000);
my $sAlternateSubject = sprintf "nicetest-%01x.openxpki.test", rand(10000000);

my %cert_subject_parts = (
	cert_subject_hostname => $sSubject,
	cert_subject_port => 0,
);

my %cert_info = (
	requestor_gname => "Andreas",
	requestor_name => "Anders",
);

my %cert_subject_alt_name_parts = (
    'cert_subject_alt_name_choice_key' => ['DNS','DNS'],
    'cert_subject_alt_name_choice_value' => [$sAlternateSubject,'www.'.$sAlternateSubject],
    'cert_subject_alt_name_oid_key' => [],
    'cert_subject_alt_name_oid_value' => []
); 

my %wfparam = (	
	cert_role => $cfg{csr}{role},
	cert_profile => $cfg{csr}{profile},
	cert_subject_style => "00_tls_basic_style",
	cert_subject_parts => $serializer->serialize( \%cert_subject_parts ),
	cert_subject_alt_name_parts => $serializer->serialize( { %cert_subject_alt_name_parts } ),
	cert_info => $serializer->serialize( \%cert_info ),
	csr_type => "pkcs10",
);



	
print "CSR Subject: $sSubject\n";
	
$test->create_ok( 'I18N_OPENXPKI_WF_TYPE_CERTIFICATE_SIGNING_REQUEST' , \%wfparam, 'Create Issue Test Workflow')
 or die "Workflow Create failed: $@";

$test->state_is('SERVER_KEY_GENERATION');

# Trigger key generation
my $param_serializer = OpenXPKI::Serialization::Simple->new({SEPARATOR => "-"});

$test->execute_ok( 'generate_key', {
	_key_type => "RSA",
    _key_gen_params => $param_serializer->serialize( { KEY_LENGTH => 2048, ENC_ALG => "aes128" } ),
    _password => "m4#bDf7m3abd" } ) or die "Error - keygen failed: $@";
 	 	

$test->state_is('PENDING');

# ACL Test - should not be allowed to user 
$test->execute_nok( 'I18N_OPENXPKI_WF_ACTION_CHANGE_CSR_ROLE', {  cert_role => $cfg{csr}{role}}, 'Disallow change role' );

$test->disconnect();
 
# Re-login with Operator for approval
$test->connect_ok(
    user => $cfg{operator}{name},
    password => $cfg{operator}{role},
) or die "Error - connect failed: $@";

$test->execute_ok( 'I18N_OPENXPKI_WF_ACTION_CHANGE_CSR_ROLE', {  cert_role => $cfg{csr}{role}} );

$test->execute_ok( 'I18N_OPENXPKI_WF_ACTION_APPROVE_CSR' );

$test->state_is('APPROVAL');

$test->execute_ok( 'I18N_OPENXPKI_WF_ACTION_PERSIST_CSR' );

$test->param_like( 'cert_subject', "/^CN=$sSubject,.*/" , 'Certificate Subject');

$test->state_is('SUCCESS');

open(CERT, ">$cfg{instance}{buffer}");
print CERT $serializer->serialize({ cert_identifier => $test->param( 'cert_identifier' ) }); 
close CERT; 

