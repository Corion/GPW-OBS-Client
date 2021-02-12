package Moo::Role::RequestReplyHandler;
use Moo::Role;
use feature 'signatures';
no warnings 'experimental::signatures';
use Scalar::Util 'weaken';

requires 'get_reply_key';

has outstanding_messages => (
    is => 'ro',
    default => sub { {} },
);

has event_listeners => (
    is => 'ro',
    default => sub { {} },
);

has message_id => (
    is => 'rw',
    default => '0',
);

sub use_message_id( $self ) {
    my $id = $self->message_id;
    $self->message_id( $id++ );
    return $id
};

sub on_message( $self, $id, $callback ) {
    $self->outstanding_messages->{$id} = $callback;
};

sub message_received( $self, $msg ) {
    my $id = $self->get_reply_key( $msg );
    if( my $handler = delete $self->outstanding_messages->{$id} ) {
        $handler->($msg);
    } else {
        warn "Unhandled message '$id' ignored";
    };
}

sub event_received( $self, $type, $ev ) {
    my $handled;
    if( my $listeners = $self->event_listeners->{ $type } ) {
        @$listeners = grep { defined $_ } @$listeners;
        for my $listener (@$listeners) {
            eval {
                $listener->notify( $ev );
            };
            warn $@ if $@;
        };
        # re-weaken our references
        for (0..$#$listeners) {
            weaken $listeners->[$_];
        };

        $handled++;
    };
    $handled;
}

=head2 C<< ->add_listener >>

    my $l = $driver->add_listener(
        'Page.domContentEventFired',
        sub {
            warn "The DOMContent event was fired";
        },
    );

    # ...

    undef $l; # stop listening

Adds a callback for the given event name. The callback will be removed once
the return value goes out of scope.

=cut

sub add_listener( $self, $event, $callback ) {
    my $listener = RequestReplyHandler::EventListener->new(
        target   => $self,
        callback => $callback,
        event    => $event,
    );
    $self->event_listeners->{ $event } ||= [];
    push @{ $self->event_listeners->{ $event }}, $listener;
    weaken $self->event_listeners->{ $event }->[-1];
    $listener
}

=head2 C<< ->remove_listener >>

    $driver->remove_listener($l);

Explicitly remove a listener.

=cut

sub remove_listener( $self, $listener ) {
    # $listener->{event} can be undef during global destruction
    if( my $event = $listener->event ) {
        my $l = $self->event_listeners->{ $event } ||= [];
        @{$l} = grep { $_ != $listener }
                grep { defined $_ }
                @{$self->event_listeners->{ $event }};
        # re-weaken our references
        for (0..$#$l) {
            weaken $l->[$_];
        };
    };
}

package
    RequestReplyHandler::EventListener;
use strict;
use Moo;
use Carp 'croak';
use Filter::signatures;
no warnings 'experimental::signatures';
use feature 'signatures';

our $VERSION = '0.01';

has 'target' => (
    is => 'ro',
    weak_ref => 1,
);

has 'callback' => (
    is => 'ro',
);

has 'event' => (
    is => 'ro',
);

around BUILDARGS => sub( $orig, $class, %args ) {
    croak "Need an event" unless $args{ event };
    croak "Need a callback" unless $args{ callback };
    croak "Need a target in target" unless $args{ target };
    return $class->$orig( %args )
};

sub notify( $self, @info ) {
    $self->callback->( @info )
}

sub unregister( $self ) {
    $self->target->remove_listener( $self )
        if $self->target; # it's a weak ref so it might have gone away already
    undef $self->{target};
}

sub DESTROY {
    $_[0]->unregister
}

1;
