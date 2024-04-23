package Log::Any::Simple;

use strict;
use warnings;
use utf8;

use Carp qw(croak cluck shortmess longmess);
use Data::Dumper;
use Log::Any;
use Log::Any::Adapter::Util 'logging_methods', 'numeric_level';
use Readonly;

our $VERSION = '0.01';

Readonly::Scalar my $DIE_AT_DEFAULT => numeric_level('fatal');
Readonly::Scalar my $DIE_AT_KEY => 'Log::Any::Simple/die_at';
Readonly::Scalar my $CATEGORY_KEY => 'Log::Any::Simple/category';
Readonly::Scalar my $PREFIX_KEY => 'Log::Any::Simple/prefix';
Readonly::Scalar my $DUMP_KEY => 'Log::Any::Simple/dump';

Readonly::Array my @ALL_LOG_METHODS =>
    (Log::Any::Adapter::Util::logging_methods(), Log::Any::Adapter::Util::logging_aliases);
Readonly::Hash my %ALL_LOG_METHODS => map { $_ => 1 } @ALL_LOG_METHODS;

Readonly::Array my @DEFAULT_LOG_METHODS => qw(trace debug info warn error fatal);

# The index of the %^H hash in the list returned by "caller".
Readonly::Scalar my $HINT_HASH => 10;

sub import {  ## no critic (RequireArgUnpacking)
  my (undef) = shift @_;  # This is the package being imported, so our self.

  my %to_export;

  while (defined (my $arg = shift)) {
    if ($arg eq ':default') {  ## no critic (ProhibitCascadingIfElse)
      $to_export{$_} = 1 for @DEFAULT_LOG_METHODS;
    } elsif ($arg eq ':all') {
      $to_export{$_} = 1 for @ALL_LOG_METHODS;
    } elsif (exists $ALL_LOG_METHODS{$arg}) {
      $to_export{$arg} = 1;
    } elsif ($arg eq ':die_at') {
      my $die_at = numeric_level(shift);
      croak 'Invalid :die_at level' unless defined $die_at;
      $^H{$DIE_AT_KEY} = $die_at;
    } elsif ($arg eq ':category') {
      my $category = shift;
      croak 'Invalid :category name' unless $category;
      $^H{$CATEGORY_KEY} = $category;
    } elsif ($arg eq ':prefix') {
      my $prefix = shift;
      croak 'Invalid :prefix value' unless $prefix;
      $^H{$PREFIX_KEY} = $prefix;
    } elsif ($arg eq ':dump_long') {
      $^H{$DUMP_KEY} = 'long';
    } elsif ($arg eq ':dump_short') {
      $^H{$DUMP_KEY} = 'short';
    } else {
      croak "Unknown parameter: $arg";
    }
  }

  # We export all the methods at the end, so that all the modifications to the
  # %^H hash are already done and can be used by the _export method.
  my $pkg_name = caller(0);
  _export_logger($pkg_name, \%^H) if %to_export;
  _export($_, $pkg_name, \%^H) for keys %to_export;

  @_ = 'Log::Any';
  goto &Log::Any::import;
}

# This is slightly ugly but the intent is that the user of a module using this
# module will set this variable to 1 to get full backtrace.
my $die_with_stack_trace;
my %die_with_stack_trace;

sub die_with_stack_trace {  ## no critic (RequireArgUnpacking)
  my ($category, $mode);
  if (@_ == 1) {
    ($mode) = @_;
  } elsif (@_ == 2) {
    ($category, $mode) = @_;
  } else {
    croak 'Invalid number of arguments for die_with_stack_trace(). Expecting 1 or 2, got '
        .(scalar(@_));
  }
  my @valid = qw(no none short small long full);
  my $valid_re = join('|', @valid);
  croak "Invalid mode passed to die_with_stack_trace: ${mode}"
      if defined $mode && $mode !~ m/^(?:${valid_re})$/;
  if (defined $category) {
    $die_with_stack_trace{$category} = $mode;
  } else {
    $die_with_stack_trace = $mode;
  }
  return;
}

sub _export_logger {
  my ($pkg_name, $hint_hash) = @_;
  my $category = _get_category($pkg_name, $hint_hash);
  my $logger = _get_logger($category, $hint_hash);
  no strict 'refs';  ## no critic (ProhibitNoStrict)
  *{"${pkg_name}::__log_any_simple_logger"} = \$logger;
  return;
}

sub _export {
  my ($method, $pkg_name, $hint_hash) = @_;

  my $log_method = $method.'f';
  my $sub;
  if (_should_die($method, $hint_hash)) {
    my $category = _get_category($pkg_name, $hint_hash);
    $sub = sub {
      no strict 'refs';  ## no critic (ProhibitNoStrict)
      my $logger = ${"${pkg_name}::__log_any_simple_logger"};
      _die($category, $logger->$log_method(@_));
    };
  } else {
    $sub = sub {
      no strict 'refs';  ## no critic (ProhibitNoStrict)
      my $logger = ${"${pkg_name}::__log_any_simple_logger"};
      $logger->$log_method(@_);
      return;
    };
  }
  no strict 'refs';  ## no critic (ProhibitNoStrict)
  *{"${pkg_name}::${method}"} = $sub;
  return;
}

sub _get_category {
  my ($pkg_name, $hint_hash) = @_;
  return $hint_hash->{$CATEGORY_KEY} // $pkg_name;
}

sub _get_formatter {
  my ($hint_hash) = @_;
  my $dump = ($hint_hash->{$DUMP_KEY} // 'short') eq 'short' ? \&_dump_short : \&_dump_long;
  return sub {
    my (undef, undef, $format, @args) = @_;  # First two args are the category and the numeric level.
    for (@args) {
      $_ = $_->() if ref eq 'CODE';
      $_ = '<undef>' unless defined;
      next unless ref;
      $_ = $dump->($_);
    }
    return sprintf($format, @args);
  };
}

sub _get_logger {
  my ($category, $hint_hash) = @_;
  my @args = (category => $category);
  push @args, prefix => $hint_hash->{$PREFIX_KEY} if exists $hint_hash->{$PREFIX_KEY};
  push @args, formatter => _get_formatter($hint_hash);
  return Log::Any->get_logger(@args);
}

sub _should_die {
  my ($level, $hint_hash) = @_;
  return numeric_level($level) <= ($hint_hash->{$DIE_AT_KEY} // $DIE_AT_DEFAULT);
}

# This method is meant to be called only at logging time (and not at import time
# like the methods above)
sub _die {
  my ($category, $msg) = @_;
  my $trace = $die_with_stack_trace // $die_with_stack_trace{$category} // 'short';
  if ($trace eq 'long' || $trace eq 'full') {
    $msg = longmess($msg);
  } elsif ($trace eq 'short' || $trace eq 'small') {
    $msg = shortmess($msg);
  } elsif ($trace eq 'none' || $trace eq 'no') {
    $msg .= "\n";
  } else {
    cluck 'Invalid $die_with_stack_trace mode. Should not happen';  # The mode is validated.
  }
  # The message returned by shortmess and longmess always end with a new line,
  # so it’s fine to use die here.
  die $msg;  ## no critic (ErrorHandling::RequireCarping)
}

sub _dump_short {
  my ($ref) = @_;  # Can be called on anything but intended to be called on ref.
  local $Data::Dumper::Indent = 0;
  local $Data::Dumper::Pad = '';  ## no critic (ProhibitEmptyQuotes)
  local $Data::Dumper::Terse = 1;
  local $Data::Dumper::Sortkeys = 1;
  local $Data::Dumper::Sparseseen = 1;
  local $Data::Dumper::Quotekeys = 0;
  # Consider Useqq = 1
  return Dumper($ref);
}

sub _dump_long {
  my ($ref) = @_;  # Can be called on anything but intended to be called on ref.
  local $Data::Dumper::Indent = 2;
  local $Data::Dumper::Pad = ' ' x 4;  ## no critic (ProhibitEmptyQuotes, ProhibitMagicNumbers)
  local $Data::Dumper::Terse = 1;
  local $Data::Dumper::Sortkeys = 1;
  local $Data::Dumper::Sparseseen = 1;
  local $Data::Dumper::Quotekeys = 0;
  # Consider Useqq = 1
  chop(my $s = Dumper($ref));  # guaranteed to end in a newline, and does not depend on $/
  return $s;
}

sub _get_singleton_logger {
  my ($pkg_name, $hint_hash) = @_;
  my $logger;
  {
    no strict 'refs';  ## no critic (ProhibitNoStrict)
    $logger = ${"${pkg_name}::__log_any_simple_logger"};
  }
  return $logger if defined $logger;
  my $category = _get_category($pkg_name, $hint_hash);
  $logger = _get_logger($category, $hint_hash);
  {
    no strict 'refs';  ## no critic (ProhibitNoStrict)
    *{"${pkg_name}::__log_any_simple_logger"} = \$logger;
  }
  return $logger;
}

# This blocks generates in the Log::Any::Simple namespace logging methods
# that can be called directly by the user (although the standard approach would
# be to import them in the caller’s namespace). These methods are slower because
# They need to retrieve a logger each time.
for my $name (logging_methods()) {
  no strict 'refs';  ## no critic (ProhibitNoStrict)
  *{$name} = sub {
    my @caller = caller(0);
    my $hint_hash = $caller[$HINT_HASH];
    my $logger = _get_singleton_logger($caller[0], $hint_hash);
    my $method = $name.'f';
    my $msg = $logger->$method(@_);
    _die(_get_category($caller[0], $hint_hash), $msg) if _should_die($name, $hint_hash);
  };
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

Log::Any::Simple - Very thin wrapper around Log::Any, using a functional
interface that dies automatically when you log above a given level

=head1 SYNOPSIS

  use Log::Any::Simple ':default';

  info 'Starting program...';
  debug 'Printing the output of a costly function: %s', sub { costly_data() };
  trace 'Printing structured data: %s', $ref_to_complex_data_structure;
  fatal 'Received a %s signal', $signal;

=head1 DESCRIPTION

B<Disclaimer>: L<Log::Any> is already quite simple, and our module name does not
imply otherwise. Maybe B<Log::Any::SlightlySimpler> would have been a better
name.

B<Log::Any::Simple> is offering a purely functional interface to L<Log::Any>,
removing all possible clutter. The first intent, however, was to die() when
logging at the fatal() level or above, so that the application using the module
can control how much stack trace is printed in that case.

The main features of the module, in addition to those of L<Log::Any>, are:

=over 4

=item *

Purely functional interface with no object to manipulate.

=item *

Supports dying directly from call to the log function (by default at the
B<fatal> level and above, but this can be configured).

=item *

The consumer application can control the amount of stack-trace produced when a
module dies with B<Log::Any::Simple>.

=item *

Support for lazily producing logged data.

=item *

Several formatting options for dumping data-structure.

=back

Except for that stack trace control, the usage of B<Log::Any::Simple> on the
application side (log consumer), is exactly the same as the usage of
L<Log::Any>. See L<Log::Any::Adapter> documentation, for how to consume logs in
your main application and L<Log::Any::Test> for how to test your logging
statements.

=head2 Importing

=head2 Logging

=head2 Controlling stack-traces

=head1 RESTRICTIONS

TODO: It is not possible to import the module more than once in a given package.

=head1 AUTHOR

This program has been written by L<Mathias Kende|mailto:mathias@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright 2024 Mathias Kende

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=head1 SEE ALSO

=over 4

=item *

L<Log::Any>

=back

=cut
