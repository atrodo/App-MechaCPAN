package App::MechaCPAN::Perl;

use strict;
use Config;
use Cwd qw/cwd/;
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

  my @config = ('-de', "-Dprefix=$dest_dir", "-A'eval:scriptdir=$dest_dir'", );
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
#  system(q[perl -pi -e 'print "set -x\n" if $.==1; $_.="\nset -x\n" if m/^\$startsh$/; ' Configure]);
  run qw[sh Configure], @config;
  run @make;

  if ( !$opts->{'skip-tests'} )
  {
    run @make, 'test_harness';
  }

  run qw/make install/;

  chdir $orig_dir;

  return 0;
}

sub _get_targz
{
  my $src = shift;

  if (-e $src)
  {
    return $src;
  }
  
  die "Cannot find $src\n";
}

1;
