use strict;
use FindBin;
use File::Copy;
use Test::More;
use Cwd qw/cwd/;
use File::Temp qw/tempdir/;

require q[t/helper.pm];

my $pwd      = cwd;
my $cpanfile = "$FindBin::Bin/../test_dists/DeployCpanfile/cpanfile";

my $dir = tempdir( TEMPLATE => "$pwd/mechacpan_t_XXXXXXXX", CLEANUP => 1 );
chdir $dir;

is(
  App::MechaCPAN::main( 'deploy', { 'skip-perl' => 1 }, $cpanfile ), 0,
  "Can run deploy"
);
is( cwd, $dir, 'Returned to whence it started' );
ok( -d "$dir/local_t/lib/perl5/", 'Created local lib' );

foreach my $file ( 'Try/Tiny.pm', 'Test/More.pm' )
{
  ok( -e "$dir/local_t/lib/perl5/$file", "Library file $file exists" );
}

chdir $pwd;
done_testing;
