package Test::Stream::Event::DummyTap;

use strict;
use warnings;

use Test::Stream::Event(
   accessors => [qw/succeed/],
   ctx_method => 'dummy_tap',
);

sub to_tap {
   my $self = shift;

   my $ok = ($self->succeed) ? 'ok' : 'not ok';

   return [ OUT_STD, "\n$ok\n", ];
}

sub extra_details {
   my $self = shift;

   return (
      succeed => $self->succeed || 0,
   );
}

1;

__END__
