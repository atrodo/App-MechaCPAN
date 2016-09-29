package App::MechaCPAN::Perl;

use strict;
use Config;
use Cwd qw/cwd/;
use File::Fetch qw//;
use App::MechaCPAN qw/:go/;

our @args = (
  'threads!',
  'jobs=i',
  'skip-tests!',
);

sub go
{
  my $class = shift;
  my $opts  = shift;
  my $src   = shift;
  my @argv  = shift;

  my $orig_dir = cwd;

  my $src_tz  = _get_targz($src);
  my $src_dir = inflate_archive($src_tz);
  my $dest_dir = "$orig_dir/local/perl";

  chdir $src_dir;

  if (!-e 'Configure')
  {
    my @files = glob('*');
    if (@files > 1)
    {
      die 'Could not find perl to configure';
    }
    chdir $files[0];
  }

  my @config = ('-des', "-Dprefix=$dest_dir", "-A'eval:scriptdir=$dest_dir'", );
  my @make = "make", "-j" . $opts->{jobs} // 2;

  delete @ENV{qw(PERL5LIB PERL5OPT)};

  # Make sure no tomfoolery is happening with perl, like plenv shims
  $ENV{PATH} = $Config{binexp} . ":$ENV{PATH}";

  eval {
    require Devel::PatchPerl;
    info 'Patching perl';
    Devel::PatchPerl->patch_source();
  };

  info 'Building perl';
  run qw[sh Configure], @config;
  run @make;
  run @make, 'test_harness'
    unless $opts->{'skip-tests'};
  run @make, 'install';

  chdir $orig_dir;

  return 0;
}

my $perl5_re = qr/^ 5 [.] (\d{1,2}) (?: [.] (\d{1,2}) )? $/xms;

sub _get_targz
{
  my $src = shift;

  # file

  if (-e $src)
  {
    return $src;
  }

  my $url;
  local $File::Fetch::WARN;

  # git
  # URL
  if ( $src =~ url_re )
  {
    return $src;
  }

  # CPAN
  if ($src =~ $perl5_re)
  {
    my $version = $1;
    my $minor   = $2;

    my $mirror = 'http://www.cpan.org/src/5.0';

    # They probably want the latest if minor wasn't given
    if (!defined $minor)
    {
      # 11 is the highest minor version seen as of this writing
      my @possible = ( 0 .. 15 );

      while (@possible > 1)
      {
        my $i = int(@possible / 2);
        $minor = $possible[$i];
        my $dnld = "$mirror/perl-5.$version.$minor.tar.bz2.md5.txt";
        my $ff = File::Fetch->new( uri => $dnld );
        my $contents = '';
        my $where = $ff->fetch( to => \$contents );

        if (defined $where)
        {
          # The version exists, which means it's higher still
          @possible = @possible[ $i .. $#possible ];
        }
        else
        {
          # The version doesn't exit. That means higher versions don't either
          @possible = @possible[ 0 .. $i-1 ];
        }
      }
    }

    return "$mirror/perl-5.$version.$minor.tar.bz2";
  }

  die "Cannot find $src\n";
}

1;
