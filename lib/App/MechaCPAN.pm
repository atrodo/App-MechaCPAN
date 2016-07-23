package App::MechaCPAN;

use strict;
use Cwd qw/cwd/;
use Carp;
use Symbol qw/geniosym/;
use autodie;
use IPC::Open3;
use IO::Select;
use File::Temp qw/tempdir tempfile/;
use Archive::Tar;
use List::Util qw/uniq/;
use Getopt::Long qw//;

use Exporter qw/import/;

BEGIN
{
  our @EXPORT_OK = qw/run info inflate_archive/;
  our %EXPORT_TAGS = ( go => [@EXPORT_OK] );
}

use App::MechaCPAN::Perl;
use App::MechaCPAN::Install;
use App::MechaCPAN::Deploy;

use 5.010_000;
our $VERSION = '0.01';

my @args = uniq(
  'dry-run|n!',
  'diag-run!',
  @App::MechaCPAN::Perl::args,
  'debug|d!',
  'verbose|v!',
);

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

  if ( $options->{'diag-run'} )
  {
    warn "Would run '$cmd'\n";
    return 0;
  }

  use Data::Dumper;
  warn Data::Dumper::Dumper( $cmd, $action, \@argv );

  my $ret = eval { $pkg->$action( $options, @argv ) || 0; };

  if (!defined $ret)
  {
    warn $@;
    return -1;
  }

  return $ret;
}

sub info
{
  warn(@_);
}

sub inflate_archive
{
  my $src = shift;
  my $dir = tempdir( TEMPLATE => 'mechacpan_XXXXXXXX', CLEANUP => 0 );
  my $orig = cwd;

  my $error_free = eval
  {
    chdir $dir;
    my $tar = Archive::Tar->new;
    $tar->error(1);
    my $ret = $tar->read("$src", 1, {extract => 1});
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

  my $VERBOSE = 0;
  my $DEBUG   = 0;
  my $out     = "";
  my $err     = "";

  my $print_output = $VERBOSE || ( $DEBUG && !defined wantarray );

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
      if ( !defined $line)
      {
        $select->remove($fh);
        next;
      }

      print STDERR $line if $print_output;

      if ( $fh eq $output )
      {
        #$out .= $line;
      }

      if ( $fh eq $error )
      {
        #$err .= $line;
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

  if (wantarray)
  {
    return split( /\r?\n/, $out );
  }

  return $out;
}

1;

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
