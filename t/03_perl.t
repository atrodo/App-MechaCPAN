use strict;
use FindBin;
use Test::More;
use App::MechaCPAN;

is(App::MechaCPAN::main('perl', "$FindBin::Bin/perl-5.12.0.tar.bz2"), 0, 'Can install a perl from a tar.gz');

done_testing;
