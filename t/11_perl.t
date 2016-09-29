use strict;
use FindBin;
use Test::More;
use App::MechaCPAN;

is(App::MechaCPAN::main('perl', "$FindBin::Bin/../test_dists/FakePerl-5.12.0.tar.gz"), 0, 'Can install "perl" from a tar.gz');

done_testing;
