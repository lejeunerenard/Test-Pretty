package Test::Pretty;
use strict;
use warnings;
use 5.008001;
our $VERSION = '0.30';

use Test::Stream (
   #subtest_tap => 'delayed',
    'OUT_STD',
    'OUT_ERR',
    'OUT_TODO',
);
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

my $DEBUG = 0;

our $NO_ENDING; # Force disable the Test::Pretty finalization process.

my $ORIGINAL_subtest = \&Test::Builder::subtest;

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
    
    #*Test::Builder::subtest = \&_subtest;
    #*Test::Builder::ok = \&_ok;
    #*Test::Builder::done_testing = \&_done_testing;
    #*Test::Builder::skip = \&_skip;
    #*Test::Builder::skip_all = \&_skip_all;
    #*Test::Builder::expected_tests = \&_expected_tests;

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

    # my %plan_cmds = (
    #     no_plan     => \&Test::Builder::no_plan,
    #     skip_all    => \&_skip_all,
    #     tests       => \&__plan_tests,
    # );
    # *Test::Builder::plan = sub {
    #     my( $self, $cmd, $arg ) = @_;

    #     return unless $cmd;

    #     local $Test::Builder::Level = $Test::Builder::Level + 1;

    #     $self->croak("You tried to plan twice") if $self->{Have_Plan};

    #     if( my $method = $plan_cmds{$cmd} ) {
    #         local $Test::Builder::Level = $Test::Builder::Level + 1;
    #         $self->$method($arg);
    #     }
    #     else {
    #         my @args = grep { defined } ( $cmd, $arg );
    #         $self->croak("plan() doesn't understand @args");
    #     }

    #     return 1;
    # };

    # my $builder = Test::Builder->new;
    # $builder->no_ending(1);
    # $builder->no_header(1); # plan

    # binmode $builder->output(), "encoding($TERM_ENCODING)";
    # binmode $builder->failure_output(), "encoding($TERM_ENCODING)";
    # binmode $builder->todo_output(), "encoding($TERM_ENCODING)";

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

END {
    my $builder = Test::Builder->new;
    my $real_exit_code = $?;

    # Don't bother with an ending if this is a forked copy.  Only the parent
    # should do the ending.
    if( $ORIGINAL_PID!= $$ ) {
        goto NO_ENDING;
    }
    if ($Test::Pretty::NO_ENDING) {
        goto NO_ENDING;
    }

    # see Test::Builder::_ending
    if( !$builder->{Have_Plan} and $builder->{Curr_Test} ) {
        $builder->is_passing(0);
        $builder->diag("Tests were run but no plan was declared and done_testing() was not seen.");
    }

    if ($builder->{Have_Plan} && !$builder->{No_Plan}) {
        if ($builder->{Curr_Test} != $builder->{Expected_Tests}) {
            $builder->diag("Bad plan: $builder->{Curr_Test} != $builder->{Expected_Tests}");
            $builder->is_passing(0);
        }
    }
    if ($SHOW_DUMMY_TAP) {
        printf("\n%s\n", ($?==0 && $builder->is_passing) ? 'ok' : 'not ok');
    }
    if (!$real_exit_code) {
        if ($builder->is_passing) {
            ## no critic (Variables::RequireLocalizedPunctuationVars)
            $? = 0;
        } else {
            # TODO: exit status may be 'how many failed'
            ## no critic (Variables::RequireLocalizedPunctuationVars)
            $? = 1;
        }
    }
NO_ENDING:
}

sub stream_listener {
    my ($stream, $e) = @_;

    $DEBUG && print STDERR "---- event ----\n";
    my $type = blessed $e;
    $type =~ s/^.*:://g;
    $DEBUG && print STDERR "type: " . lc($type) . "\n";
    $DEBUG && print STDERR "=> In Subtest (". $e->in_subtest. ")\n" if $e->in_subtest;

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
            #$e->_render_events(@_),
            #[OUT_STD, "}\n"],
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
      $context->diag(Carp::longmess("\$Test::Builder::Level is invalid. Testing library you are using is broken. : $Test::Builder::Level"));
       $src_line = '';
   }

   my $name = $e->name || "  L" . $context->line . ": ". $src_line;
   @sets = $e->to_tap;

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

   $out .= "\n";

   # Replace STDOUT
   for my $set ( @sets ) {
       if ( $set->[0] == OUT_STD ) {
           $set = [
               OUT_STD, $out,
           ];
           last;
       }
   }
   return @sets;
}

sub _skip_all {
    my ($self, $reason) = @_;

    $self->{Skip_All} = $self->parent ? $reason : 1;

    printf("1..0 # SKIP %s\n", $reason);
    $SHOW_DUMMY_TAP = 0;
    if ( $self->parent ) {
        die bless {} => 'Test::Builder::Exception';
    }
    exit(0);
}

sub _ok {
    my( $self, $test, $name ) = @_;

    my ($pkg, $filename, $line, $sub) = caller($Test::Builder::Level);
    my $src_line;
    if (defined($line)) {
        $src_line = $get_src_line->($filename, $line);
    } else {
        $self->diag(Carp::longmess("\$Test::Builder::Level is invalid. Testing library you are using is broken. : $Test::Builder::Level"));
        $src_line = '';
    }

    if ( $self->{Child_Name} and not $self->{In_Destroy} ) {
        $name = 'unnamed test' unless defined $name;
        $self->is_passing(0);
        $self->croak("Cannot run test ($name) with active children");
    }
    # $test might contain an object which we don't want to accidentally
    # store, so we turn it into a boolean.
    $test = $test ? 1 : 0;

    lock $self->{Curr_Test};
    $self->{Curr_Test}++;

    # In case $name is a string overloaded object, force it to stringify.
    $self->_unoverload_str( \$name );

    $self->diag(<<"ERR") if defined $name and $name =~ /^[\d\s]+$/;
    You named your test '$name'.  You shouldn't use numbers for your test names.
    Very confusing.
ERR

    # Capture the value of $TODO for the rest of this ok() call
    # so it can more easily be found by other routines.
    my $todo    = $self->todo();
    my $in_todo = $self->in_todo;
    local $self->{Todo} = $todo if $in_todo;

    $self->_unoverload_str( \$todo );

    my $out;
    my $result = &Test::Builder::share( {} );


    unless($test) {
        my $fail_char = $ENCODING_IS_UTF8 ? "\x{2716}" : "x";
        $out .= colored(['red'], $fail_char);
        @$result{ 'ok', 'actual_ok' } = ( ( $self->in_todo ? 1 : 0 ), 0 );
    }
    else {
        my $success_char = $ENCODING_IS_UTF8 ? "\x{2713}" : "o";
        $out .= colored(['green'], $success_char);
        @$result{ 'ok', 'actual_ok' } = ( 1, $test );
    }

    $name ||= "  L$line: $src_line";

    # $out .= " $self->{Curr_Test}" if $self->use_numbers;

    if( defined $name ) {
        $name =~ s|#|\\#|g;    # # in a name can confuse Test::Harness.
        $out .= colored([$ENV{TEST_PRETTY_COLOR_NAME} || 'BRIGHT_BLACK'], "  $name");
        $result->{name} = $name;
    }
    else {
        $result->{name} = '';
    }

    if( $self->in_todo ) {
        $out .= " # TODO $todo";
        $result->{reason} = $todo;
        $result->{type}   = 'todo';
    }
    else {
        $result->{reason} = '';
        $result->{type}   = '';
    }

    $self->{Test_Results}[ $self->{Curr_Test} - 1 ] = $result;
    $out .= "\n";

    # Dont print 'ok's for subtests. It's not pretty.
    $self->_print($out) unless $sub =~/subtest/ and $test;

    unless($test) {
        my $msg = $self->in_todo ? "Failed (TODO)" : "Failed";
        $self->_print_to_fh( $self->_diag_fh, "\n" ) if $ENV{HARNESS_ACTIVE};

        my( undef, $file, $line ) = $self->caller;
        if( defined $name ) {
            $self->diag(qq[  $msg test '$name'\n]);
            $self->diag(qq[  at $file line $line.\n]);
        }
        else {
            $self->diag(qq[  $msg test at $file line $line.\n]);
        }
    }

    $self->is_passing(0) unless $test || $self->in_todo;

    # Check that we haven't violated the plan
    $self->_check_is_passing_plan();

    return $test ? 1 : 0;
}

sub _done_testing {
    # do nothing
    my $builder = Test::More->builder;
    $builder->{Have_Plan} = 1;
    $builder->{Done_Testing} = [caller];
    $builder->{Expected_Tests} = $builder->current_test;
}

sub _subtest {
    my ($self, $name) = @_;
    my $orig_indent = $self->_indent();
    my $ORIGINAL_note = \&Test::Builder::note;
    no warnings 'redefine';
    *Test::Builder::note = sub {
        # Not sure why the output looses its encoding but lets set it back again.
        # Otherwise we get "Wide character in print" errors.
        binmode $_[0]->output(), "encoding($TERM_ENCODING)";
        # If printing the beginning of a subtest, make it pretty
        if ( $_[1] eq "Subtest: $name") {
            print {$self->output} do {
                 $orig_indent . "  $name\n";
            };
            return 0;
        } else {
            $ORIGINAL_note->(@_);
        }
    };
    # Now that we've redefined note(), let Test::Builder run as normal.
    my $retval = $ORIGINAL_subtest->(@_);
    *Test::Builder::note = $ORIGINAL_note;
    $retval;
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

sub __plan_tests {
    my ( $self, $arg ) = @_;

    if ($arg) {
        local $Test::Builder::Level = $Test::Builder::Level + 1;
        return $self->expected_tests($arg);
    }
    elsif ( !defined $arg ) {
        $self->croak("Got an undefined number of tests");
    }
    else {
        $self->croak("You said to run 0 tests");
    }

    return;
}

sub _expected_tests {
    my $self = shift;
    my($max) = @_;

    if(@_) {
        $self->croak("Number of tests must be a positive integer.  You gave it '$max'")
          unless $max =~ /^\+?\d+$/;

        $self->{Expected_Tests} = $max;
        $self->{Have_Plan}      = 1;

        # $self->_output_plan($max) unless $self->no_header;
    }
    return $self->{Expected_Tests};
}

sub _skip {
    my ($self, $why) = @_;

    lock( $self->{Curr_Test} );
    $self->{Curr_Test}++;

    $self->{Test_Results}[ $self->{Curr_Test} - 1 ] = &Test::Builder::share(
        {
            'ok'      => 1,
            actual_ok => 1,
            name      => '',
            type      => 'skip',
            reason    => $why,
        }
    );

    $self->_print(colored(['yellow'], 'skip') . " $why");

    return 1;
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
