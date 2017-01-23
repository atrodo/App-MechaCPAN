use strict;
use FindBin;
use File::Copy;
use Test::More;
use Cwd qw/cwd/;

require q[t/helper.pm];

my $pwd = cwd;
foreach my $dist ( sort glob("$FindBin::Bin/../test_dists/Deploy*/") )
{
  chdir $dist;
  $dist = cwd;

  is(
    App::MechaCPAN::main( 'deploy', { 'skip-perl' => 1 } ), 0,
    "Can run deploy for $dist"
  );
  is( cwd, $dist, 'Returned to whence it started' );
  ok( -d "$dist/local/lib/perl5/", 'Created local lib' );
}

done_testing;
