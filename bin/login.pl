#!perl
use 5.020;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::UserAgent;
use Mojo::JSON 'decode_json', 'encode_json';
use Net::Protocol::OBSRemote;
use Future::Mojo;

use Getopt::Long;
use Pod::Usage;

GetOptions(
    'u=s' => \my $url,
    'p=s' => \my $password,
) or pod2usage(2);

$url //= 'ws://localhost:4444';

my $ua = Mojo::UserAgent->new();
my $protocol = Net::Protocol::OBSRemote->new;

my $ioloop = Mojo::IOLoop->new;
sub future($loop=$ioloop) {
    Future::Mojo->new( $loop )
}

my %responses;
my $tx;
sub connect($ws_url) {
    my $res = future();

    $ua->websocket(
       $ws_url,
    => { 'Sec-WebSocket-Extensions' => 'permessage-deflate' }
    => []
    => sub($dummy, $_tx) {
            $tx = $_tx;
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
                use Data::Dumper;
                say Dumper $payload;
                my $id = $payload->{'message-id'};
                if( my $pending = delete $responses{$id}) {
                    $pending->($payload)
                };
            });

            $res->done();
       },
    );
    return $res;
}

sub send_message($msg) {
    my $res = future();
    use Data::Dumper; say "==>" . Dumper $msg;
    $responses{ $msg->{'message-id'}} = sub($response) {
        $res->done($response);
    };
    $tx->send( encode_json( $msg ));
    $res
};

my $r = &connect($url)->then(sub {
    send_message($protocol->GetVersion());
})->then(sub {
    send_message($protocol->GetAuthRequired());
})->then(sub( $challenge ) {
    send_message($protocol->Authenticate($password,$challenge));
})->then(sub( $challenge ) {
    send_message($protocol->SetTextFreetype2Properties( source => 'Next-Talk',text => 'Hello World'))
})->then(sub( $challenge ) {
    send_message($protocol->GetSourceSettings( sourceName => 'VLC.Vortrag', sourceType => 'vlc_source'))
});

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

