use strict;
use FindBin;
use Test::More;
use File::Copy qw/copy/;
use File::Spec;
use File::Temp qw/tempdir/;
use Cwd qw/cwd/;
use autodie qw/:default copy/;

require q[./t/helper.pm];

my $src_tarball = "$FindBin::Bin/../test_dists/FakePerl-5.12.0.tar.gz";

my $pwd = cwd;

# Ensure that inflate_archive can handle paths with shell-meaningful characters
my @tricky_names = (
  'arch w space.tar.gz',
  q{arch's name.tar.gz},
  q{arch "name".tar.gz},
);

for my $name (@tricky_names)
{
  subtest "inflate_archive handles: `$name`" => sub
  {
    my $tmpdir = tempdir(
      TEMPLATE => File::Spec->tmpdir . "/mecha_inflate_XXXXXXXX",
      CLEANUP  => 1,
    );

    my $copied = File::Spec->catfile( $tmpdir, $name );
    copy( $src_tarball, $copied );

    my $dest = File::Spec->catdir( $tmpdir, 'extract' );
    mkdir $dest;

    chdir $tmpdir;
    local $@;
    my $result = eval { App::MechaCPAN::inflate_archive( $copied, $dest ) };
    my $err    = $@;
    chdir $pwd;

    warn $err
      if $err;

    is( $err, '', 'inflate_archive did not die' );
    isnt( $result, undef, 'inflate_archive returned something' );
    is( -d $result, 1, 'inflate_archive returned a directory' );
  };
}

done_testing;
