#!perl
use strict;
use warnings;
use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use Getopt::Long;
use Pod::Usage;
use POSIX 'strftime';

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
})->catch(sub {
    use Data::Dumper;
    warn Dumper \@_;
    });

my $l = $h->add_listener('StreamStatus' => sub( $status ) {
    say sprintf "Status: '%s'", $status->{"update-type"}; #, Dumper $status;
    #say Dumper $status;
});

use Data::Dumper;
Mojo::IOLoop->recurring(5 => sub {
    my $scene;
    my $duration;
    my $timestamp;
    $h->send_message($h->protocol->GetCurrentScene())->then(sub($reply) {
        $scene = $reply->{"name"};
        Future->done();
    })->then(sub {
        $h->send_message($h->protocol->GetMediaDuration('VLC.Vortrag'))
    })->then(sub( $reply) {
        $duration = $reply->{mediaDuration};
        Future->done();
    })->then(sub() {
        $h->send_message($h->protocol->GetMediaTime('VLC.Vortrag'))
    })->then(sub($reply) {

        if( $scene eq 'Vortrag' ) {
            $timestamp = $reply->{timestamp};

            my $left = ($duration - $timestamp)/1000;

            warn sprintf 'Duration: %d ms   Current time: %d ms, time left: %s',
            $duration,
            $timestamp,
            strftime '%H:%M:%S left', gmtime($left);
        };

        Future->done();
    })->retain;
});

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

