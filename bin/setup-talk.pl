#!perl
use 5.020;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Getopt::Long;
use Pod::Usage;
use POSIX 'strftime';

use Mojo::OBS::Client;
use Future;

GetOptions(
    'u=s' => \my $url,
    'p=s' => \my $password,
) or pod2usage(2);

$url //= 'ws://localhost:4444';

my $h = Mojo::OBS::Client->new;

sub login( $url, $password ) {

    return $h->connect($url)->then(sub {
        $h->send_message($h->protocol->GetVersion());
    })->then(sub {
        $h->send_message($h->protocol->GetAuthRequired());
    })->then(sub( $challenge ) {
        $h->send_message($h->protocol->Authenticate($password,$challenge));
    })->catch(sub {
        use Data::Dumper;
        warn Dumper \@_;
    });
};

sub setup_talk( $obs, %info ) {

    my @text = grep { /^Text\./ } keys %info;
    my @f = map {
        $obs->send_message($h->protocol->SetTextFreetype2Properties( source => $_,text => $info{ $_ }))
    } (@text);

    my @video = grep { /^VLC\./ } keys %info;
    push @f, map {
        $h->send_message($h->protocol->SetSourceSettings( sourceName => $_, sourceType => 'vlc_source',
                         sourceSettings => {
                                'playlist' => [
                                                {
                                                  'value' => $info{$_},
                                                  'hidden' => $JSON::false,
                                                  'selected' => $JSON::false,
                                                }
                                              ]
                                          }))
    } @video;

    return Future->wait_all( @f );
}

login( $url, $password )->then(sub {
    say "Setting up talk";
    return setup_talk( $h,
        @ARGV
    );
})->on_ready(sub {
    $h->shutdown;
    $h->ioloop->stop;
})->retain;

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

