use strict;
use FindBin;
use File::Copy;
use Test::More;
use Cwd qw/cwd/;
use File::Temp qw/tempdir/;

use App::MechaCPAN;
require q[t/helper.pm];

my $pwd = cwd;
my $cpanfile      = "$FindBin::Bin/../test_dists/DeploySnapshot/cpanfile";

my $dir = tempdir( TEMPLATE => "$pwd/mechacpan_t_XXXXXXXX", CLEANUP => 1 );
chdir $dir;

is(App::MechaCPAN::main('deploy', $cpanfile), 0, "Can run deploy");
is(cwd, $dir, 'Returned to whence it started');
ok(-d "$dir/local_t/lib/perl5/", 'Created local lib');

my $lib = 'Try/Tiny.pm';
ok( -e "$dir/local_t/lib/perl5/$lib", "Library file $lib exists" );

require_ok("$dir/local_t/lib/perl5/$lib");
is($Try::Tiny::VERSION, '0.24', "The correct version was installed");

done_testing;
