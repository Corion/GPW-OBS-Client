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
use XML::Twig; # for reading schedule.xml
#use Spreadsheet::Read; # for reading a spreadsheet
use Spreadsheet::ParseXLSX; # for reading a spreadsheet
use Time::Piece; # for strptime
use Encode 'decode','encode';
use Text::Unidecode;
use YAML 'LoadFile';
use Data::Dumper;

our $VERSION = '0.01';

GetOptions(
    'u=s' => \my $url,
    'p=s' => \my $password,
    #'offset|o=s' => \my $offset, # the offset to shift the whole schedule by
    'start-from=s' => \my $schedule_time, # the point in time to start in the schedule
    'schedule|s=s' => \my $schedule,
    'video-config|c=s' => \my $video_config_file,
    'log'          => \my $log_output,
    'dry-run|n'    => \my $dryrun,
) or pod2usage(2);

my %only_ids = map { $_ => $_ } @ARGV;

$url //= 'ws://localhost:4444';
$schedule //= 'schedule.xml';
#$offset //= 0;

my $video_config;
if( $video_config_file ) {
    $video_config = LoadFile( $video_config_file );
} else {
    $video_config = {
        events => [],
    };
};

binmode STDOUT, ':utf8';

if( $schedule_time ) {
    $schedule_time = Time::Piece->strptime($schedule_time, '%Y-%m-%dT%H:%M:%S%z');
} else {
    $schedule_time = Time::Piece->new();
};
my $time_adjust = Time::Piece->new() - $schedule_time;

# watch input file (XML?)
# reload database on file change

# This should go into a config
my %allScenes = map { $_->{sceneName} => $_ } (
    #{ sceneName => 'Pausenbild.hot', start_offset => -120, record => 0, },
    #{ sceneName => 'Anmoderation', start_offset => -10, record => 1 },
    { sceneName => 'Vortrag', start_offset => 0, duration => 40, record => 1 },
    { sceneName => 'Vortrag.Vollbild', start_offset => 40, record => 1 },
    { sceneName => 'Q&A (obs.ninja)', end_offset => 0, duration => 600, record => 1 },
    { sceneName => 'Lightning Talks (obs.ninja)', end_offset => 0, duration => 10, record => 1 },

    { sceneName => 'Orga-Screenshare (obs.ninja)', start_offset => 0, record => 1 },
    { sceneName => 'Pausenbild', end_offset => 0, record => 0 },
    { sceneName => 'Ende', start_offset => 0, record => 0 },
);

my @talkScenes = (qw(
    Vortrag
    Vortrag.Vollbild
),
    'Q&A (obs.ninja)',
);

my @schedule = ();

my $obs;

if( ! $dryrun ) {
    $obs = Mojo::OBS::Client->new;
};

sub time_to_seconds( $time ) {
    $time =~ m!^(?:\[?(\d\d)\]?:)?(\d\d):(\d\d)$!
        or croak "Invalid time: '$time'";
    return ($1 // 0)*3600+$2*60+$3
}

sub ffmpeg_read_media_duration( $file ) {
    my ($t) = grep { /Duration: (\d\d:\d\d:\d\d)\.\d+, start/ } `ffmpeg -i "$file" 2>&1`;
    return time_to_seconds( $t )
}

sub video_info( $id ) {
    (my $ev) = grep { $_->{id} == $id } @{ $video_config->{events} };
    return $ev
}

sub read_schedule_xml( $schedule ) {
    my $twig = XML::Twig->new();
    my $s = $twig->parsefile( $schedule )->simplify( forcearray => [qw[day room]] ); # sluuurp
    my $start = time + 15;
    # Maybe we should always renormalize the schedule to the current time?
    # Or have an offset-fudge so we can start late?
    my @talks = map { my $r = $_; map { +{ id => $_, %{$r->{event}->{$_}} } } keys %{ $r->{event}} }
                map { values %{ $_->{room}} }
                @{ $s->{day} };

    if( scalar keys %only_ids ) {
        @talks = grep { exists $only_ids{ $_->{id}} } @talks;
    };

    for my $t (@talks) {
        $t->{date} =~ s!\+(\d\d):!+$1!;
        if( $t->{date} =~ m!^(20\d\d-\d\d-\d\d) (\d\d:\d\d:\d\d)$! ) {
            $t->{date} = "${1}T$2+0100";
        };
        if( !$t->{date}) {
            use Data::Dumper;
            die Dumper $t;
        };
        $t->{date} = Time::Piece->strptime( $t->{date},'%Y-%m-%dT%H:%M:%S%z' )->epoch;
        $t->{speaker} = join ", ", sort { $a cmp $b } map { $_->{content} } values %{ $t->{persons}->{person}};
        if( $t->{duration} !~ /^(?:\d\d:)?\d\d:\d\d$/) {
            use Data::Dumper;
            die "No duration in " . Dumper $t;
        } elsif ( $t->{duration} =~ /^\d\d:\d\d$/ ) {
            $t->{duration} = "$t->{duration}:00";
        };
        $t->{slot_duration} = time_to_seconds( $t->{duration} );

        my $info = video_info( $t->{id} );

        if( $info ) {
            if( $info->{talk_duration }) {
                $t->{video} = $info->{talk_filename};
                $t->{talk_duration} = $info->{talk_duration};
                $t->{talk_duration} = time_to_seconds( $t->{talk_duration});
                if( ! $info->{scene} ) {
                    delete $t->{scene};
                };
            };

            if( $info->{intro_filename}) {
                $t->{intro_filename} = $info->{intro_filename};
                $t->{talk_duration} += time_to_seconds( $info->{intro_duration})
            };

            if( $info->{q_a_duration}) {
                $t->{q_a_duration} = $info->{q_a_duration};
            };

            if( $info->{scene} ) {
                $t->{scene} = $info->{scene};
            };

        } elsif( $t->{video} ) {
            # Ughh - hopefully the video is available locally to where this
            # script runs so we can fetch the play duration

            # Otherwise, load video into OBS
            # Get the video length
            # But that requires that the OBS connection is already there
            # $t->{talk_duration} //= ffmpeg_read_media_duration( $t->{video} );
            $t->{talk_duration} //= $t->{duration};
            $t->{talk_duration} = time_to_seconds( $t->{talk_duration});

            if( $t->{intro_filename}) {
                $t->{talk_duration} += time_to_seconds( $t->{intro_duration})
            };

            #warn "Talk duration for $t->{title} is $t->{talk_duration}";
        } elsif( $t->{scene} ) {
            # Predefined scene
        } else {
            # this is likely a live talk
            # We don't know how to autostart the Q&A, oh well ...
            #$t->{scene} = 'Orga-Screenshare (obs.ninja)';
            $t->{scene} = 'Q&A (obs.ninja)';
        }
    };
    return @talks;
}

sub read_schedule_spreadsheet( $schedule ) {
    #my $workbook = Spreadsheet::Read->new($schedule, cells => 0, trim => 1);
    my $workbook = Spreadsheet::ParseXLSX->new->parse($schedule);
    my $s = $workbook->worksheet('Tabelle1');
    my $start = time + 15;
    # Maybe we should always renormalize the schedule to the current time?
    # Or have an offset-fudge so we can start late?
    my @talks;
    my ($row_min,$row_max) = $s->row_range;
    for my $row ($row_min+1..$row_max) {
        my @r = map { $s->get_cell($row,$_) } 0..10;
        next if ! defined $r[0] or ! defined $r[3];
        my %talk = (
            date           => $r[0]  ? $r[0]->value : undef,
            duration       => $r[2]  ? $r[2]->value : undef,
            title          => $r[3]  ? $r[3]->value : undef,
            speaker        => $r[4]  ? $r[4]->value : undef,
            video          => $r[5]  ? $r[5]->value : undef,
            talk_duration  => $r[6]  ? $r[6]->value : undef,
            intro          => $r[7]  ? $r[7]->value : undef,
            intro_duration => $r[8]  ? $r[8]->value : undef,
            q_a_duration   => $r[9]  ? $r[9]->value : undef,
            scene          => $r[10] ? $r[10]->value : undef,
        );

        #$talk{ speaker } = decode('Latin-1', $talk{speaker});
        #$talk{ title } = decode('Latin-1', $talk{title});
        $talk{ speaker } = encode('Latin-1', $talk{speaker});
        $talk{ title }   = encode('Latin-1', $talk{title});

        next if $talk{ title } eq 'Pause';
        push @talks, \%talk;
    };

    for my $t (@talks) {
        $t->{date} =~ s!\+(\d\d):!+$1!;
        if( !$t->{date}) {
            use Data::Dumper;
            die Dumper $t;
        };
        $t->{date} = Time::Piece->strptime( "$t->{date}+0100",'%Y-%m-%d %H:%M:%S%z' )->epoch;
        #$t->{speaker} = join ", ", sort { $a cmp $b } map { $_->{content} } values %{ $t->{persons}->{person}};
        if( $t->{duration} !~ /^(?:\d\d:)?\d\d:\d\d$/) {
            use Data::Dumper;
            die "No duration in " . Dumper $t;
        };
        $t->{slot_duration} = time_to_seconds( $t->{duration} );

        if( $t->{intro_duration}) {
            $t->{intro_duration} = time_to_seconds( $t->{intro_duration} );
        };

        if( $t->{video} ) {
            # Ughh - hopefully the video is available locally to where this
            # script runs so we can fetch the play duration

            $t->{talk_duration} //= $t->{duration};
            $t->{talk_duration} = time_to_seconds( $t->{talk_duration});
            warn "Talk duration for $t->{title} is $t->{talk_duration}";
        } else {
            # this is likely a live talk
            $t->{scene} //= 'Q&A (obs.ninja)';
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

    if( exists $talk->{talk_info} ) {
        croak "Type error: Passed in scene instead of talk";
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

sub get_current_event( $events, $ts=time ) {
    [grep {$_->{date} <= $ts and $ts <= $_->{date} + $_->{slot_duration} } @$events]->[0]
}

sub get_next_event( $events, $ts=time) {
    [grep {$ts < $_->{date}} @$events]->[0]
}

sub current_scene( $events, $ts=time) {
    my $currentSlot = get_current_event( $events, $ts );
    my $nextSlot = get_next_event( $events, $ts );

    my $current_presentation_end_time;
    my $current_talk_end_time;
    my $has_QA;
    my $has_Announce;
    if( $currentSlot ) {
        $current_presentation_end_time = $currentSlot->{date} + ($currentSlot->{talk_duration} // 0);
        $has_QA = ! exists $currentSlot->{scene};

        $has_Announce = $currentSlot->{announce_file}
                        || (!$currentSlot->{scene} or $currentSlot->{scene} ne 'Orga-Screenshare (obs.ninja)');

        $current_talk_end_time = $currentSlot->{date} + ($currentSlot->{talk_duration} // $currentSlot->{slot_duration});
        if( $has_QA ) {
            my $d = $currentSlot->{q_a_duration} // $allScenes{"Q&A (obs.ninja)"}->{duration};
            $current_talk_end_time += $d;
            # Well, make the Q&A fit up to the next talk, at most...
        };
    } else {
        $current_talk_end_time = $ts -1;
        $has_Announce = $nextSlot->{announce_file}
                        || (!$nextSlot->{scene} or $nextSlot->{scene} ne 'Orga-Screenshare (obs.ninja)');
    };

    my $current_scene;
    if( !$currentSlot ) {
        # The current slot has ended, but the next slot has not started

        my $sc;
        if( $nextSlot ) {
            #my @upcoming_scenes = sort { $a->{start_offset} <=> $b->{start_offset} }
            #                      grep { ($_->{start_offset} // 0) < 0 }
            #                      values %allScenes;
            ##use Data::Dumper; warn Dumper \@upcoming_scenes;
            ##warn Dumper [grep {     $ts - $nextSlot->{date} > $_->{start_offset}
            ##              and $ts < $nextSlot->{date}
            ##              and ($has_Announce || ($_->{sceneName} ne 'Anmoderation'))
            ##            } @upcoming_scenes];
            #$sc = (grep {     $ts - $nextSlot->{date} > $_->{start_offset}
            #              and $ts < $nextSlot->{date}
            #              and ($has_Announce || ($_->{sceneName} ne 'Anmoderation'))
            #            } @upcoming_scenes)[-1];
            #if( $has_Announce
            #    and $nextSlot->{date} - $nextSlot->{intro_duration} <= $ts
            #    and $ts < $nextSlot->{date}) {
            #    $sc = $allScenes{ 'Anmoderation' };
            #};
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

            # If we have an intro, use that intro length
            #if( $sc eq 'Anmoderation' ) {
            #    if( $nextSlot->{intro_duration} ) {
            #        $ofs = -$nextSlot->{intro_duration}
            #    } else {
            #        $ofs = $allScenes{$sc}->{start_offset} // 0;
            #    };
            #} else {
                $ofs = $allScenes{$sc}->{start_offset} // 0;
            #};

        } else {
            $start = $ts;
            $ofs = 10000;
        };

        if( $sc eq 'Pausenbild' ) {
            #$start = $ts -1;
            #$ofs = $nextSlot->{date} - $ts;
            ##warn "Setting Pausenbild offset of $ofs (Pause starts at $start";
            #$current_scene = scene_for_talk( $sc, $nextSlot, $ts, abs($ofs) );
            if( ! $nextSlot ) {
                warn "Have no next slot but want to Pause?!";
                exit;
            };
            #warn "Creating pausenbild for $nextSlot->{title}";
            $current_scene = pause_until( { date => $nextSlot->{date}, talk_info => $nextSlot }, $ts );
        } else {

            # What do we calculate here???
            $current_scene = scene_for_talk( $sc, $nextSlot, $start+$ofs, abs($ofs) );
         };

    # We have a fixed scene
    } elsif( $currentSlot->{scene} and $current_presentation_end_time <= $ts and $ts < $current_talk_end_time) {
        $current_scene = scene_for_talk( $currentSlot->{scene}, $currentSlot, $currentSlot->{date}, $currentSlot->{slot_duration});

    # Maybe the QA session is running
    } elsif( $has_QA and $current_presentation_end_time <= $ts and $ts < $current_talk_end_time ) {
        # The current video has (likely) ended
        # Q&A has started
        $current_scene = scene_for_talk( 'Q&A (obs.ninja)', $currentSlot, $current_presentation_end_time, $allScenes{'Q&A (obs.ninja)'}->{duration});

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

sub pause_until( $nextSlot, $ts ) {
    if( ! $nextSlot->{talk_info} ) {
        croak "No talk in " . Dumper $nextSlot;
    };
    return scene_for_talk( 'Pausenbild', $nextSlot->{talk_info}, $ts, $nextSlot->{date} - $ts );
}

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

    say "Expanding schedule from " . strftime('%Y-%m-%d %H:%M:%S', localtime($start_time));
    for my $ts ($start_time..$end_time) {
        my $scene = current_scene( \@schedule, $ts );
        #say sprintf "%s %s %s", strftime( "%Y-%m-%d %H:%M:%S", localtime($ts)), $scene->{sceneName}, $scene->{talk_info}->{title};
        #$scene->{talk_info} //= 0;
        if( ! $scene->{sceneName}) {
            use Data::Dumper;
            warn Dumper $scene;
            die "No scene name!";
        };

        my $different_scene;
        {
            $different_scene = $last_scene
                              && (($last_scene->{sceneName} ne $scene->{sceneName})
                                   || (defined $last_scene->{talk_info} xor defined $scene->{talk_info}))
        };

        if( !@res or $different_scene) {
            if( my $prev_scene = $res[-1] ) {
                if( $scene->{date} < $prev_scene->{date}+$prev_scene->{duration}) {
                    my $d = $scene->{date} - $prev_scene->{date};
                    warn "$scene->{sceneName} overlaps $prev_scene->{sceneName} ($d)";
                    if( $d == 0 ) {
                        pop @res;
                    } elsif( $d > 0 ) {
                        $prev_scene->{duration} = $d;
                    } else {
                        $prev_scene->{duration} -= $d;
                    };
                };
            };
            push @res, $scene;
        };
        $last_scene = $res[-1];

#        if( @res > 3 ) {
#    use Data::Dumper;
#    warn Dumper $scene;
#    warn Dumper \@res;
#    exit 1;
#        };
    }


    return @res
}

my $output_quotes = Term::Output::List->new();
sub print_events( $action, $events, $ts=time ) {
    # i, hh:mm, scene, title, time to start/running, time left

    my $curr = [grep { $_->{date} <= $ts && $ts < $_->{date} + $_->{duration} } @$events]->[0];
    if( ! $curr ) {

        use Data::Dumper;
        warn Dumper $events->[0];
        warn "Now:  ", $ts;
        warn "Next: ", $events->[0]->{date};
        warn "Diff: ", $events->[0]->{date} - $ts;
        warn strftime('%Y-%m-%d %H:%M:%S', localtime($ts));
        warn "No current event?!";
        exit;
    };
    my @lines = map {
        my $current =    $_->{talk_info} == $curr->{talk_info}
                      && $_->{sceneName} eq $curr->{sceneName}
                    ? ">" : "";
        # We may have multiple scenes being "current", this is inconvenient
        # Also, the separate "announce" scenes need to be distinguishable

        my $start = strftime "%H:%M:%S", localtime ($_->{date});
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
        [ $current, $start, $_->{sceneName}, $_->{talk_info}->{title}, $running, $remaining, $_->{record}],
    } @$events;

    my $tb = Text::Table->new({},{},{},{},{align=>'right'},{align=>'right'},{});

    my $sceneName = $curr->{sceneName};
    unshift @lines, ['','',$sceneName,'', strftime('%Y-%m-%d %H:%M:%S', localtime ),''];

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
    if( $log_output ) {
        say for (@output,$action//'');
    } else {
        $output_quotes->output_list(@output, $action//'');
    };
}

sub setup_talk( $obs, %info ) {

    my @text = grep { /^Text\./ } keys %info;
    my @f = map {
        $obs->SetTextFreetype2Properties( source => $_,text => $info{ $_ })
    } (@text);

    my @video = grep { /^VLC\./ } keys %info;

    push @f, map {
        my $videos = $info{ $_ };
        if(! ref $videos ) {
            $videos = [ $videos ];
        };
        my @videofiles = map {
                                +{
                                  'value' => $_,
                                  'hidden' => $JSON::PP::false,
                                  'selected' => $JSON::PP::false,
                                }
                             } @$videos;

        $obs->SetSourceSettings(
            sourceName => $_,
            sourceType => 'vlc_source',
            sourceSettings => {
                'playlist' => \@videofiles
            })
    } @video;

    return Future->wait_all( @f )->catch(sub { use Data::Dumper; warn Dumper \@_; exit });
}

sub switch_scene( $obs, $old_scene, $new_scene ) {
    #return $obs->send_message($obs->protocol->GetCurrentScene())
    #->then(sub( $info ) {
        #if( $info->{name} eq $old_scene ) {
            #warn "Switching from '$info->{name}' to '$new_scene'";
    return $obs->SetCurrentScene($new_scene)
        #} else {
        #    warn "Weird/unexpected scene '$info->{name}', not switching to '$new_scene'";
        #    return Future->done(0)
        #}
    #})
    ->catch(sub {
        warn Dumper \@_;
        exit;
    });
}

if( $time_adjust ) {
    warn "Adjusting schedule by $time_adjust seconds";
};

my $last_talk = 0;
my $last_scene = {};

sub scene_changed( $h, $sc ) {
    my @actions;
    # Set up all the information

    my $f = Future->done;

    if( $last_talk != $sc->{talk_info}) {
        #say "$last_talk != $sc->{talk_info} ($last_talk->{title} -> $sc->{talk_info}->{title})";
        # if we changed the talk, stop recording
        push @actions, "Stopping recording";
        $f = $f->then(sub {
            $h->StopRecording()
        });

        my @video;
        if( $sc->{talk_info}->{intro_filename} ) {
            push @video, '/home/gpw/gpw2021-talks/' . $sc->{talk_info}->{intro_filename};
        };
        if( $sc->{talk_info}->{video} ) {
            push @video, '/home/gpw/gpw2021-talks/' . $sc->{talk_info}->{video};
        };
        push @actions, sprintf "setting up talk '$sc->{talk_info}->{title}' at %s", strftime '%H:%M', localtime($sc->{talk_info}->{date});
        #use Data::Dumper;
        #warn Dumper \@video;
        #exit;

        # OBS doesn't output/ingest UTF-8 here :(
        my $s = unidecode( $sc->{talk_info}->{speaker});
        my $t = unidecode( $sc->{talk_info}->{title} );

        $f = $f->then(sub {
            setup_talk( $h,
                'VLC.Vortrag' => \@video,
                'Text.NextTalk'    => $t,
                'Text.NextSpeaker' => $s,
                'Text.NextTime'    => strftime( '%H:%M', localtime( $sc->{talk_info}->{date} )),
            )
        });
    };

    if( !$last_scene or ($last_talk != $sc->{talk_info} or $last_scene->{sceneName} ne $sc->{sceneName})) {

        # If $sc->{record} goes from 0 to 1, record this
        # (maybe also set the filename to the name of the talk(?!)

        if( $sc->{record} and ( $last_talk != $sc->{talk_info} or !$last_scene->{record} )) {
            push @actions, "Starting recording";
            $f = $f->then(sub {
                $h->StartRecording()
            });
        };

        if( $last_scene->{sceneName} ne $sc->{sceneName}) {
            $f = $f->then( sub {
                switch_scene( $h, undef => $sc->{sceneName} )
            });
            push @actions, "Switching from '$last_scene->{sceneName}' to '$sc->{sceneName}'";
        };
    };
    $last_talk = $sc->{talk_info};

    die Dumper $sc
        unless $sc->{talk_info};

    $last_scene = $sc;

    return $f, @actions
};

sub timer_callback( $h, $events, $ts=time() ) {
    $ts -= $time_adjust;
    my $sc = [grep { $_->{date} <= $ts && $ts < $_->{date} + $_->{duration} } @$events]->[0];
    my $next_sc = [grep { $sc->{date}+$sc->{duration} < $_->{date} } @$events]->[0];

    # Check here if we are in Q&A and the next slot is Pausenbild
    # and the next slot is more than 30 seconds away
    # If so, shorten the Pause, elongate the current Q&A and continue

    my @actions;
    if( ref $last_talk
        and $last_talk != $sc->{talk_info}
        and $sc->{sceneName} eq 'Pausenbild'
        and $sc->{date} + $sc->{duration} - $ts > 60) {
            $last_scene->{duration} += 30;
            $sc->{date} += 30;
            $sc->{duration} -= 30;
        # Yell about running over ...
        push @actions, 'running over time, switch manually to "Pausenbild" to stop';
    } else {
        (my( $f ), @actions ) = scene_changed($h, $sc);
        $f->retain;
    };

    @actions = 'idle'
        unless @actions;
    my $action = join ",", @actions;
    print_events($action, $events, $ts);
}

my @events;

# Mute the Desktop audio source whenever no browser is visible
sub onScenesSwitched($info) {
    #say "New scene: " . $info->{'scene-name'};
    # Look for browser source in the current scene items

    my $have_browser;
    for my $source (@{$info->{sources}}) {
        if( $source->{type} eq 'browser_source') {
            #say "Browser source is active";
            $have_browser = 1;
        };
    };

    #if( $have_browser ) {
    #        say "Browser source is active";
    #} else {
    #        say "Browser source is inactive";
    #};

    my $mute = !$have_browser ? $JSON::PP::true : $JSON::PP::false;

    my $toggle_browser_sound = $obs->SetMute(
        source => 'Desktop Audio',
        mute => $mute
    );
    $toggle_browser_sound->retain;
};

sub onPauseClicked( $info ) {
    if( $info->{'scene-name'} eq 'Pausenbild' ) {
        # Somebody clicked "Pause", or the script switched to the Pause scene
        my $ts = time() - $time_adjust;

        #my $sc = [grep { $_->{date} <= $ts && $ts < $_->{date} + $_->{duration} } @events]->[0];
        #my $next_sc = [grep { $_->{date} > $ts } @events]->[0];
        my $sc = get_current_event( \@events, $ts );
        my $next_sc = get_next_event( \@events, $ts );

        if( $sc and $sc->{sceneName} ne 'Pausenbild' ) {
            # We actually switched away from a planned scene, so somebody
            # clicked the "Pause" scene:

            say "You switched away from $sc->{talk_info}->{title}";
            say "Next up is $next_sc->{talk_info}->{title}";

            # Cut the current scene short:
            $sc->{duration} = $ts - $sc->{date};

            # Splice the manual pause event in:
            my $manual_pause = pause_until( $next_sc, $ts );

            my $i = 0;
            $i++ while $events[$i] != $sc;
            splice @events, $i+1, 0, $manual_pause;
        };
    };
}

my $scenesSwitched;
my $pauseClicked;
if( ! $dryrun ) {
    $scenesSwitched = $obs->add_listener('SwitchScenes', \&onScenesSwitched);
    $pauseClicked = $obs->add_listener('SwitchScenes', \&onPauseClicked);
};

sub read_events( $schedule ) {
        my @info;
        if( $schedule =~ /\.xml$/i ) {
            @info = read_schedule_xml( $schedule );
        } elsif( $schedule =~ /\.xlsx$/i ) {
            @info = read_schedule_spreadsheet( $schedule );
        } else {
            die "Unknown file format '$schedule'. I know xml and xlsx";
        };
        my @events = expand_schedule( @info );

        for my $ev (@events) {
            if( ! defined $ev->{duration}) {
                die Dumper \@events;
            };
        };
        return @events;
}

my $logged_in;
if( $dryrun ) {
    @events  = read_events( $schedule );

} else {
    $logged_in = $obs->login( $url, $password )->then( sub {
        $obs->GetCurrentScene()
    })->then(sub( $info ) {
        $last_scene = $info
    })->then(sub {
        eval {

            @events = read_events( $schedule );

            Mojo::IOLoop->recurring(1, sub { timer_callback( $obs, \@events ) });
        };
        warn $@ if $@;

        Future->done;
    })->retain;
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
};


# * Show local time instead of simulated time for next event (?!)
# * Replace Q & A by "ohne Regie (obs.ninja)"
# * Replace Lightning Talks by "mit Regie (obs.ninja)"
