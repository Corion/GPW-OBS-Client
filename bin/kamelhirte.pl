#!perl
use strict;
use warnings;
use Filter::signatures;
use 5.012;

use feature 'signatures';
no warnings 'experimental::signatures';

use Getopt::Long;
use Pod::Usage;
use POSIX 'strftime';

use Mojo::OBS::Client;
use Future;
use File::ChangeNotify;
use Text::Table;
use Term::Output::List;
use Carp 'croak';

our $VERSION = '0.01';


GetOptions(
    'u=s' => \my $url,
    'p=s' => \my $password,
    'schedule|s=s' => \my $schedule,
) or pod2usage(2);

$url //= 'ws://localhost:4444';
$schedule //= 'schedule.xml';

# watch input file (XML?)
# reload database on file change
# scene: pre-announce talk
# scene: announce talk
# scene: run talk
# orga: announce q&a ready
# scene: run q&a
# while q&a running:
#     main channel: announce pause/cut, announce next room(?)
# scene: switch to pause

my $pauseScene =

my %allScenes = map { $_->{sceneName} => $_ } (
    { sceneName => 'Pausenbild.hot', start_offset => -120 },
    { sceneName => 'Anmoderation', start_offset => -10 },
    { sceneName => 'Vortrag', start_offset => 0, duration => 6 },
    { sceneName => 'Vortrag.Vollbild', start_offset => 6 },
    { sceneName => 'Q&A', end_offset => 0, duration => 10 },

    { sceneName => 'Orga-Screenshare (obs.ninja)', start_offset => 0 },
    { sceneName => 'Pausenbild', end_offset => 0 },
    { sceneName => 'Ende', start_offset => 0, },
);

my @talkScenes = (qw(
    Vortrag
    Vortrag.Vollbild
    Q&A
));

my @schedule = ();

sub read_schedule_xml( $schedule ) {
    # ...
    my $start = time + 15;
    return (
        { title => 'Welcome to GPW 2021', start => $start,                         slot_duration =>  6, speaker => 'Max', scene => 'Orga-Screenshare (obs.ninja)' },
        { title => 'First talk',          start => $start+6, talk_duration => 13, slot_duration => 30, speaker => 'Max' },
        { title => 'Second talk',         start => $start+45, talk_duration => 17, slot_duration => 30, speaker => 'Max' },
    );
}

sub scene_for_talk( $scene, $talk, $start=undef, $duration=undef ) {
    my $info = $allScenes{ $scene }
        or croak "Unknown scene '$scene'";

    if( $talk ) {
        use Data::Dumper;
        croak Dumper $talk unless defined $talk->{start};
        $start //= $talk->{start}+($info->{start_offset}//0);
    };

    $duration //= $info->{duration};
    if( ! defined $duration ) {
        if( $talk ) {
            my $end = $talk->{start};
            $duration = $end - $start;
        } else {
            $duration = 10000;
        };
    };

    return +{
        %$info,
        talk_info => $talk,
        start => $start,
        duration => $duration,
    };
}

sub current_scene( $events, $ts=time) {
    my $currentSlot = [grep {$ts >= $_->{start} and $ts <= $_->{start} + $_->{slot_duration} } @$events]->[0];
    my $nextSlot = [grep {$ts < $_->{start}} @$events]->[0];

    my $current_presentation_end_time;
    my $current_talk_end_time;
    my $has_QA;
    my $has_Announce;
    if( $currentSlot ) {
        $current_presentation_end_time = $currentSlot->{start} + ($currentSlot->{talk_duration} // 0);
        $has_QA = ! exists $currentSlot->{scene};
        $has_Announce = (!$currentSlot->{scene} or $currentSlot->{scene} ne 'Orga-Screenshare (obs.ninja)');

        $current_talk_end_time = $currentSlot->{start} + ($currentSlot->{talk_duration} // $currentSlot->{slot_duration});
        if( $has_QA ) {
            $current_talk_end_time += $allScenes{"Q&A"}->{duration};
        };
    } else {
        $current_talk_end_time = $ts -1;
        $has_Announce = (!$nextSlot->{scene} or $nextSlot->{scene} ne 'Orga-Screenshare (obs.ninja)');
    };

    my $current_scene;
    if( !$currentSlot ) {
        # The current slot has ended, but the next slot has not started

        my $sc;
        if( $nextSlot ) {
            my @upcoming_scenes = sort { $a->{start_offset} <=> $b->{start_offset} }
                                  grep { ($_->{start_offset} // 0) < 0 }
                                  values %allScenes;
            $sc = (grep {     $ts - $nextSlot->{start} > $_->{start_offset}
                          and $ts < $nextSlot->{start}
                          and ($has_Announce || ($_->{sceneName} ne 'Anmoderation'))
                        } @upcoming_scenes)[-1];
            if( $sc ) {
                $sc = $sc->{sceneName}
            } else {
                $sc = "Pausenbild";
            };


        } else {
            $sc = "Ende";
        };

        # Copy the scene
        my( $start, $ofs );
        if( $nextSlot ) {
            $start = $nextSlot->{start};
            $ofs = $allScenes{$sc}->{start_offset} // 0;

        } else {
            $start = $ts;
            $ofs = 10000;
        };

        if( $sc eq 'Pausenbild' ) {
            $start = $ts -1;
            $ofs = $nextSlot->{start} - $ts;
        };

        $current_scene = scene_for_talk( $sc, $nextSlot, $start+$ofs, abs($ofs) );

    # We have a fixed scene
    } elsif( $currentSlot->{scene} ) {
        $current_scene = scene_for_talk( $currentSlot->{scene}, $currentSlot, $currentSlot->{start}, $currentSlot->{slot_duration});

    # Maybe the QA session is running
    } elsif( $has_QA and $current_presentation_end_time <= $ts and $ts < $current_talk_end_time ) {
        # The current video has (likely) ended
        # Q&A has started
        $current_scene = scene_for_talk( 'Q&A', $currentSlot, $current_presentation_end_time, $allScenes{'Q&A'}->{duration});

    # Vortrag im Vollbild
    } elsif(     $currentSlot->{start} + $allScenes{'Vortrag.Vollbild'}->{start_offset} < $ts
             and $ts < $current_presentation_end_time ) {
        # Plain scene
        $current_scene = scene_for_talk( 'Vortrag.Vollbild', $currentSlot,
                                         $currentSlot->{start} + ($allScenes{'Vortrag.Vollbild'}->{start_offset}//0),
                                         ($currentSlot->{talk_duration}//$currentSlot->{slot_duration}) - ($allScenes{'Vortrag.Vollbild'}->{start_offset} ));
    # Vortrag mit Rahmen
    } elsif( $currentSlot->{start} <= $ts and $ts <= $currentSlot->{start} + $allScenes{'Vortrag.Vollbild'}->{start_offset}) {
        $current_scene = scene_for_talk( 'Vortrag', $currentSlot,
                                         $currentSlot->{start},
                                         );
    } elsif( $nextSlot ) {
        $current_scene = scene_for_talk( 'Pausenbild', $nextSlot, $ts, $nextSlot->{start} - $ts );
    } else {
        $current_scene = scene_for_talk( 'Ende', undef, $ts, $ts+10000 );
    };

    return $current_scene
};

sub expand_schedule( @schedule ) {

    # Retrieve video playlength (if any)

    # Make sure the schedule is sorted by start time
    @schedule = sort { $a->{start} <=> $b->{start} } @schedule;

    my @res;
    # We spring into action right now. Maybe we should limit ourselves
    # to five minutes before the first event?
    my $start_time = time();
    my $end_time = $schedule[-1]->{start} + $schedule[-1]->{slot_duration};

    my $last_scene;
    for my $ts ($start_time..$end_time) {
        my $scene = current_scene( \@schedule, $ts );
        if( ! $scene->{sceneName}) {
            use Data::Dumper;
            warn Dumper $scene;
            die "No scene name!";
        };
        if( !@res or ($last_scene->{sceneName} ne $scene->{sceneName} or $last_scene->{talk_info} != $scene->{talk_info})) {
            if( my $prev_scene = $res[-1] ) {
                if( $scene->{start} < $prev_scene->{start}+$prev_scene->{duration}) {
                    my $d = $prev_scene->{start}+$prev_scene->{duration} - $scene->{start};
                    if( $d > 0 ) {
                        $prev_scene->{duration} = $prev_scene->{start}+$prev_scene->{duration}-$scene->{start};
                    } else {
                        use Data::Dumper;
                        warn "Removing " . Dumper $res[-1];
                        pop @res;
                    };
                };
            };
            push @res, $scene;
        };
        $last_scene = $scene;
    }

    # Fix up the durations here, in the case we lack any?!

    # Maybe do the overlap elimination here?!
    # Or shorten pre-talk events?

    return @res
}

my @events = expand_schedule(read_schedule_xml( $schedule ));

for my $ev (@events) {
    if( ! defined $ev->{duration}) {
        die Dumper \@events;
    };
};

my $output_quotes = Term::Output::List->new();
sub print_events( $action, $events, $ts=time ) {
    # i, hh:mm, scene, title, time to start/running, time left

    my $curr = [grep { $_->{start} <= $ts && $ts < $_->{start} + $_->{duration} } @$events]->[0];
    if( ! $curr ) {
        use Data::Dumper;
        warn $ts;
        warn Dumper $events;
        die "No current event?!";
    };
    my @lines = map {
        my $current =    $_->{talk_info} == $curr->{talk_info}
                      && $_->{sceneName} eq $curr->{sceneName}
                    ? ">" : " ";
        # We may have multiple scenes being "current", this is inconvenient
        # Also, the separate "announce" scenes need to be distinguishable

        my $start = strftime "%H:%M:%S", localtime $_->{start};
        my $remaining = 0;
        my $running = 0;

        if( $ts < $_->{start} ) {
            # This talk/event is pending
            $running = $_->{start} - $ts;
            $running = strftime "-%H:%M:%S", gmtime $running;
            $remaining = strftime ' %H:%M:%S', gmtime $_->{duration};

        } elsif( $ts < $_->{start} + $_->{duration} ) {
            $running = $ts - $_->{start};
            $running = strftime " %H:%M:%S", gmtime $running;

            $remaining = strftime ' %H:%M:%S', gmtime $_->{start} + $_->{duration} - $ts;
        } else {
            $running = ' --:--:--';
            $remaining = ' --:--:--';
        };
        [ $current, $start, $_->{sceneName}, $_->{talk_info}->{title}, $running, $remaining],
    } @$events;

    my $tb = Text::Table->new({},{},{},{},{align=>'right'},{align=>'right'});

    my $sceneName = $curr->{sceneName};
    unshift @lines, ['','',$sceneName,'', strftime('%Y-%m-%d %H:%M:%S', localtime )];

    $tb->load(@lines);
    my @output = split /\r?\n/, $tb;
    #say for @output;
    $output_quotes->output_list(@output, $action//'');
}

#for (1..160) {
#    print_events( \@events );
#    sleep 1;
#};
#exit;

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

sub switch_scene( $obs, $old_scene, $new_scene ) {
    return $obs->send_message($obs->protocol->GetCurrentScene())
    ->then(sub( $info ) {
        if( $info->{name} eq $old_scene ) {
            #warn "Switching from '$info->{name}' to '$new_scene'";
            return $obs->send_message($obs->protocol->SetCurrentScene($new_scene))
        } else {
            warn "Weird/unexpected scene '$info->{name}', not switching to '$new_scene'";
            return Future->done(0)
        }
    });
}

my $last_scene;
Mojo::IOLoop->recurring(1, sub {
    my $ts = time();

    #my $sc = current_scene( \@events );
    my $sc = [grep { $_->{start} <= $ts && $ts < $_->{start} + $_->{duration} } @events]->[0];

    my $action = 'idle';
    # Set up all the information

    if( $last_scene ne $sc->{sceneName}) {
        $action = "Switching from '$last_scene' to '$sc->{sceneName}'";
        switch_scene( $h, $last_scene => $sc->{sceneName} )->retain;
        $last_scene = $sc->{sceneName};
    };
    print_events($action, \@events, $ts);

    # setup_talk($h, 'Text.NextTalk', $sc->{talk_info}->{title});

});

login( $url, $password )->then( sub {
    $h->send_message($h->protocol->GetCurrentScene())
})->then(sub( $info ) {
    $last_scene = $info->{name}
})->retain;

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

