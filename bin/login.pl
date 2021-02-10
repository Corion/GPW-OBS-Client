#!perl
use 5.020;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Getopt::Long;
use Pod::Usage;

use Mojo::OBS::Client;

GetOptions(
    'u=s' => \my $url,
    'p=s' => \my $password,
) or pod2usage(2);

$url //= 'ws://localhost:4444';

my $h = Mojo::OBS::Client->new;
my $r = $h->connect($url)->then(sub {
    $h->send_message($h->protocol->GetVersion());
})->then(sub {
    $h->send_message($h->protocol->GetAuthRequired());
})->then(sub( $challenge ) {
    $h->send_message($h->protocol->Authenticate($password,$challenge));
})->then(sub( $challenge ) {
    $h->send_message($h->protocol->SetTextFreetype2Properties( source => 'Text.NextTalk',text => 'Hello World'))
})->then(sub( $challenge ) {
    $h->send_message($h->protocol->GetSourceSettings( sourceName => 'VLC.Vortrag', sourceType => 'vlc_source'))
})->then(sub( $challenge ) {
    # Queue up a talk
    $h->send_message($h->protocol->SetSourceSettings( sourceName => 'VLC.Vortrag', sourceType => 'vlc_source',
    sourceSettings => {
                                'playlist' => [
                                                {
                                                  'value' => '/home/gpw/gpw2021-recordings/2021-02-02 18-21-42.mp4',
                                                  'hidden' => $JSON::false,
                                                  'selected' => $JSON::false,
                                                }
                                              ]
                                          },
    ))
})->catch(sub {
    use Data::Dumper;
    warn Dumper \@_;
    });

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

