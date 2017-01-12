package App::MechaCPAN;

use v5.14;
use strict;
use Cwd qw/cwd/;
use Carp;
use Config;
use Symbol qw/geniosym/;
use autodie;
use Term::ANSIColor qw//;
use IPC::Open3;
use IO::Select;
use List::Util qw/first/;
use File::Temp qw/tempfile tempdir/;
use File::Spec qw//;
use Archive::Tar;
use Getopt::Long qw//;

use Exporter qw/import/;

BEGIN
{
  our @EXPORT_OK
    = qw/url_re info success dest_dir inflate_archive run restart_script/;
  our %EXPORT_TAGS = ( go => [@EXPORT_OK] );
}

require App::MechaCPAN::Perl;
require App::MechaCPAN::Install;
require App::MechaCPAN::Deploy;

my $loaded_at_compile;
my $restarted_key        = 'APP_MECHACPAN_RESTARTED';
my $is_restarted_process = delete $ENV{$restarted_key};
INIT
{
  $loaded_at_compile = 1;
  &restart_script();
}

$loaded_at_compile //= 0;
our $VERSION = '0.10';

my @args = (
  'diag-run!',
  @App::MechaCPAN::Perl::args,
  @App::MechaCPAN::Install::args,
  @App::MechaCPAN::Deploy::args,
  'verbose|v!',
  'quiet|q!',
  'no-log!',
);
@args = keys %{ { map { $_ => 1 } @args } };

our $VERBOSE;    # Print output from sub commands to STDERR
our $QUIET;      # Do not print any progress to STDERR
our $LOGFH;      # File handle to send the logs to
our $LOG_ON = 1; # Default if to log or not

sub main
{
  my @argv = @_;

  my $options = {};
  my $getopt_ret
    = Getopt::Long::GetOptionsFromArray( \@argv, $options, @args );
  return -1
    if !$getopt_ret;

  my $orig_dir = cwd;
  my $dest_dir = &dest_dir;
  my $cmd      = ucfirst lc shift @argv;
  my $pkg      = join( '::', __PACKAGE__, $cmd );
  my $action   = eval { $pkg->can('go') };

  if ( !defined $action )
  {
    warn "Could not find action to run: $cmd\n";
    return -1;
  }

  if ( ref $argv[0] eq 'HASH' )
  {
    $options = shift @argv;
  }

  if ( $options->{'diag-run'} )
  {
    warn "Would run '$cmd'\n";
    return 0;
  }

  $options->{is_restarted_process} = $is_restarted_process;

  if ( !-d $dest_dir )
  {
    mkdir $dest_dir;
  }

  unless ( $options->{'no-log'} )
  {
    my $log_dir = "$dest_dir/logs";
    if ( !-d $log_dir )
    {
      mkdir $log_dir;
    }

    my $log_path;
    ( $LOGFH, $log_path ) = tempfile( "$log_dir/log.$$.XXXX", UNLINK => 0 );
  }

  my $ret = eval { $pkg->$action( $options, @argv ) || 0; };
  chdir $orig_dir;

  if ( !defined $ret )
  {
    warn $@;
    return -1;
  }

  return $ret;
}

sub url_re
{
  state $url_re = qr[
    ^
    (?: ftp | http | https | file )
    :
  ]xmsi;
  return $url_re;
}

sub info
{
  my $key  = shift;
  my $line = shift;

  if ( !defined $line )
  {
    $line = $key;
    undef $key;
  }

  status( $key, 'YELLOW', $line );
}

sub success
{
  my $key  = shift;
  my $line = shift;

  if ( !defined $line )
  {
    $line = $key;
    undef $key;
  }

  status( $key, 'GREEN', $line );
}

my $RESET = Term::ANSIColor::color('RESET');
my $BOLD  = Term::ANSIColor::color('BOLD');

sub _show_line
{
  my $key   = shift;
  my $color = shift;
  my $line  = shift;

  # Clean up the line
  $line =~ s/\n/ /xmsg;

  state @key_lines;

  my $idx = first { $key_lines[$_] eq $key } 0 .. $#key_lines;

  if ( !defined $key )
  {
    $idx = -1;
  }

  if ( !defined $idx )
  {
    unshift @key_lines, $key;
    $idx = 0;

    # Scroll Up 1 line
    print STDERR "\n";
  }
  $idx++;

  # We use some ANSI escape codes, so they are:
  # \e[.F  - Move up from current line, which is always the end of the list
  # \e[K   - Clear the line
  # $color - Colorize the text
  # $line  - Print the text
  # $RESET - Reset the colorize
  # \e[.E  - Move down from the current line, back to the end of the list
  print STDERR "\e[${idx}F";
  print STDERR "\e[K";
  print STDERR "$color$line$RESET";
  print STDERR "\e[${idx}E";

  return;
}

sub status
{
  my $key   = shift;
  my $color = shift;
  my $line  = shift;

  if ( !defined $line )
  {
    $line  = $color;
    $color = 'RESET';
  }

  return
    if $QUIET;

  $color = eval { Term::ANSIColor::color($color) } // $RESET;

  state @last_key;

  # Undo the last line that is bold
  if (@last_key)
  {
    _show_line(@last_key);
  }

  _show_line( $key, $color . $BOLD, $line );

  @last_key = ( $key, $color, $line );
}
END  { print STDERR "\n" unless $QUIET; }
INIT { print STDERR "\n" unless $QUIET; }

package MechaCPAN::DestGuard
{
  use Cwd qw/cwd/;
  use Scalar::Util qw/refaddr weaken/;
  use overload '""' => sub { my $s = shift; return $$s }, fallback => 1;
  my $dest_dir;

  sub get
  {
    my $result = $dest_dir;
    if ( !defined $result )
    {
      my $pwd = cwd;
      $dest_dir = \"$pwd/local";
      bless $dest_dir;
      $result = $dest_dir;
      weaken $dest_dir;
    }
    return $dest_dir;
  }

  sub DESTROY
  {
    undef $dest_dir;
  }
}

sub dest_dir
{
  my $result = MechaCPAN::DestGuard::get();
  return $result;
}

sub inflate_archive
{
  my $src = shift;

  # $src can be a file path or a URL.
  if ( !-e $src )
  {
    local $File::Fetch::WARN;
    my $ff = File::Fetch->new( uri => $src );
    $ff->scheme('http')
      if $ff->scheme eq 'https';
    my $content = '';
    my $where = $ff->fetch( to => \$content );
    die $ff->error || "Could not download $src"
      if !defined $where;
    $src = $where;
  }

  my $dir = tempdir(
    TEMPLATE => File::Spec->tmpdir . '/mechacpan_XXXXXXXX',
    CLEANUP  => 1
  );
  my $orig = cwd;

  my $error_free = eval {
    chdir $dir;
    my $tar = Archive::Tar->new;
    $tar->error(1);
    my $ret = $tar->read( "$src", 1, { extract => 1 } );
    die $tar->error
      unless $ret;
    1;
  };
  my $err = $@;

  chdir $orig;

  die $err
    unless $error_free;

  return $dir;
}

sub run
{
  my $cmd  = shift;
  my @args = @_;

  my $out = "";
  my $err = "";

  my $dest_out_fh  = $LOGFH;
  my $dest_err_fh  = $LOGFH;
  my $print_output = $VERBOSE;

  if ( ref $cmd eq 'GLOB' )
  {
    $dest_out_fh = $cmd;
    $cmd         = shift @args;
  }

  # If the output is asked for (non-void context), don't show it anywhere
  if ( defined wantarray )
  {
    undef $print_output;
    open $dest_out_fh, ">", \$out;
    open $dest_err_fh, ">", \$err;
  }

  my $output = geniosym;
  my $error  = geniosym;

  $output->blocking(0);
  $error->blocking(0);

  warn( join( "\t", $cmd, @args ) . "\n" )
    if $VERBOSE;

  print $dest_err_fh ( 'Running: ', join( "\t", $cmd, @args ) . "\n")
    if defined $dest_err_fh;

  my $pid = open3( undef, $output, $error, $cmd, @args );

  my $select = IO::Select->new;

  $select->add( $output, $error );

  while ( my @ready = $select->can_read )
  {
    foreach my $fh (@ready)
    {
      my $line = <$fh>;

      #warn "reading $fh";
      #my $ret = $fh->read($line, 2048) ;
      #warn $ret;
      if ( !defined $line )
      {
        $select->remove($fh);
        next;
      }

      print STDERR $line if $print_output;

      if ( $fh eq $output && defined $dest_out_fh )
      {
        print $dest_out_fh $line;
      }

      if ( $fh eq $error && defined $dest_err_fh )
      {
        print $dest_err_fh $line;
      }

    }
  }

  waitpid( $pid, 0 );

  if ( $? >> 8 )
  {
    croak qq/\e[32m$out\e[31m$err\nCould not execute '/
      . join( ' ', $cmd, @args )
      . qq/'.\e[0m\n/;
  }

  return
    if !defined wantarray;

  if (wantarray)
  {
    return split( /\r?\n/, $out );
  }

  return $out;
}

sub restart_script
{
  my $dest_dir   = &dest_dir;
  my $local_perl = File::Spec->canonpath("$dest_dir/perl/bin/perl");
  my $this_perl  = File::Spec->canonpath($^X);
  if ( $^O ne 'VMS' )
  {
    $this_perl .= $Config{_exe}
      unless $this_perl =~ m/$Config{_exe}$/i;
    $local_perl .= $Config{_exe}
      unless $local_perl =~ m/$Config{_exe}$/i;
  }

  state $orig_cwd = cwd;
  state $orig_0   = $0;

  my $current_cwd = cwd;
  chdir $orig_cwd;

  if (
    $loaded_at_compile              # IF we were loaded during compile-time
    && -e -x $local_perl            # AND the local perl is there
    && $this_perl ne $local_perl    # AND if we're not running it
    && -e -f -r $0                  # AND we are a readable file
    && !$^P                         # AND we're not debugging
    )
  {
    # ReExecute using the local perl
    my @inc_add;
    my @paths = qw/
      sitearchexp sitelibexp
      vendorarchexp vendorlibexp
      archlibexp privlibexp
      otherlibdirsexp
      /;
    my %site_inc = map { $_ => 1 } @Config{@paths}, '.';

    foreach my $lib ( split ':', $ENV{PERL5LIB} )
    {
      $site_inc{$lib} = 1;
      $site_inc{"$lib/$Config{archname}"} = 1;
    }

    foreach my $lib (@INC)
    {
      push( @inc_add, $lib )
        unless exists $site_inc{$lib};
    }

    # Make sure anything from PERL5LIB and local::lib are removed since it's
    # most likely the wrong version as well.
    @inc_add = grep { $_ !~ m/^$ENV{PERL_LOCAL_LIB_ROOT}/xms } @inc_add;
    undef @ENV{qw/PERL_LOCAL_LIB_ROOT PERL5LIB/};

    # If we've running, inform the new us that they are a restarted process
    $ENV{$restarted_key} = 1
      if ${^GLOBAL_PHASE} eq 'RUN';

    # Cleanup any files opened already. They arn't useful after we exec
    File::Temp::cleanup();

    exec( $local_perl, map( {"-I$_"} @inc_add ), $0, @ARGV );
  }

  chdir $current_cwd;
}

1;
__END__

=encoding utf-8

=head1 NAME

App::MechaCPAN - Mechanize the installation of CPAN things.

=head1 SYNOPSIS

  # Install 5.24 into local/
  user@host:~$ zhuli perl 5.24
  
  # Install Catalyst into local/
  user@host:~$ zhuli install Catalyst
  
  # Install everything from the cpanfile into local/
  # If cpanfile.snapshot exists, it will be consulted first
  user@host:~$ zhuli install
  
  # Install perl and everything from the cpanfile into local/
  # If cpanfile.snapshot exists, it will be consulted exclusivly
  user@host:~$ zhuli deploy
  user@host:~$ zhuli do the thing

=head1 DESCRIPTION

App::MechaCPAN Mechanizes the installation of perl and CPAN modules.

=head1 AUTHOR

Jon Gentle E<lt>cpan@atrodo.orgE<gt>

=head1 COPYRIGHT

Copyright 2016- Jon Gentle

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut
