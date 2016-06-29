use strict;
use FindBin;
use Test::More;
use App::MechaCPAN;

is(App::MechaCPAN::main('install', "$FindBin::Bin/JSON-PP-2.27400.tar.gz"), 0, 'Can install a package from a tar.gz');

done_testing;
