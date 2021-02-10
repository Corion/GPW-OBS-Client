package Moo::Role::RequestReplyHandler;
use Moo::Role;
use feature 'signatures';
no warnings 'experimental::signatures';

requires 'get_reply_key';

has outstanding_messages => (
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

1;
