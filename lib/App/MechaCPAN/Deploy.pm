package App::MechaCPAN::Deploy;

use strict;
use warnings;
use autodie;
use Carp;
use CPAN::Meta;
use List::Util qw/reduce/;
use App::MechaCPAN;

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
    croak "Could not find cpanfile";
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
  use Data::Dumper;
}

1;
