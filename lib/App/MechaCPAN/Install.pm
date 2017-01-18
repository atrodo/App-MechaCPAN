package App::MechaCPAN::Install;

use v5.14;

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
  'skip-tests!',
  'skip-tests-for:s@',
  'install-man!',
  'source=s%',
  'only-sources!',
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
  my $dest_dir = &dest_dir;

  local $dest_lib = "$dest_dir/lib/perl5";

  my @targets = ( $src, @srcs );
  my %src_names;
  my @deps;

  if ( ref $opts->{source} ne 'HASH' )
  {
    $opts->{source} = {};
  }

  if ( ref $opts->{'skip-tests-for'} ne 'ARRAY' )
  {
    $opts->{'skip-tests-for'} = [];
  }
  $opts->{'skip-tests-for'}
    = { map { $_ => 1 } @{ $opts->{'skip-tests-for'} } };

  # trick AutoInstall
  local $ENV{PERL5_CPAN_IS_RUNNING}     = $$;
  local $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;

  local $ENV{PERL_MM_USE_DEFAULT} = 1;

  local $ENV{PERL_MM_OPT} = "INSTALL_BASE=$dest_dir";
  local $ENV{PERL_MB_OPT} = "--install_base $dest_dir";

  local $ENV{PERL5LIB} = "$dest_lib";

  # skip man page generation
  if ( !$opts->{'install-man'} )
  {
    $ENV{PERL_MM_OPT}
      .= " " . join( " ", "INSTALLMAN1DIR=none", "INSTALLMAN3DIR=none" );
    $ENV{PERL_MB_OPT} .= " " . join(
      " ",                            "--config installman1dir=",
      "--config installsiteman1dir=", "--config installman3dir=",
      "--config installsiteman3dir="
    );
  }

  #if ( $self->{pure_perl} )
  #{
  #  $ENV{PERL_MM_OPT} .= " PUREPERL_ONLY=1";
  #  $ENV{PERL_MB_OPT} .= " --pureperl-only";
  #}

  my $cache = { opts => $opts };
  my @full_states = (
    'Resolving'     => \&_resolve,
    'Configuring'   => \&_meta,
    'Configuring'   => \&_config_prereq,
    'Configuring'   => \&_configure,
    'Configuring'   => \&_mymeta,
    'Prerequisites' => \&_prereq,
    'Installing'    => \&_install,
    'Installed'     => \&_write_meta,
  );

  my @states     = grep { ref $_ eq 'CODE' } @full_states;
  my @state_desc = grep { ref $_ ne 'CODE' } @full_states;

  foreach my $target (@targets)
  {
    $target = _source_translate( $target, $opts );
    $target = _create_target( $target, $cache );
    $target->{update} = 1;
  }

  while ( my $target = shift @targets )
  {
    $target = _source_translate( $target, $opts );
    $target = _create_target( $target, $cache );

    if ( $target->{state} eq $COMPLETE )
    {
      next;
    }

    chdir $orig_dir;
    chdir $target->{dir}
      if exists $target->{dir};

    my $line = sprintf(
      '%-13s %s', $state_desc[ $target->{state} ],
      $target->{src_name}
    );
    info( $target->{src_name}, $line );
    my $method = $states[ $target->{state} ];
    unshift @targets, $method->( $target, $cache );
    $target->{state}++;

    if ( $target->{state} eq scalar @states )
    {
      _complete($target);
      success( $target->{src_name}, $line );
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

  # fetch
  my $src_tgz = _get_targz($target);

  # Verify we need to install it
  if ( defined $target->{module} )
  {
    my $module = $target->{module};
    my $ver    = _get_mod_ver($module);

    if ( defined $ver && $target->{version} eq $ver )
    {
      success(
        $target->{src_name},
        sprintf( '%-13s %s', 'Up to date', $target->{src_name} )
      );
      _complete($target);
      return;
    }

    if ( defined $ver && !$target->{update} )
    {
      my $constraint = $target->{constraint};
      my $prereq     = CPAN::Meta::Prereqs->new(
        { runtime => { requires => { $module => $constraint // 0 } } } );
      my $req = $prereq->requirements_for( 'runtime', 'requires' );

      if ( $req->accepts_module( $module, $ver ) )
      {
        success(
          $target->{src_name},
          sprintf( '%-13s %s', 'Up to date', $target->{src_name} )
        );
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
  my $cache  = shift;

  local $ENV{PERL_MM_USE_DEFAULT}    = 0;
  local $ENV{NONINTERACTIVE_TESTING} = 0;

  state $make;
  my $opts = $cache->{opts};

  if ( !defined $make )
  {
    $make = $Config{make};
  }

  my $skip_tests = $cache->{opts}->{'skip-tests'};
  if ( !$skip_tests )
  {
    my $skips = $opts->{'skip-tests-for'};
    $skip_tests = exists $skips->{ $target->{src_name} };

    if ( !$skip_tests && defined $target->{module} )
    {
      $skip_tests = $skips->{ $target->{module} };
    }
  }

  if ( $target->{maker} eq 'mb' )
  {
    run( $^X, './Build' );
    run( $^X, './Build', 'test' )
      unless $skip_tests;
    run( $^X, './Build', 'install' );
    return $target;
  }

  if ( $target->{maker} eq 'mm' )
  {
    run($make);
    run( $make, 'test' )
      unless $skip_tests;
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
  my $cache  = shift;

  return $target
    if ref $target eq 'HASH';

  if ( ref $target eq '' )
  {
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

  if ( exists $cache->{targets}->{ $target->{src_name} } )
  {
    $target = $cache->{targets}->{ $target->{src_name} };
  }

  $cache->{targets}->{ $target->{src_name} } = $target;

  return $target;
}

sub _get_targz
{
  my $target = shift;

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
    run(
      $fh, 'git', 'archive', '--format=tar.gz', "--remote=$dir",
      $commit || 'master'
    );
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
    $target->{version} = version->parse( $json_data->{version} );
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
    my $dest_dir = dest_dir() . "/pkgs";

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
  my $target = shift;
  my $opts   = shift;

  my $sources = $opts->{source};

  if ( ref $target eq 'HASH' && exists $target->{state} )
  {
    return $target;
  }

  my $src_name = $target;
  if ( ref $target eq 'ARRAY' )
  {
    $src_name = $target->[0];
  }

  if ( ref $target eq 'HASH' )
  {
    $src_name = $target->{src_name};
  }

  my $new_src = $sources->{$src_name};

  if ( $opts->{'only-sources'} )
  {
    die "Unable to locate $src_name from the sources list\n"
      if !$new_src;
    return $new_src;
  }

  return defined $new_src ? $new_src : $target;
}

sub _complete
{
  my $target = shift;
  $target->{state} = $COMPLETE;
  return;
}

1;
__END__

=encoding utf-8

=head1 NAME

App::MechaCPAN::Install - Mechanize the installation of CPAN modules.

=head1 SYNOPSIS

  # Install Catalyst into local/
  user@host:~$ mechacpan install Catalyst

=head1 DESCRIPTION

  user@host:~$ mechacpan install Catalyst

The C<install> command is used for installing specific modules. All modules are installed into the C<local/> directory.
It can accept module names in various formats. This includes:

                                         # Install from:
  foo-bar.tar.gz                         # * an archive
  foo::bar                               # * a CPAN module
  foo::bar@1.0                           # * a specific module version
  foo::bar~<1.0                          # * a module with version < 1.0
  BAZ/foo-bar.tar.gz                     # * a PAUSE URL
  B/BA/BAZ/foo-bar.tar.gz                # * a PAUSE URL
  https://example.com/foo-bar.zip        # * a URL
  https://example.com/foo-bar.git        # * a git repo
  https://example.com/foo-bar.git@master # * a git branch

L<MetaCPAN|https://metacpan.org> is used to search for modules by name.

=head2 Methods

=head3 go( \%opts, @srcs )

There is only a single public function that should be called. This will install the modules listed in C<@srcs> using the options in C<\%opts>. The options available are listed in the L<arguments|/Arguments> section below.

  # Example of calling go
  App::MecahCPAN::Install->go({}, 'Try::Tiny');

=head2 Arguments

=head3 skip-tests

=head3 skip-tests-for

By default the tests of each module will be ran. If you do not want to run tests when installing modules, use this option. Alternatively, you can use C<skip-tests-for> to specify module names that will skip the tests for that module.

  # Examples of --skip-tests
  mechacpan install Try::Tiny --skip-tests
  mechacpan install Catalyst --skip-tests-for=Moose

=head3 install-man

By default, man pages are not installed. Use this option to install the man pages.

=head3 source

Add a source translation to the installation. This can be used to translate a module name into another form, like using an exact version of a module or pull another module from its git repo. This can be repeated multiple times for multiple translations.

  # Examples of --source
  mechacpan install Catalyst --source Try::Tiny=ETHER/Try-Tiny-0.24
  mechacpan install Catalyst --source Catalyst=git://git.shadowcat.co.uk/catagits/Catalyst-Runtime.git

=head3 only-sources

Do not use modules not listed in the source list. This means if you do not specify every module and every prerequisite in the source list, then it will not be installed. This doesn't sound very useful since you would be potentially listing hundreds of modules. However, this feature is mostly used in conjuncture with L<App::MechaCPAN::Deploy> so that the modules listed in the C<cpanfile.snapshot> are the only module versions used.

=head1 AUTHOR

Jon Gentle E<lt>cpan@atrodo.orgE<gt>

=head1 COPYRIGHT

Copyright 2017- Jon Gentle

=head1 LICENSE

This is free software. You may redistribute copies of it under the terms of the Artistic License 2 as published by The Perl Foundation.

=head1 SEE ALSO

=over

=item L<App::cpanminus>

=item L<CPAN>

=back

=cut
