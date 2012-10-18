
use strict;
use warnings;
use Test::More;
use OpenXPKI::XML::Cache;
use Time::HiRes;

BEGIN { plan tests => 4 };
print STDERR "PERFORMANCE VALIDATION\n" if $ENV{VERBOSE};
ok(1);

## create new object
my $obj = OpenXPKI::XML::Cache->new(CONFIG => "t/20_xml/test.xml");

if ($obj)
{
    ok (1);
} else {
    ok (0);
    exit;
}

my $xpath = ["config"];
my $counter = [0];
my $items = 10000;
my $begin = [ Time::HiRes::gettimeofday() ];
for (my $i=0; $i<$items; $i++)
{
    my $answer = $obj->get_xpath (COUNTER => $counter, XPATH => $xpath);
}
ok (1);
my $result = Time::HiRes::tv_interval( $begin, [Time::HiRes::gettimeofday()]);
$result = $items / $result;
$result =~ s/\..*$//;
print STDERR " - $result xpaths/second (minimum: 1000 per second)\n" if $ENV{VERBOSE};
if ($result < 1000)
{
    ok (0);
} else {
    ok(1);
}

1;
