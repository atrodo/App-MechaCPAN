package App::MechaCPAN::Install;

use v5.12;

use Config;
use Cwd qw/cwd/;
use JSON::PP qw//;
use File::Spec qw//;
use File::Path qw//;
use File::Temp qw/tempdir tempfile/;
use CPAN::Meta qw//;
use CPAN::Meta::Prereqs qw//;
use File::Fetch qw//;
use ExtUtils::MakeMaker qw//;
use App::MechaCPAN qw/:go/;

our @args = (
  'jobs=i',
  'skip-tests!',
  'install-man!',
  'source=s%',
);

our $dest_lib;

# Constants
my $COMPLETE = 'COMPLETE';

sub go
{
  my $class = shift;
  my $opts  = shift;
  my $src   = shift // '.';
  my @srcs  = @_;

  my $orig_dir = cwd;

  local $dest_dir = "$orig_dir/local_t/";
  local $dest_lib = "$dest_dir/lib/perl5";

  my @targets = ($src, @srcs);
  my %src_names;
  my @deps;

  if (ref $opts->{source} ne 'HASH')
  {
    $opts->{source} = {};
  }

  # trick AutoInstall
  local $ENV{PERL5_CPAN_IS_RUNNING}     = $$;
  local $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;

  local $ENV{PERL_MM_USE_DEFAULT} = 1;

  local $ENV{PERL_MM_OPT} = "INSTALL_BASE=$dest_dir";
  local $ENV{PERL_MB_OPT} = "--install_base $dest_dir";

  local $ENV{PERL5LIB} = "$dest_lib";

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

  my $cache       = {};
  my @full_states = (
    'Resolving'             => \&_resolve,
    'Configuring'           => \&_meta,
    'Configuring'           => \&_config_prereq,
    'Configuring'           => \&_configure,
    'Configuring'           => \&_mymeta,
    'Finding Prerequisites' => \&_prereq,
    'Installing'            => \&_install,
    'Installed'             => \&_write_meta,
  );

  my @states     = grep { ref $_ eq 'CODE' } @full_states;
  my @state_desc = grep { ref $_ ne 'CODE' } @full_states;

  foreach my $target ( @targets )
  {
    $target = _source_translate( $opts->{source}, $target );
    $target = _create_target($target);
    $target->{update} = 1;
  }

  while ( my $target = shift @targets )
  {
    $target = _source_translate( $opts->{source}, $target );
    $target = _create_target($target);

    if ( $target->{state} eq $COMPLETE )
    {
      next;
    }

    chdir $orig_dir;
    chdir $target->{dir}
        if exists $target->{dir};

    info(
      $target->{src_name},
      sprintf(
        '%-21s %s', $state_desc[ $target->{state} ], $target->{src_name}
      )
    );
    my $method = $states[ $target->{state} ];
    unshift @targets, $method->( $target, $cache );
    $target->{state}++;

    if ( $target->{state} eq scalar @states )
    {
      _complete($target);
    }
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
  my $src_tgz = _get_targz($target);

  # Verify we need to install it
  if ( defined $target->{module} )
  {
    my $module = $target->{module};
    my $ver    = _get_mod_ver($module);

      if ($target->{version} eq $ver)
      {
        info( $target->{src_name},
          sprintf( '%-21s %s', 'Up to date', $target->{src_name} ) );
        _complete($target);
        return;
      }

    if ( defined $ver && !$target->{update})
    {
      my $constraint = $target->{constraint};
      my $prereq     = CPAN::Meta::Prereqs->new(
        { runtime => { requires => { $module => $constraint // 0 } } } );
      my $req = $prereq->requirements_for( 'runtime', 'requires' );

      if ( $req->accepts_module( $module, $ver ) )
      {
        info( $target->{src_name},
          sprintf( '%-21s %s', 'Up to date', $target->{src_name} ) );
        _complete($target);
        return;
      }
    }
  }

  my $src_dir = inflate_archive($src_tgz);

  my @files = glob( $src_dir . '/*' );
  if ( @files == 1 )
  {
    $src_dir = $files[0];
  }

  @{$target}{qw/src_tgz dir/} = ( $src_tgz, $src_dir );
  return $target;
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

  return $target
      if !defined $meta;

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

  # meta may not be defined, so wrap it in an eval
  my $is_mb_dep = eval { exists $mb_deps->{ $meta->name } };
  my $maker;

  if ( -e 'Build.PL' && !$is_mb_dep )
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
  my $target = shift;
  my $cache = shift;

  local $ENV{PERL_MM_USE_DEFAULT}    = 0;
  local $ENV{NONINTERACTIVE_TESTING} = 0;

  state $make;

  if ( !defined $make )
  {
    $make = $Config{make};
  }

  if ( $target->{maker} eq 'mb' )
  {
    run( $^X, './Build' );
    run( $^X, './Build', 'test' );
    run( $^X, './Build', 'install' );
    return $target;
  }

  if ( $target->{maker} eq 'mm' )
  {
    run($make);
    run( $make, 'test' );
    run( $make, 'install' );
    return $target;
  }

  die 'Unable to determine how to install ' . $target->{meta}->name;
}

sub _write_meta
{
  my $target = shift;
  my $cache  = shift;

  state $arch_dir = "$Config{archname}/.meta/";

  if ( $target->{is_cpan} )
  {
    my $dir = "$dest_lib/$arch_dir/" . $target->{distvname};
    File::Path::mkpath( $dir, 0, 0777 );
    $target->{meta}->save("$dir/MYMETA.json");

    my $install = {
      name     => $target->{meta}->name,
      version  => $target->{meta}->version,
      dist     => $target->{distvname},
      pathname => $target->{pathname},
      provides => $target->{meta}->provides,
    };

    open my $fh, ">", "$dir/install.json";
    print $fh JSON::PP::encode_json($install);
  }
  return;
}

my $git_re = qr[
  ^ (?: git | ssh ) :
  |
  [.]git (?: @|$ )
]xmsi;

my $url_re = qr[
  ^
  (?: ftp | http | https | file )
  : //
]xmsi;

my $full_pause_re = qr[
  (?: authors/id/ )
  (   \w / \w\w /)

  ( \w{2,} )
  /
  ( [^/]+ )
]xms;
my $pause_re = qr[
  ^

  (?: authors/id/ )?
  (?: \w / \w\w /)?

  ( \w{2,} )
  /
  ( [^/]+ )

  $
]xms;

sub _escape
{
  my $str = shift;
  $str =~ s/ ([^A-Za-z0-9\-\._~]) / sprintf("%%%02X", ord($1)) /xmsge;
  return $str;
}

sub _create_target
{
  my $target = shift;

  if ( ref $target eq '' )
  {
    # $target = { state => 0, src_name => $target, };
    if ( $target =~ m{^ ([^/]+) @ (.*) $}xms )
    {
      $target = [ $1, "==$2" ];
    }
    else
    {
      $target = [ split /[~]/xms, $target, 2 ];
    }
  }

  if ( ref $target eq 'ARRAY' )
  {
    $target = {
      state      => 0,
      src_name   => $target->[0],
      constraint => $target->[1],
    };
  }

  return $target;
}

sub _get_targz
{
  my $target = _create_target(shift);

  my $src = $target->{src_name};

  if ( -e -f $src )
  {
    return $src;
  }

  my $url;

  # git
  if ( $src =~ $git_re )
  {
    my ( $git_url, $commit ) = $src =~ m/^ (.*?) (?: @ ([^@]*) )? $/xms;

    my $dir
        = tempdir( TEMPLATE => File::Spec->tmpdir . '/mechacpan_XXXXXXXX' );
    my ( $fh, $file ) = tempfile(
      TEMPLATE => File::Spec->tmpdir . '/mechacpan_tar.gz_XXXXXXXX',
      CLEANUP  => 1
    );

    run( 'git', 'clone', '--bare', $git_url, $dir );
    run( $fh, 'git', 'archive', '--format=tar.gz', "--remote=$dir",
      $commit || 'master' );
    close $fh;
    return $file;
  }

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

    $target->{is_cpan} = 1;
  }

  # Module Name
  if ( !defined $url )
  {
    # TODO mirrors
    my $dnld = 'https://api-v1.metacpan.org/download_url/' . _escape($src);
    if ( defined $target->{constraint} )
    {
      $dnld .= '?version=' . _escape( $target->{constraint} );
    }

    local $File::Fetch::WARN;
    my $ff = File::Fetch->new( uri => $dnld );
    $ff->scheme('http')
        if $ff->scheme eq 'https';
    my $json_info = '';
    my $where = $ff->fetch( to => \$json_info );

    die "Could not find module $src on metacpan"
        if !defined $where;

    my $json_data = JSON::PP::decode_json($json_info);

    $url = $json_data->{download_url};

    $target->{is_cpan} = 1;
    $target->{module}  = "$src";
    $target->{version} = version->parse($json_data->{version});
  }

  if ( defined $url )
  {
    # if it's pause like, parse out the distibution's version name
    if ( $url =~ $full_pause_re )
    {
      my $package = $3;
      $target->{pathname} = "$1/$2/$3";
      $package =~ s/ (.*) [.] ( tar[.](gz|z|bz2) | zip | tgz) $/$1/xmsi;
      $target->{distvname} = $package;
    }

    local $File::Fetch::WARN;
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
  local $@;
  my $ver = eval {
    my $file = _installed_file_for_module($module);
    MM->parse_version($file);
  };

  return $ver;
}

sub _load_meta
{
  my $target = shift;
  my $cache  = shift;
  my $my     = shift;

  my $prefix = $my ? 'MYMETA' : 'META';

  my $meta;

  foreach my $file ( "$prefix.json", "$prefix.yml" )
  {
    $meta = eval { CPAN::Meta->load_file($file) };
    last
        if defined $meta;
  }


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
    my $status;

    my $version = _get_mod_ver($module);
    if ( defined $version )
    {
      $version = $module eq 'perl' ? $] : $version;
      $status = $reqs->accepts_module( $module, $version );
    }


    push @result, $module
        if !$status;
  }

  return @result;
}

sub _installed_file_for_module
{
  my $prereq = shift;
  my $file   = "$prereq.pm";
  $file =~ s{::}{/}g;

  my $archname = $Config{archname};
  my $perlver  = $Config{version};

  for my $dir (
    "$dest_lib/$perlver/$archname",
    "$dest_lib/$perlver",
    "$dest_lib/$archname",
    "$dest_lib",
    @Config{qw(archlibexp privlibexp)},
      )
  {
    my $tmp = File::Spec->catfile( $dir, $file );
    return $tmp
        if -r $tmp;
  }
}

sub _source_translate
{
  my $sources = shift;
  my $src = shift;

  if (ref $src eq 'HASH' && exists $src->{state})
  {
    return $src;
  }

  my $src_name = $src;
  if (ref $src eq 'ARRAY')
  {
    $src_name = $src->[0];
  }

  if (ref $src eq 'HASH')
  {
    $src_name = $src->{src_name};
  }

  my $new_src = $sources->{$src_name};

  return defined $new_src ? $new_src : $src;
}

sub _complete
{
  my $target = shift;
  $target->{state} = $COMPLETE;
  return;
}

1;
