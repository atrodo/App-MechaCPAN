package App::MechaCPAN::Install;

use v5.12;

use Config;
use Cwd qw/cwd/;
use JSON::PP qw//;
use File::Spec qw//;
use CPAN::Meta qw//;
use File::Fetch qw//;
use ExtUtils::MakeMaker qw//;
use App::MechaCPAN qw/:go/;

our @args = (
  'jobs=i',
  'skip-tests!',
  'instal-man!'
);

our $dest_dir;

sub go
{
  my $class = shift;
  my $opts  = shift;
  my $src   = shift // '.';
  my @argv  = shift;

  my $orig_dir = cwd;

  local $dest_dir = "$orig_dir/local_t/";

  my @srcs = ($src);
  my %src_names;
  my @deps;

  # trick AutoInstall
  local $ENV{PERL5_CPAN_IS_RUNNING}     = $$;
  local $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;

  local $ENV{PERL_MM_USE_DEFAULT} = 1;

  local $ENV{PERL_MM_OPT} = "INSTALL_BASE=$dest_dir";
  local $ENV{PERL_MB_OPT} = "--install_base $dest_dir";

  local $ENV{PERL5LIB} = "$dest_dir";

  # skip man page generation
  $ENV{PERL_MM_OPT}
      .= " " . join( " ", "INSTALLMAN1DIR=none", "INSTALLMAN3DIR=none" );
  $ENV{PERL_MB_OPT} .= " " . join(
    " ",                            "--config installman1dir=",
    "--config installsiteman1dir=", "--config installman3dir=",
    "--config installsiteman3dir="
  );

  #if ( $self->{pure_perl} )
  #{
  #  $ENV{PERL_MM_OPT} .= " PUREPERL_ONLY=1";
  #  $ENV{PERL_MB_OPT} .= " --pureperl-only";
  #}

  my @targets = ($src);
  my $cache   = {};
  my @states  = (
    \&_resolve,
    \&_meta,
    \&_config_prereq,
    \&_configure,
    \&_mymeta,
    \&_prereq,
    \&_install
  );

  while ( my $target = shift @targets )
  {
    if ( ref $target eq '' )
    {
      $target = { state => 0, src_name => $target, };
    }

    chdir $orig_dir;
    chdir $target->{dir}
        if exists $target->{dir};

    my $method = $states[ $target->{state} ];
    unshift @targets, $method->( $target, $cache );
    $target->{state}++;
  }

  chdir $orig_dir;

  return 0;
}

sub _resolve
{
  my $target = shift;
  my $cache  = shift;

  my $src_name = $target->{src_name};

  return
      if exists $cache->{src_names}->{$src_name};

  $cache->{src_names}->{$src_name} = 1;

  # fetch
  my $src_tgz = _get_targz($src_name);
  my $src_dir = inflate_archive($src_tgz);

  my @files = glob( $src_dir . '/*' );
  if ( @files == 1 )
  {
    $src_dir = $files[0];
  }

  @{$target}{qw/src_tgz dir/} = ( $src_tgz, $src_dir );
  return $target;
  return {
    src_name => $src_name,
    src_tgz  => $src_tgz,
    dir      => $src_dir,
  };
}

sub _meta
{
  my $target = shift;
  my $cache  = shift;

  $target->{meta} = _load_meta( $target, $cache, 0 );
  return $target;
}

sub _config_prereq
{
  my $target = shift;
  my $cache  = shift;

  my $meta = $target->{meta};

  #printf "testing requirements for %s version %s\n", $meta->name,
  #    $meta->version;

  my @config_deps = _phase_prereq( $target, $cache, 'configure' );

  $target->{configure_prereq} = [@config_deps];

  return @config_deps, $target;
}

sub _configure
{
  my $target = shift;
  my $cache  = shift;
  my $meta   = $target->{meta};

  state $mb_deps = { map { $_ => 1 }
        qw/version ExtUtils-ParseXS ExtUtils-Install ExtUtilsManifest/ };

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

  $target->{maker} = $maker;
  return $target;
}

sub _mymeta
{
  my $target = shift;
  my $cache  = shift;

  $target->{meta} = _load_meta( $target, $cache, 1 );
  return $target;
}

sub _prereq
{
  my $target = shift;
  my $cache  = shift;

  my $meta = $target->{meta};

  #printf "testing requirements for %s version %s\n", $meta->name,
  #    $meta->version;

  my @deps
      = map { _phase_prereq( $target, $cache, $_ ) } qw/runtime build test/;

  $target->{prereq} = [@deps];

  return @deps, $target;
}

sub _install
{
  my $dep = shift;

  local $ENV{PERL_MM_USE_DEFAULT}    = 0;
  local $ENV{NONINTERACTIVE_TESTING} = 0;

  chdir $dep->{dir};

  state $make;

  if ( !defined $make )
  {
    $make = $Config{make};
  }

  if ( $dep->{maker} eq 'mb' )
  {
    run( $^X, './Build' );
    run( $^X, './Build', 'test' );
    run( $^X, './Build', 'install' );
    _write_meta($dep);
    return;
  }

  if ( $dep->{maker} eq 'mm' )
  {
    run($make);
    run( $make, 'test' );
    run( $make, 'install' );
    _write_meta($dep);
    return;
  }

  die 'Unable to determine how to install ' . $dep->{meta}->name;
}

my $url_re = qr[
  ^
  (?: ftp | http | https | file )
  :
]xmsi;

my $pause_re = qr[
  ^
  (?: authors/id/ )?
  (?: \w / \w\w /)?

  ( \w{2,} )
  /
  ( .* )

  $
]xms;

sub _escape
{
  my $str = shift;
  $str =~ s/ ([^A-Za-z0-9\-\._~]) / sprintf("%%%02X", ord($1)) /xmsge;
  return $str;
}

sub _get_targz
{
  my $src = shift;

  if ( -e -f $src )
  {
    return $src;
  }

  my $url;

  # git
  # URL

  if ( $src =~ $url_re )
  {
    $url = $src;
  }

  # PAUSE

  if ( $src =~ $pause_re )
  {
    my $author  = $1;
    my $package = $2;
    $url = join(
      '/',
      'https://cpan.metacpan.org/authors/id',
      substr( $author, 0, 1 ),
      substr( $author, 0, 2 ),
      $author,
      $package,
    );
  }

  # Module Name
  if ( !defined $url )
  {
    # TODO mirrors
    my $dnld = 'https://api-v1.metacpan.org/download_url/' . _escape($src);
    my $ff = File::Fetch->new( uri => $dnld );
    $ff->scheme('http')
        if $ff->scheme eq 'https';
    my $json_info = '';
    my $where = $ff->fetch( to => \$json_info );

    die "Could not find module $src on metacpan"
        if !defined $where;

    $url = JSON::PP::decode_json($json_info)->{download_url};
  }

  if ( defined $url )
  {
    my $ff = File::Fetch->new( uri => $url );
    $ff->scheme('http')
        if $ff->scheme eq 'https';
    my $where = $ff->fetch( to => $dest_dir );
    die $ff->error || "Could not download $url"
        if !defined $where;

    return $where;
  }

  die "Cannot find $src\n";
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

sub _load_meta
{
  my $target = shift;
  my $cache  = shift;
  my $my     = shift;

  my $prefix = $my ? 'MYMETA' : 'META';

  my ($meta)
      = map { CPAN::Meta->load_file($_) }
      grep {-r} ( "$prefix.json", "$prefix.yml" );

  die "Cannot find $prefix file for " . $target->{src_name}
      if !defined $meta;

  return $meta;
}

sub _phase_prereq
{
  my $target = shift;
  my $cache  = shift;
  my $phase  = shift;

  my $prereqs = $target->{meta}->effective_prereqs;
  my @result;

  #say "  Requirements for $phase:";
  my $reqs = $prereqs->requirements_for( $phase, "requires" );
  for my $module ( sort $reqs->required_modules )
  {
    my $status  = 'missing';
    my $version = _get_mod_ver($module);
    if ( defined $version )
    {
      $version = $module eq 'perl' ? $] : $version;
      $status
          = $reqs->accepts_module( $module, $version )
          ? "$version ok"
          : "$version not ok";
    }

    #say "    $module ($status)";

    push @result, $module
        if !defined $version;
  }

  return @result;
}

sub _installed_file_for_module
{
  my $prereq = shift;
  my $file   = "$prereq.pm";
  $file =~ s{::}{/}g;

  for my $dir ( @Config{qw(privlibexp archlibexp)}, $dest_dir )
  {
    my $tmp = File::Spec->catfile( $dir, $file );
    return $tmp
        if -r $tmp;
  }
}

sub _write_meta
{
}

1;
