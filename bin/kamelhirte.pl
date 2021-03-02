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
use XML::Twig;
use Time::Piece; # for strptime

our $VERSION = '0.01';

GetOptions(
    'u=s' => \my $url,
    'p=s' => \my $password,
    #'offset|o=s' => \my $offset, # the offset to shift the whole schedule by
    'start-from=s' => \my $schedule_time, # the point in time to start in the schedule
    'schedule|s=s' => \my $schedule,
) or pod2usage(2);

$url //= 'ws://localhost:4444';
$schedule //= 'schedule.xml';
#$offset //= 0;

if( $schedule_time ) {
    $schedule_time = Time::Piece->strptime($schedule_time, '%Y-%m-%dT%H:%M:%S%z');
} else {
    $schedule_time = Time::Piece->new();
};
my $time_adjust = Time::Piece->new() - $schedule_time;

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

# This should go into a config
my %allScenes = map { $_->{sceneName} => $_ } (
    { sceneName => 'Pausenbild.hot', start_offset => -120, record => 0, },
    { sceneName => 'Anmoderation', start_offset => -10, record => 1 },
    { sceneName => 'Vortrag', start_offset => 0, duration => 6, record => 1 },
    { sceneName => 'Vortrag.Vollbild', start_offset => 6, record => 1 },
    { sceneName => 'Q&A', end_offset => 0, duration => 10, record => 1 },

    { sceneName => 'Orga-Screenshare (obs.ninja)', start_offset => 0, record => 1 },
    { sceneName => 'Pausenbild', end_offset => 0, record => 0 },
    { sceneName => 'Ende', start_offset => 0, record => 0 },
);

my @talkScenes = (qw(
    Vortrag
    Vortrag.Vollbild
    Q&A
));

my @schedule = ();

my $obs = Mojo::OBS::Client->new;

sub get_video_info( $obs, $filename ) {
    # Load the file into OBS
    # Query OBS for the video duration
}

sub time_to_seconds( $time ) {
    $time =~ m!^(?:(\d\d):)?(\d\d):(\d\d)$!
        or croak "Invalid time: '$time'";
    return ($1 // 0)*3600+$2*60+$3
}

sub ffmpeg_read_media_duration( $file ) {
    my ($t) = grep { /Duration: (\d\d:\d\d:\d\d)\.\d+, start/ } `ffmpeg -i "$file" 2>&1`;
    return time_to_seconds( $t )
}

sub read_schedule_xml( $schedule ) {
    my $twig = XML::Twig->new();
    my $s = $twig->parsefile( $schedule )->simplify; # sluuurp
    my $start = time + 15;
    # Maybe we should always renormalize the schedule to the current time?
    # Or have an offset-fudge so we can start late?

    my @talks = map { my $r = $_; map { +{ id => $_, %{$r->{event}->{$_}} } } keys %{ $r->{event}} }
                map { values %{ $_->{room}} }
                @{ $s->{day} };

    for my $t (@talks) {
        $t->{date} =~ s!\+(\d\d):!+$1!;
        if( !$t->{date}) {
            use Data::Dumper;
            die Dumper $t;
        };
        $t->{date} = Time::Piece->strptime( $t->{date},'%Y-%m-%dT%H:%M:%S%z' )->epoch;
        $t->{speaker} = join ", ", sort { $a cmp $b } map { $_->{content} } values %{ $t->{persons}->{person}};
        if( $t->{duration} !~ /^(?:\d\d:)?\d\d:\d\d$/) {
            use Data::Dumper;
            die "No duration in " . Dumper $t;
        };
        $t->{slot_duration} = time_to_seconds( $t->{duration} );

        if( $t->{video} ) {
            # Ughh - hopefully the video is available locally to where this
            # script runs so we can fetch the play duration

            # Otherwise, load video into OBS
            # Get the video length
            # But that requires that the OBS connection is already there
            # $t->{talk_duration} //= ffmpeg_read_media_duration( $t->{video} );
            $t->{talk_duration} //= $t->{duration};
            $t->{talk_duration} = time_to_seconds( $t->{talk_duration});
            warn "Talk duration for $t->{title} is $t->{talk_duration}";
        } else {
            # this is likely a live talk
            # We don't know how to autostart the Q&A, oh well ...
            $t->{scene} = 'Orga-Screenshare (obs.ninja)';
        }
    };
    return @talks;
}

sub scene_for_talk( $scene, $talk, $date=undef, $duration=undef ) {
    my $info = $allScenes{ $scene }
        or croak "Unknown scene '$scene'";

    if( $talk ) {
        use Data::Dumper;
        croak Dumper $talk unless defined $talk->{date};
        $date //= $talk->{date}+($info->{start_offset}//0);
    };

    $duration //= $info->{duration};
    if( ! defined $duration ) {
        if( $talk ) {
            my $end = $talk->{date};
            $duration = $end - $date;
        } else {
            $duration = 10000;
        };
    };

    return +{
        %$info,
        talk_info => $talk,
        date      => $date,
        duration => $duration,
    };
}

sub current_scene( $events, $ts=time) {
    my $currentSlot = [grep {$ts >= $_->{date} and $ts <= $_->{date} + $_->{slot_duration} } @$events]->[0];
    my $nextSlot = [grep {$ts < $_->{date}} @$events]->[0];

    my $current_presentation_end_time;
    my $current_talk_end_time;
    my $has_QA;
    my $has_Announce;
    if( $currentSlot ) {
        $current_presentation_end_time = $currentSlot->{date} + ($currentSlot->{talk_duration} // 0);
        $has_QA = ! exists $currentSlot->{scene};
        $has_Announce = (!$currentSlot->{scene} or $currentSlot->{scene} ne 'Orga-Screenshare (obs.ninja)');

        $current_talk_end_time = $currentSlot->{date} + ($currentSlot->{talk_duration} // $currentSlot->{slot_duration});
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
            $sc = (grep {     $ts - $nextSlot->{date} > $_->{start_offset}
                          and $ts < $nextSlot->{date}
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
            $start = $nextSlot->{date};
            $ofs = $allScenes{$sc}->{start_offset} // 0;

        } else {
            $start = $ts;
            $ofs = 10000;
        };

        if( $sc eq 'Pausenbild' ) {
            $start = $ts -1;
            $ofs = $nextSlot->{date} - $ts;
        };

        $current_scene = scene_for_talk( $sc, $nextSlot, $start+$ofs, abs($ofs) );

    # We have a fixed scene
    } elsif( $currentSlot->{scene} and $current_presentation_end_time <= $ts and $ts < $current_talk_end_time) {
        $current_scene = scene_for_talk( $currentSlot->{scene}, $currentSlot, $currentSlot->{date}, $currentSlot->{slot_duration});

    # Maybe the QA session is running
    } elsif( $has_QA and $current_presentation_end_time <= $ts and $ts < $current_talk_end_time ) {
        # The current video has (likely) ended
        # Q&A has started
        $current_scene = scene_for_talk( 'Q&A', $currentSlot, $current_presentation_end_time, $allScenes{'Q&A'}->{duration});

    # Vortrag im Vollbild
    } elsif(     $currentSlot->{date} + $allScenes{'Vortrag.Vollbild'}->{start_offset} < $ts
             and $ts < $current_presentation_end_time ) {
        # Plain scene
        $current_scene = scene_for_talk( 'Vortrag.Vollbild', $currentSlot,
                                         $currentSlot->{date} + ($allScenes{'Vortrag.Vollbild'}->{start_offset}//0),
                                         ($currentSlot->{talk_duration}//$currentSlot->{slot_duration}) - ($allScenes{'Vortrag.Vollbild'}->{start_offset} ));
    # Vortrag mit Rahmen
    } elsif( $currentSlot->{date} <= $ts and $ts <= $currentSlot->{date} + $allScenes{'Vortrag.Vollbild'}->{start_offset}) {
        $current_scene = scene_for_talk( 'Vortrag', $currentSlot,
                                         $currentSlot->{date},
                                         );
    } elsif( $nextSlot ) {
        $current_scene = scene_for_talk( 'Pausenbild', $nextSlot, $ts, $nextSlot->{date} - $ts );
    } else {
        $current_scene = scene_for_talk( 'Ende', undef, $ts, $ts+10000 );
    };

    return $current_scene
};

sub expand_schedule( @schedule ) {

    # Retrieve video playlength (if any)

    # Make sure the schedule is sorted by start time
    @schedule = sort { $a->{date} <=> $b->{date} } @schedule;

    my @res;
    # We spring into action right now. Maybe we should limit ourselves
    # to five minutes before the first event?
    my $start_time = time() - $time_adjust;
    my $end_time = $schedule[-1]->{date} + $schedule[-1]->{slot_duration};

    my $last_scene = {
        sceneName => '',
        talk_info => 0,
    };
    for my $ts ($start_time..$end_time) {
        my $scene = current_scene( \@schedule, $ts );
        #$scene->{talk_info} //= 0;
        if( ! $scene->{sceneName}) {
            use Data::Dumper;
            warn Dumper $scene;
            die "No scene name!";
        };

        my $different_scene;
        {
            no warnings 'uninitialized';
            $different_scene = $last_scene
                              && (($last_scene->{sceneName} ne $scene->{sceneName})
                                   || (defined $last_scene->{talk_info} xor defined $scene->{talk_info}))
        };

        if( !@res or $different_scene) {
            if( my $prev_scene = $res[-1] ) {
                if( $scene->{date} < $prev_scene->{date}+$prev_scene->{duration}) {
                    my $d = $scene->{date} - $prev_scene->{date};
                    #warn "$scene->{sceneName} overlaps $prev_scene->{sceneName} ($d)";
                    if( $d > 0 ) {
                        $prev_scene->{duration} = $d;
                    } else {
                        pop @res;
                    };
                };
            };
            push @res, $scene;
        };
        $last_scene = $res[-1];
    }

    # Fix up the durations here, in the case we lack any?!

    # Maybe do the overlap elimination here?!
    # Or shorten pre-talk events?

    return @res
}

my $output_quotes = Term::Output::List->new();
sub print_events( $action, $events, $ts=time ) {
    # i, hh:mm, scene, title, time to start/running, time left

    my $curr = [grep { $_->{date} <= $ts && $ts < $_->{date} + $_->{duration} } @$events]->[0];
    if( ! $curr ) {
        use Data::Dumper;
        warn $ts;
        warn Dumper $events;
        die "No current event?!";
    };
    my @lines = map {
        my $current =    $_->{talk_info} == $curr->{talk_info}
                      && $_->{sceneName} eq $curr->{sceneName}
                    ? ">" : "";
        # We may have multiple scenes being "current", this is inconvenient
        # Also, the separate "announce" scenes need to be distinguishable

        my $start = strftime "%H:%M:%S", localtime $_->{date};
        my $remaining = 0;
        my $running = 0;

        if( $ts < $_->{date} ) {
            # This talk/event is pending
            $running = $_->{date} - $ts;
            $running = strftime "-%H:%M:%S", gmtime $running;
            $remaining = strftime ' %H:%M:%S', gmtime $_->{duration};

        } elsif( $ts < $_->{date} + $_->{duration} ) {
            $running = $ts - $_->{date};
            $running = strftime " %H:%M:%S", gmtime $running;

            $remaining = strftime ' %H:%M:%S', gmtime $_->{date} + $_->{duration} - $ts;
        } else {
            $running = ' --:--:--';
            $remaining = ' --:--:--';
        };
        [ $current, $start, $_->{sceneName}, $_->{talk_info}->{title}, $running, $remaining],
    } @$events;

    my $tb = Text::Table->new({},{},{},{},{align=>'right'},{align=>'right'});

    my $sceneName = $curr->{sceneName};
    unshift @lines, ['','',$sceneName,'', strftime('%Y-%m-%d %H:%M:%S', localtime )];

    my $curr_idx = 0;
    for (@lines) {
        if( $_->[0] ) {
            last
        } else {
            $curr_idx++
        };
    };

    if( @lines > 20) {
        my $start = $curr_idx ? $curr_idx -1 : 0;
        @lines = splice @lines, $start, 20;
    };

    $tb->load(@lines);
    my @output = split /\r?\n/, $tb;
    #say for @output;
    $output_quotes->output_list(@output, $action//'');
}

sub login( $h, $url, $password ) {

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
        $obs->send_message($obs->protocol->SetTextFreetype2Properties( source => $_,text => $info{ $_ }))
    } (@text);

    my @video = grep { /^VLC\./ } keys %info;
    push @f, map {
        $obs->send_message($obs->protocol->SetSourceSettings( sourceName => $_, sourceType => 'vlc_source',
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
        #if( $info->{name} eq $old_scene ) {
            #warn "Switching from '$info->{name}' to '$new_scene'";
            return $obs->send_message($obs->protocol->SetCurrentScene($new_scene))
        #} else {
        #    warn "Weird/unexpected scene '$info->{name}', not switching to '$new_scene'";
        #    return Future->done(0)
        #}
    });
}

my $last_talk = 0;
my $last_scene = 0;

if( $time_adjust ) {
    warn "Adjusting schedule by $time_adjust seconds";
};

sub timer_callback( $h, $events, $ts=time() ) {
    $ts -= $time_adjust;
    my $sc = [grep { $_->{date} <= $ts && $ts < $_->{date} + $_->{duration} } @$events]->[0];
    my $next_sc = [grep { $sc->{date}+$sc->{duration} < $_->{date} } @$events]->[0];

    my @actions;
    # Set up all the information

    my $f = Future->done;

    if( $last_talk != $sc->{talk_info}) {
        # if we changed the talk, stop recording
        push @actions, "Stopping recording";
        $f = $f->then(sub {
            $h->send_message( $h->protocol->StopRecording())
        });

        my @video;
        if( $sc->{talk_info}->{file} ) {
            push @video,
                'VLC.Vortrag' => '/home/gpw/gpw2021-talks/' . $sc->{talk_info}->{file};
        };
        $f = $f->then(sub {
        setup_talk( $h,
            @video,
            'Text.ThisTalk' => $sc->{talk_info}->{title},
            'Text.ThisSpeaker' => $sc->{talk_info}->{speaker},
            'Text.NextTalk' => $sc->{talk_info}->{title},
            'Text.NextSpeaker' => $sc->{talk_info}->{speaker},
        )});
    };

    if( !$last_scene or ($last_scene->{sceneName} ne $sc->{sceneName} or $last_talk != $sc->{talk_info})) {

        # If $sc->{record} goes from 0 to 1, record this
        # (maybe also set the filename to the name of the talk(?!)

        if( $sc->{record} and ( $last_talk != $sc->{talk_info} or !$last_scene->{record} )) {
            push @actions, "Starting recording";
            $f = $f->then(sub {
                $h->send_message( $h->protocol->StartRecording())
            });
        };
        $f = $f->then( sub {
            switch_scene( $h, undef => $sc->{sceneName} )
        });
        push @actions, "Switching from '$last_scene->{sceneName}' to '$sc->{sceneName}'";
    };

    $f->retain;

    @actions = 'idle'
        unless @actions;
    my $action = join ",", @actions;
    print_events($action, $events, $ts);

    $last_talk = $sc->{talk_info};
    $last_scene = $sc;
}

login( $obs, $url, $password )->then( sub {
    $obs->send_message($obs->protocol->GetCurrentScene())
})->then(sub( $info ) {
    $last_scene = $info
})->then(sub {
    eval {
    my @events = expand_schedule(read_schedule_xml( $schedule ));
    for my $ev (@events) {
        if( ! defined $ev->{duration}) {
            die Dumper \@events;
        };
    };

    Mojo::IOLoop->recurring(1, sub { timer_callback( $obs, \@events ) });
    };
    warn $@ if $@;

    Future->done;
})->retain;

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

