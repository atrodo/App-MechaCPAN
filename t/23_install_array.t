use strict;
use FindBin;
use Test::More;
use Config;
use Cwd qw/cwd/;
use File::Temp qw/tempdir/;

use App::MechaCPAN;
require q[t/helper.pm];

my $pwd  = cwd;
my %pkgs = (
  'Try::Tiny'  => 'Try/Tiny.pm',
  'Test::More' => 'Test/More.pm',
);

chdir $pwd;
my $dir = tempdir( TEMPLATE => "$pwd/mechacpan_t_XXXXXXXX", CLEANUP => 1 );
chdir $dir;

is(
  App::MechaCPAN::Install->go( {}, keys %pkgs ), 0,
  "Can install from an array"
);
is( cwd, $dir, 'Returned to whence it started' );

foreach my $file ( values %pkgs )
{
  ok( -e "$dir/local_t/lib/perl5/$file", "Library file $file exists" );
}

chdir $pwd;
done_testing;
