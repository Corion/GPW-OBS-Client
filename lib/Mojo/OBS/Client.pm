package Mojo::OBS::Client;
use 5.012;
use Moo;
use Mojo::UserAgent;
use Mojo::JSON 'decode_json', 'encode_json';
use Net::Protocol::OBSRemote;
use Future::Mojo;

use feature 'signatures';
no warnings 'experimental::signatures';
with 'Moo::Role::RequestReplyHandler';

sub future($self, $loop=$self->ioloop) {
    Future::Mojo->new( $loop )
}

has ioloop => (
    is => 'ro',
    default => sub {
        return Mojo::IOLoop->new();
    },
);

has ua => (
    is => 'ro',
    default => sub {
        return Mojo::UserAgent->new();
    },
);

has tx => (
    is => 'rw',
);

has protocol => (
    is => 'ro',
    default => sub {
        return Net::Protocol::OBSRemote->new();
    },
);

sub get_reply_key($self,$msg) {
    $msg->{'message-id'}
};

sub connect($self,$ws_url) {
    my $res = $self->future();

    $self->ua->websocket(
       $ws_url,
    => { 'Sec-WebSocket-Extensions' => 'permessage-deflate' }
    => []
    => sub($dummy, $_tx) {
            my $tx = $_tx;
            $self->tx( $tx );
            if( ! $tx->is_websocket ) {
                say 'WebSocket handshake failed!';
                $res->fail('WebSocket handshake failed!');
                return;
            };

            $tx->on(finish => sub {
                my ($tx, $code, $reason) = @_;
                #if( $s->_status ne 'shutdown' ) {
                #    say "WebSocket closed with status $code.";
                #};
            });

            $tx->on(message => sub($tx,$msg) {
                my $payload = decode_json($msg);

                if( my $type = $payload->{"update-type"}) {
                    use Data::Dumper;
                    #warn '***' . Dumper $payload;
                    $self->event_received( $type, $payload );
                } elsif( my $id = $self->get_reply_key( $payload )) {
                    use Data::Dumper;
                    #warn '<==' . Dumper $payload;
                    $self->message_received($payload);
                };
            });

            $res->done();
       },
    );
    return $res;
}

sub shutdown( $self ) {
    $self->tx->finish;
}

sub send_message($self, $msg) {
    my $res = $self->future();
    #use Data::Dumper; say "==>" . Dumper $msg;
    my $id = $msg->{'message-id'};
    $self->on_message( $id, sub($response) {
        $res->done($response);
    });
    $self->tx->send( encode_json( $msg ));
    return $res
};

1;
