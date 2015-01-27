package Test::Pretty;
use strict;
use warnings;
use 5.008001;
our $VERSION = '0.30';

use Test::Stream (
    subtest_tap => 'delayed',
    'OUT_STD',
    'OUT_ERR',
    'OUT_TODO',
);
use Test::Stream::Event::DummyTap;
use Term::Encoding ();
use File::Spec ();
use Term::ANSIColor ();
use Test::More ();
use Scope::Guard;
use Carp ();

use Cwd ();

*colored = -t STDOUT || $ENV{PERL_TEST_PRETTY_ENABLED} ? \&Term::ANSIColor::colored : sub { $_[1] };

my $ORIGINAL_PID = $$;

$ENV{TEST_PRETTY_INDENT} ||= '    ';

my $SHOW_DUMMY_TAP;
my $TERM_ENCODING = Term::Encoding::term_encoding();
my $ENCODING_IS_UTF8 = $TERM_ENCODING =~ /^utf-?8$/i;

our $NO_ENDING; # Force disable the Test::Pretty finalization process.

our $BASE_DIR = Cwd::getcwd();
my %filecache;
my $get_src_line = sub {
    my ($filename, $lineno) = @_;
    $filename = File::Spec->rel2abs($filename, $BASE_DIR);
    # read a source as utf-8... Yes. it's bad. but works for most of users.
    # I may need to remove binmode for STDOUT?
    my $lines = $filecache{$filename} ||= sub {
        # :encoding is likely to override $@
        local $@;
        open my $fh, "<:encoding(utf-8)", $filename
            or return '';
        [<$fh>]
    }->();
    return unless ref $lines eq 'ARRAY';
    my $line = $lines->[$lineno-1];
    $line =~ s/^\s+|\s+$//g;
    return $line;
};

if ((!$ENV{HARNESS_ACTIVE} || $ENV{PERL_TEST_PRETTY_ENABLED})) {
    # make pretty

    # Check if Using Stream API
    eval{ use Test::Stream };

    # If an error is found, assume Test::Stream isn't installed
    if ($@) {
       # Implement using monkey patching
       {
          no warnings 'redefine';
          *Test::Builder::subtest = \&_subtest;
          *Test::Builder::ok = \&_ok;
          *Test::Builder::done_testing = \&_done_testing;
          *Test::Builder::skip = \&_skip;
          *Test::Builder::skip_all = \&_skip_all;
          *Test::Builder::expected_tests = \&_expected_tests;
       }
       my $builder = Test::Builder->new;
       $builder->no_ending(1);
       $builder->no_header(1); # plan

       # Set encoding of File Handlers
       binmode $builder->output(), "encoding($TERM_ENCODING)";
       binmode $builder->failure_output(), "encoding($TERM_ENCODING)";
       binmode $builder->todo_output(), "encoding($TERM_ENCODING)";
    } else {
       # Use Test::Stream
       # Turn off normal TAP output
       Test::Stream->shared->set_use_tap(0);

       # Turn off legacy storage of results.
       Test::Stream->shared->set_use_legacy(0);

       Test::Stream->shared->listen(sub {
          my ($stream, $e) = @_;
          my @sets = stream_listener($stream, $e);

          # Render output
          for my $set (@sets) {
              my ($hid, $msg) = @$set;
              next unless $msg;
              my $enc = $e->encoding || die "Could not find encoding!";

              # This is how you get the proper handle to use (STDERR, STDOUT, ETC).
              my $io = $stream->io_sets->{$enc}->[$hid] || die "Could not find IO $hid for $enc";

              # Make sure we don't alter these vars.
              local($\, $", $,) = (undef, ' ', '');

              # Otherwise we get "Wide character in print" errors.
              binmode $io, "encoding($TERM_ENCODING)";
              # print to the IO
              print $io $msg;
          }
       });
    }

    if ($ENV{HARNESS_ACTIVE}) {
        $SHOW_DUMMY_TAP++;
    }
} else {
    no warnings 'redefine';
    my $ORIGINAL_ok = \&Test::Builder::ok;
    my @NAMES;

    $|++;

    my $builder = Test::Builder->new;
    binmode $builder->output(), "encoding($TERM_ENCODING)";
    binmode $builder->failure_output(), "encoding($TERM_ENCODING)";
    binmode $builder->todo_output(), "encoding($TERM_ENCODING)";

    my ($arrow_mark, $failed_mark);
    if ($ENCODING_IS_UTF8) {
        $arrow_mark = "\x{bb}";
        $failed_mark = " \x{2192} ";
    } else {
        $arrow_mark = ">>";
        $failed_mark = " x ";
    }

    *Test::Builder::subtest = sub {
        push @NAMES, $_[1];
        my $guard = Scope::Guard->new(sub {
            pop @NAMES;
        });
        $_[0]->note(colored(['cyan'], $arrow_mark x (@NAMES*2)) . " " . join(colored(['yellow'], $failed_mark), $NAMES[-1]));
        $_[2]->();
    };
    *Test::Builder::ok = sub {
        my @args = @_;
        $args[2] ||= do {
            my ( $package, $filename, $line ) = caller($Test::Builder::Level);
            "L $line: " . $get_src_line->($filename, $line);
        };
        if (@NAMES) {
            $args[2] = "(" . join( '/', @NAMES)  . ") " . $args[2];
        }
        local $Test::Builder::Level = $Test::Builder::Level + 1;
        &$ORIGINAL_ok(@_);
    };
}

Test::Stream->shared->follow_up( sub {
    my ($ctx) = @_;
    my $stream = $ctx->stream;
    my $real_exit_code = $?;

    my $called_by_done_testing = not $ctx->isa('Test::Stream::ExitMagic::Context' );

    # Don't bother with an ending if this is a forked copy.  Only the parent
    # should do the ending.
    if( $ORIGINAL_PID!= $$ ) {
        return;
    }
    if ($Test::Pretty::NO_ENDING) {
        return;
    }

    # see Test::Builder::_ending
    if( !$stream->plan and $stream->count and !$called_by_done_testing) {
        $stream->is_passing(0);
    }

    if ( $stream->plan && !( $stream->plan->directive && $stream->plan->directive eq 'NO PLAN' ) ) {
        if ($stream->count != $stream->plan->max) {
            $ctx->diag("Bad plan: " . $stream->count . " != " . $stream->plan->max);
            $stream->is_passing(0);
        }
    }

    if ($SHOW_DUMMY_TAP) {
       $ctx->dummy_tap(($?==0 && $stream->is_passing));
    }
});

sub stream_listener {
    my ($stream, $e) = @_;

    my @sets;

    if ($e->isa('Test::Stream::Event::Subtest')) {
        unless($stream->subtest_tap_delayed) {
           #return if $e->[EXCEPTION]
           #       && $e->[EXCEPTION]->isa('Test::Stream::Event::Bail');

           # Subtest is a subclass of Ok, use Ok's to_tap method:
           return ok_to_tap($e);
        }

        # Subtest final result first
        @sets = (
           [ OUT_STD, $e->name . "\n" ], # Render the subtests name
            subtest_render_events($stream, $e),
        );
    } elsif ( $e->isa('Test::Stream::Event::Ok') ) {
       @sets = ok_to_tap($e);
    } elsif ( $e->isa('Test::Stream::Event::Plan') ) {

       # IF the plan is a skip all
       if ($e->directive eq 'SKIP') {
          $SHOW_DUMMY_TAP = 0;
          @sets = ( [
                OUT_STD, "1..0 # SKIP ". $e->reason . "\n",
          ] );
       }
    } else {
       return unless $e->can('to_tap');
       @sets = $e->to_tap();
    }

    return @sets;
}

=head2 ok_to_tap

C<ok_to_tap> is the "pretty" version of Test::Stream::Event::Ok's C<to_tap>.

=cut

sub ok_to_tap {
   my $e = shift;

   my $context = $e->context;

   my ( $out, @sets );

   # If skipped, render "skip" followed by the reason why.
   if ( $e->skip ) {
      return (
         [
            OUT_STD, colored(['yellow'], 'skip') . " " . $e->skip . "\n",
         ]
      );
   }

   my $src_line;
   if (defined($context->line)) {
       $src_line = $get_src_line->($context->file, $context->line);
   } else {
      $e->add_diag(Carp::longmess("\$Test::Builder::Level is invalid. Testing library you are using is broken. : $Test::Builder::Level"));
       $src_line = '';
   }

   $src_line = ( $src_line ) ? ": ". $src_line : "";
   my $name = $e->name || "  L" . $context->line . $src_line;

   unless($e->real_bool) {
       my $fail_char = $ENCODING_IS_UTF8 ? "\x{2716}" : "x";
       $out .= colored(['red'], $fail_char);
   }
   else {
       my $success_char = $ENCODING_IS_UTF8 ? "\x{2713}" : "o";
       $out .= colored(['green'], $success_char);
   }

   # Add name
   if( defined $name ) {
       $name =~ s|#|\\#|g;    # # in a name can confuse Test::Harness.
       $out .= colored([$ENV{TEST_PRETTY_COLOR_NAME} || 'BRIGHT_BLACK'], "  $name");
   }

   if( $context->in_todo ) {
       $out .= " # TODO ".$e->todo;
   }

   $out .= "\n";

   return [ OUT_STD, $out ] unless $e->diag;

   return (
      [OUT_STD, $out,],
      map {$_->to_tap()} @{$e->diag},
   );
}

sub subtest_render_events {
    my ($stream, $e) = @_;

    my $idx = 0;
    my @out;
    for my $e (@{$e->events}) {
        next unless $e->can('to_tap');
        $idx++ if $e->isa('Test::Stream::Event::Ok');
        push @out => stream_listener($stream, $e);
    }

    for my $set (@out) {
        $set->[1] =~ s/^/$ENV{TEST_PRETTY_INDENT}/mg;
    }

    return @out;
}

1;
__END__

=encoding utf8

=for stopwords cho45++

=head1 NAME

Test::Pretty - Smile Precure!

=head1 SYNOPSIS

  use Test::Pretty;

=head1 DESCRIPTION

Test::Pretty is a prettifier for Test::More.

When you are writing a test case such as following:

    use strict;
    use warnings;
    use utf8;
    use Test::More;

    subtest 'MessageFilter' => sub {
        my $filter = MessageFilter->new('foo');

        subtest 'should detect message with NG word' => sub {
            ok($filter->detect('hello from foo'));
        };
        subtest 'should not detect message without NG word' => sub {
            ok(!$filter->detect('hello world!'));
        };
    };

    done_testing;

This code outputs following result:

=begin html

<div><img src="https://raw.github.com/tokuhirom/Test-Pretty/master/img/more.png"></div>

=end html

No, it's not readable. Test::Pretty makes this result to pretty.

You can enable Test::Pretty by

    use Test::Pretty;

Or just add following option to perl interpreter.
    
    -MTest::Pretty

After this, you can get a following pretty output.

=begin html

<div><img src="https://raw.github.com/tokuhirom/Test-Pretty/master/img/pretty.png"></div>

=end html

And this module outputs TAP when $ENV{HARNESS_ACTIVE} is true or under the win32.

=head1 AUTHOR

Tokuhiro Matsuno E<lt>tokuhirom AAJKLFJEF@ GMAIL COME<gt>

=head1 THANKS TO

Some code was taken from L<Test::Name::FromLine>, thanks cho45++

=head1 SEE ALSO

L<Acme::PrettyCure>

=head1 LICENSE

Copyright (C) Tokuhiro Matsuno

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
