package App::MechaCPAN::Deploy;

use strict;
use warnings;
use autodie;
use Carp;
use CPAN::Meta;
use List::Util qw/reduce/;
use App::MechaCPAN;

our @args = (
  'skip-perl!',
);

sub go
{
  my $class = shift;
  my $opts  = shift;
  my $src   = shift || '.';

  my $file = $src;

  if ( -d $file )
  {
    $file = "$file/cpanfile";
  }

  if ( !-e $file )
  {
    croak "Could not find cpanfile ($file)";
  }

  if ( !-f $file )
  {
    croak "cpanfile must be a regular file";
  }

  my $prereq = parse_cpanfile($file);
  my @phases = qw/configure build test runtime/;

  my @acc = map {%$_} map { values %{ $prereq->{$_} } } @phases;
  my @reqs;
  while (@acc)
  {
    push @reqs, [ splice( @acc, 0, 2 ) ];
  }

  if ( -f "$file.snapshot")
  {
    my $snapshot_info = parse_snapshot("$file.snapshot");
    my %srcs;
    foreach my $dist ( values %$snapshot_info )
    {
      my $src = $dist->{pathname};
      foreach my $provide ( keys %{ $dist->{provides} })
      {
        if (exists $srcs{$provide})
        {
          die "Found dumplicate distributions ($src and $srcs{$provide}) that provides the same module ($provide)\n";
        }
        $srcs{$provide} = $src;
      }
    }

    if (ref  $opts->{source} eq 'HASH')
    {
      %srcs = ( %srcs, %{ $opts->{source} } );
    }
    $opts->{source} = \%srcs;
    $opts->{'only-sources'} = 1;
  }

  if (!$opts->{'skip-perl'})
  {
    $result = App::MechaCPAN::Perl->go( $opts );
    return $result if $result;
  }

  return App::MechaCPAN::Install->go( $opts, @reqs );
}

my $sandbox_num = 1;

sub parse_cpanfile
{
  my $file = shift;

  my $result = { runtime => {} };

  $result->{current} = $result->{runtime};

  my $methods = {
    on => sub
    {
      my ( $phase, $code ) = @_;
      local $result->{current} = $result->{$phase} //= {};
      $code->();
    },
    feature => sub {...},
  };

  foreach my $type (qw/requires recommends suggests conflicts/)
  {
    $methods->{$type} = sub
    {
      my ( $module, $ver ) = @_;
      if ( $module eq 'perl' )
      {
        $result->{perl} = $ver;
        return;
      }
      $result->{current}->{$type}->{$module} = $ver;
    };
  }

  open my $code_fh, '<', $file;
  my $code = do { local $/; <$code_fh> };

  my $pkg = __PACKAGE__ . "::Sandbox$sandbox_num";
  $sandbox_num++;

  foreach my $method ( keys %$methods )
  {
    no strict 'refs';
    *{"${pkg}::${method}"} = $methods->{$method};
  }

  local $@;
  my $sandbox = join(
    "\n",
    qq[package $pkg;],
    qq[no warnings;],
    qq[# line 1 "$file"],
    qq[$code],
    qq[return 1;],
  );

  my $no_error = eval $sandbox;

  croak $@
      unless $no_error;

  delete $result->{current};

  return $result;
}

my $snapshot_re = qr/^\# carton snapshot format: version 1\.0/;
sub parse_snapshot
{
  my $file = shift;

  my $result = {};

  open my $snap_fh, '<', $file;

  if (my $line = <$snap_fh> !~ $snapshot_re)
  {
    die "File doesn't looks like a carton snapshot: $file";
  }

  my @stack = ($result);
  my $prefix = '';
  while (my $line = <$snap_fh>)
  {
    chomp $line;

    if ($line =~ m/^ \Q$prefix\E (\S+?) :? $/xms)
    {
      my $new_depth = {};
      $stack[0]->{$1} = $new_depth;
      unshift @stack, $new_depth;
      $prefix = '  ' x $#stack;
      next;
    }

    if ($line =~ m/^ \Q$prefix\E (\S+?) (?: :? \s (.*) )? $/xms)
    {
      $stack[0]->{$1} = $2;
      next;
    }

    if ($line !~ m/^ \Q$prefix\E /xms)
    {
      shift @stack;
      $prefix = '  ' x $#stack;
      redo;
    }

    die "Unable to parse snapshot (line $.)\n";
  }

  return $result->{DISTRIBUTIONS};
}

1;
