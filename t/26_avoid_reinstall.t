use strict;
use FindBin;
use Test::More;
use Config;
use Cwd qw/cwd/;
use File::Temp qw/tempdir/;

use App::MechaCPAN;
require q[t/helper.pm];

my $pwd = cwd;
my $dist = 'Try::Tiny';
my $dir = tempdir( TEMPLATE => "$pwd/mechacpan_t_XXXXXXXX", CLEANUP => 1 );

chdir $dir;
is(App::MechaCPAN::main('install', $dist), 0, "Can install $dist");

{
  no strict 'refs';
  my $ran_configure = 0;
  local *App::MechaCPAN::Install::_configure = sub { $ran_configure = 1 };
  is(App::MechaCPAN::main('install', $dist), 0, "Can rerun install $dist");
  is($ran_configure, 0, "Did not actually reininstall $dist");
}

done_testing;
