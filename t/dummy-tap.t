use strict;
use warnings;
use Test::More;
use Test::Stream::API qw/ context /;
use Test::Stream::Tester;

use_ok('Test::Stream::Event::DummyTap');

events_are(
   intercept {
      my $ctx = context();
      $ctx->dummy_tap(1);
      $ctx->dummy_tap(0);
      $ctx->dummy_tap();
   },
   #Expected results
   check {
      event dummytap => { succeed => 1, };
      event dummytap => { succeed => 0, };
      event dummytap => { succeed => 0, };
      directive 'end';
   },
   'events are generated correctly'
);

subtest 'rendering' => sub {
   my $successful_dummy_tap;
   my $failed_dummy_tap;

   my $events = intercept {
      my $ctx = context;
      $successful_dummy_tap = $ctx->dummy_tap(1);
      $failed_dummy_tap = $ctx->dummy_tap(0);
   };

   is_deeply( $successful_dummy_tap->to_tap, [
      0, "\nok\n",
   ], 'Successful Dummy Tap renders correctly' );
   is_deeply( $failed_dummy_tap->to_tap, [
      0, "\nnot ok\n",
   ], 'Failed Dummy Tap renders correctly' );
};

done_testing
