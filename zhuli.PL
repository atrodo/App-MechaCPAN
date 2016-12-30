#!/usr/bin/env perl

use strict;
use warnings;

use 5.010000;

use autodie;
use FindBin;
use Pod::Simple;
use File::Find;

open my $ouFH, '>', $ARGV[0];
my $prefix = "$FindBin::Bin/lib/";
my @files;
find(
  {
    wanted => sub
    {
      my $file = $_;
      if ( -f $file && $file =~ m/^[^.] .* [.]pm/xms )
      {
        warn "Will include '$file' in '$ARGV[0]'\n";
        my $filename = $File::Find::name;
        $filename =~ s[^$prefix][]xms;
        push @files, $filename;
        $ouFH->say("BEGIN { \$INC{'$filename'} = __FILE__ };");
      }
    },
  },
  $prefix
);

my $parser = Pod::Simple->new;

foreach my $file (@files)
{
  $parser->code_handler(
    sub
    {
      my $line        = shift;
      my $line_number = shift;
      my $parser      = shift;
      $ouFH->say($line)
        unless $line =~ m/^__END__/xms;
    }
  );
  $parser->parse_file("$prefix/$file");
}