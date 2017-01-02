use strict;
use FindBin;
use Test::More;
use Config;
use Cwd qw/cwd/;
use File::Temp qw/tempdir/;

use App::MechaCPAN;
require q[t/helper.pm];

my $pwd  = cwd;
my $dist = "$FindBin::Bin/../test_dists/FailTests/FailTests-1.0.tar.gz";
my $dir  = tempdir( TEMPLATE => "$pwd/mechacpan_t_XXXXXXXX", CLEANUP => 1 );

local $SIG{__WARN__} = sub {note shift};

chdir $dir;
isnt( App::MechaCPAN::main( 'install', $dist ), 0, "Fail as expected: $dist" );
is( cwd, $dir, 'Returned to whence it started' );

is( App::MechaCPAN::main( '--skip-tests', 'install', $dist ), 0, "Skipped tests: $dist" );
is( cwd, $dir, 'Returned to whence it started' );

is( App::MechaCPAN::main( '--skip-tests-for', $dist, 'install', $dist ), 0, "Skipped tests for: $dist" );
is( cwd, $dir, 'Returned to whence it started' );

chdir $pwd;
done_testing;
