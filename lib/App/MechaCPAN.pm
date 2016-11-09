package App::MechaCPAN;

use v5.12;
use strict;
use Cwd qw/cwd/;
use Carp;
use Symbol qw/geniosym/;
use autodie;
use IPC::Open3;
use IO::Select;
use File::Temp qw/tempdir/;
use File::Spec qw//;
use Archive::Tar;
use Getopt::Long qw//;

use Exporter qw/import/;

BEGIN
{
  our @EXPORT_OK = qw/run info inflate_archive url_re $dest_dir/;
  our %EXPORT_TAGS = ( go => [@EXPORT_OK] );
}

require App::MechaCPAN::Perl;
require App::MechaCPAN::Install;
require App::MechaCPAN::Deploy;

our $VERSION = '0.10';

my $orig_dir = cwd;
our $dest_dir = "$orig_dir/local_t/";

my @args = (
  'dry-run|n!',
  'diag-run!',
  @App::MechaCPAN::Perl::args,
  @App::MechaCPAN::Install::args,
  @App::MechaCPAN::Deploy::args,
  'verbose|v!',
  'quiet|q!',
  'no-log!',
);

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

  my $cmd    = ucfirst lc shift @argv;
  my $pkg    = join( '::', __PACKAGE__, $cmd );
  my $action = eval { $pkg->can('go') };

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


  my $ret = eval { $pkg->$action( $options, @argv ) || 0; };

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
  my $key = shift;
  my $line = shift // $key;

  return
    if $QUIET;

  state $last_key;

  if ( $last_key eq $key )
  {
    print STDERR "\e[0E\e[K\e[1E";
  }
  else
  {
    print STDERR "\n"
      if defined $last_key;
    $last_key = $key;
  }

  print STDERR "$line";
}
END { print STDERR "\n" unless $QUIET; }

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
