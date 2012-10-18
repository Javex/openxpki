use strict;
use warnings;
use Test::More;
use English;

plan tests => 15;

print STDERR "OpenXPKI::Crypto::Backend::OpenSSL::CRL\n" if $ENV{VERBOSE};

use OpenXPKI::Crypto::TokenManager;

our $cache;
our $basedir;
our $cacert;
eval `cat t/25_crypto/common.pl`;

is($EVAL_ERROR, '', 'common.pl evaluated correctly');

SKIP: {
    skip 'crypt init failed', 14 if $EVAL_ERROR;

## parameter checks for TokenManager init

my $mgmt = OpenXPKI::Crypto::TokenManager->new({'IGNORE_CHECK' => 1});
ok ($mgmt, 'Create OpenXPKI::Crypto::TokenManager instance');

my $token = $mgmt->get_token ({
   TYPE => 'certsign',
   NAME => 'test-ca',
   CERTIFICATE => {
        DATA => $cacert,
        IDENTIFIER => 'ignored',
   }
});

ok (defined $token, 'Parameter checks for get_token');


## create CRL
my $crl = OpenXPKI->read_file ("$basedir/test-ca/crl.pem");
ok(1);

## get object
$crl = $token->get_object ({DATA => $crl, TYPE => "CRL"});
ok(1);

## check that all required functions are available and work
foreach my $func ("version", "issuer", "issuer_hash", "serial",
                  "last_update", "next_update", "fingerprint", #"extensions",
                  "revoked", "signature_algorithm", "signature")
{
    ## FIXME: this is a bypass of the API !!!
    my $result = $crl->$func();
    if (defined $result)
    {
        ok(1);
        print STDERR "$func: $result\n" if ($ENV{DEBUG});
    } else {
        ok(0);
        print STDERR "Error: function $func failed\n";
    }
}

}
1;
