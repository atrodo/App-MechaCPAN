package App::MechaCPAN::Install;

use v5.12;

use Config;
use Cwd qw/cwd/;
use File::Spec qw//;
use CPAN::Meta qw//;
use ExtUtils::MakeMaker qw//;
use App::MechaCPAN qw/:go/;

our @args = (
  'jobs=i',
  'skip-tests!',
  'instal-man!'
);

our $dest_dir;
my %installed;

sub go
{
  my $class = shift;
  my $opts  = shift;
  my $src   = shift // '.';
  my @argv  = shift;

  my $orig_dir = cwd;

  local $dest_dir = "$orig_dir/local_t/";
  %installed = ();

  my @srcs = ($src);
  my %src_names;
  my @deps;

  while ( my $src = shift @srcs )
  {
    # resolve
    my $src_name = _resolve($src);

    next
        if exists $src_names{$src_name} || exists $installed{$src_name};

    $src_names{$src_name} = 1;

    # fetch
    my $src_tz  = _get_targz($src_name);
    my $src_dir = inflate_archive($src_tz);

    chdir $src_dir;

    my @files = glob('*');
    if (@files == 1)
    {
      chdir $files[0];
    }

    #configure
    my ($meta) = map { -r $_ && CPAN::Meta->load_file($_) } qw/META.json META.yml/;

    die "Cannot find META file"
      if !defined $meta;

    my $dep = _configure($meta);

    #if ( defined $dep )
    #{
    #  push @deps, $dep;
    #}
    push @deps, $dep;
    push @srcs, @{ $dep->{deps} };
  }

  #install
  foreach my $dep ( @deps )
  {
    _install($dep);
  }

  chdir $orig_dir;

  return 0;
}

sub _resolve
{
  return shift;
}

sub _get_targz
{
  my $src = shift;

  if ( -e $src )
  {
    return $src;
  }

  die "Cannot find $src\n";
}

sub _configure
{
  my $meta = shift;

  printf "testing requirements for %s version %s\n", $meta->name,
      $meta->version;

  my $config_deps = [ _prereq( $meta, 'configure' ) ];
  die 'TODO: configure prereqs'
      if @$config_deps > 0;

  my @deps;

  for my $phase (qw/runtime build test/)
  {
    push @deps, _prereq( $meta, $phase );
  }

  # trick AutoInstall
  local $ENV{PERL5_CPAN_IS_RUNNING}     = $$;
  local $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;

  local $ENV{PERL_MM_USE_DEFAULT} = 1;

  #local $ENV{PERL_MM_OPT}         = $ENV{PERL_MM_OPT};
  #local $ENV{PERL_MB_OPT}         = $ENV{PERL_MB_OPT};

  local $ENV{PERL_MM_OPT} = "INSTALL_BASE=$dest_dir";
  local $ENV{PERL_MB_OPT} = "--installbase $dest_dir";

  # skip man page generation
  local $ENV{PERL_MM_OPT} .= join(" ", "INSTALLMAN1DIR=none", "INSTALLMAN3DIR=none");
  local $ENV{PERL_MB_OPT} .= join(" ", "--config installman1dir=", "--config installsiteman1dir=", "--config installman3dir=", "--config installsiteman3dir=");

  #if ( $self->{pure_perl} )
  #{
  #  $ENV{PERL_MM_OPT} .= " PUREPERL_ONLY=1";
  #  $ENV{PERL_MB_OPT} .= " --pureperl-only";
  #}

  state $mb_deps = [ map { $_ => 1 }
        qw/version ExtUtils-ParseXS ExtUtils-Install ExtUtilsManifest/ ];

  my $maker;

  if ( -e 'Build.PL' && !exists $mb_deps->{ $meta->name } )
  {
    run( $^X, 'Build.PL' );
    my $configured = -e -f 'Build';
    die 'Unable to configure Buid.PL'
        unless $configured;
    $maker = 'mb';
  }

  if ( !defined $maker && -e 'Makefile.PL' )
  {
    run( $^X, 'Makefile.PL' );
    my $configured = -e 'Makefile';
    die 'Unable to configure Makefile.PL'
        unless $configured;
    $maker = 'mm';
  }

  die 'Unable to configure'
    if !defined $maker;

  return {
    maker => $maker,
    meta => $meta,
    dir => cwd,
    config_dep => $config_deps,
    deps => \@deps,
  };
  die;
}

sub _prereq
{
  my $meta = shift;
  my $phase = shift;
  my $prereqs = $meta->effective_prereqs;
  my @result;

  say "Requirements for $phase:";
  my $reqs = $prereqs->requirements_for( $phase, "requires" );
  for my $module ( sort $reqs->required_modules )
  {
    my $status = 'missing';
    my $version = _get_mod_ver($module);
    if ( defined $version )
    {
      $version = $module eq 'perl' ? $] : $version;
      $status
          = $reqs->accepts_module( $module, $version )
          ? "$version ok"
          : "$version not ok";
    }
    say "  $module ($status)";

    push @result, $module
      if !defined $version;
  }

  return @result;
}

sub _get_mod_ver
{
  my $module = shift;
  return $]
      if $module eq 'perl';
  my $ver = eval {
    my $file = _installed_file_for_module($module);
    MM->parse_version($file);
  };

  undef $@;
  return $ver;
}

sub _installed_file_for_module
{
  my $prereq = shift;
  my $file   = "$prereq.pm";
  $file =~ s{::}{/}g;

  for my $dir (@Config{qw(privlibexp archlibexp)}, $dest_dir)
  {
    my $tmp = File::Spec->catfile( $dir, $file );
    return $tmp
      if -r $tmp;
  }
}

sub _install
{
  my $dep = shift;

  local $ENV{PERL_MM_USE_DEFAULT} = 0;
  local $ENV{NONINTERACTIVE_TESTING} = 0;

  chdir $dep->{dir};

  state $make;

  if (!defined $make)
  {
    $make = $Config{make};
  }

  if ($dep->{maker} eq 'mb')
  {
    run($^X, './Build');
    run($^X, './Build', 'test');
    run($^X, './Build', 'install');
    _write_meta($dep);
    return;
  }

  if ($dep->{maker} eq 'mm')
  {
    run($make);
    run($make, 'test');
    run($make, 'install');
    _write_meta($dep);
    return;
  }

  die 'Unable to determine how to install ' . $dep->{meta}->name;
}

sub _write_meta
{
}

1;
