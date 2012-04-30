#! /usr/bin/perl

# USAGE: ./mplayer_ctrl.pl <mplayer_pipe> [alsa_midi_port]

use strict;
use warnings;

use MIDI::ALSA;

open(my $mplayer_pipe, '>>', $ARGV[0]) or die "wtf $!";

my @knob_names;
my %knob_names;
my %bindings;

sub LEFT() { return 0; }
sub RIGHT() { return 1; }

my $aclient = MIDI::ALSA::client('hercules mplayer', 1, 1);
if($ARGV[1]) {
	MIDI::ALSA::connectfrom(0, $ARGV[1], 0);
	MIDI::ALSA::connectto(0, $ARGV[1], 0);
}
printf "got id %d, fd %d\n", MIDI::ALSA::id(), MIDI::ALSA::fd();

sub setled {
	my ($led, $val) = @_;

	my $led_num = $knob_names{$led.'_led'};
	die "wrong led $led _led" unless defined $led_num;

	MIDI::ALSA::output(
		MIDI::ALSA::SND_SEQ_EVENT_CONTROLLER,
		0, 0, 0, 0, [ MIDI::ALSA::id(), 0 ], [ 0, 0 ], 
		[ 0, 0, 0, 0, $led_num, $val ? 0x7F: 0 ]
	);
}
sub light {
	setled(@_, 1);
}
sub dim {
	setled(@_, 0);
}

while(<DATA>) {
	my ($hex, $val) = ($_ =~ /^(.*?) (.*?)$/);
	my $dec = hex($hex);

	# initialize num->name and name->num arrays
	$knob_names[$dec] = $val;
	$knob_names{$val} = $dec;

	# dim the led if it's a led
	if($val =~ s/_led$//) {
		dim $val;
	}
}

sub mplayer_do {
	my $cmd = shift;

	print $mplayer_pipe "$cmd\n";
	$mplayer_pipe->flush;
}

# takes funny input from hercules and turns it into signed int
# (hercules gives 127 for -1)
sub negativize {
	my $val = shift;
	
	return ($val < 64) ? $val : ($val - 128);
}
sub wheel_seek {
	my $val = negativize(@_) * 10;
	mplayer_do "pausing_keep seek $val";
}
sub wheel_vol {
	my $val = negativize(@_);
	mplayer_do "pausing_keep volume $val";
}
sub wheel_sub {
	my $val = negativize(@_) * 0.1;
	mplayer_do "pausing_keep sub_delay $val";
}
sub wheel_avd {
	my $val = negativize(@_) * 0.1;
	mplayer_do "pausing_keep audio_delay $val";
}

my @mode = (0, 0); # left, right
my %mode_lights = (
	cue => 'l_cue_btn',
	vol => 'r_cue_btn',
	rsub => 'r_fx',
	ravd => 'r_cue',
	lsub => 'l_fx',
	lavd => 'l_cue',
	rframe => 'r_play',
);

sub unset_mode {
	my ($which, $desc) = @_;

	$desc ||= '';
	dim $mode_lights{$mode[$which]};

	print "unsetting $which mode from $mode[$which]\n";
	mplayer_do "pausing_keep osd_show_property_text $which.OFF.$desc";
	$mode[$which] = 0;
}
sub set_mode {
	my ($to, $which, $desc) = @_;

	print "setting $which mode to $to\n";
	$desc ||= '';
	mplayer_do "pausing_keep osd_show_property_text $which.$to.$desc";
	unset_mode($which) if $mode[$which];
	$mode[$which] = $to;
	light $mode_lights{$mode[$which]};
}
# nicely changes 0-127 into -100-100
sub re_range {
	my ($from) = @_;

	my $float = 2 * ($from / 127) - 1; # makes a number in [-1:1]
	$float = (5 * $float ** 3 + $float) / 6; # makes nicely-distributed 
		# number [-1:1] (niceness determined with gnuplot)
	
	return int($float * 100); # returns [-100:100] as taken by mplayer
}

sub button_handler {
	my ($val, $cmd) = @_;
	return unless $val == 0x7F;
	
	mplayer_do $cmd;
}

sub mode_handler {
	my ($val, $which, $mode, $knob, $func, $desc) = @_;
	return unless $val == 0x7F;

	if($mode[$which] eq $mode) {
		unset_mode($which, $desc);
		undef $bindings{$knob};
	} else {
		set_mode($mode, $which, $desc);
		$bindings{$knob} = $func;
	}
}

%bindings = (
	l_cue => sub {
		mode_handler(@_, LEFT, 'cue', 'l_wheel', \&wheel_seek);
	},
	r_cue => sub {
		mode_handler(@_, RIGHT, 'vol', 'r_wheel', \&wheel_vol);
	},
	r_1 => sub { # sub delay
		mode_handler(@_, RIGHT, 'rsub', 'r_wheel', \&wheel_sub, '${sub_delay}');
	},
	r_2 => sub { # a/v delay
		mode_handler(@_, RIGHT, 'ravd', 'r_wheel', \&wheel_avd, '${audio_delay}');
	},
	l_1 => sub { # sub delay
		mode_handler(@_, LEFT, 'lsub', 'l_wheel', \&wheel_sub, '${sub_delay}');
	},
	l_2 => sub { # a/v delay
		mode_handler(@_, LEFT, 'lavd', 'l_wheel', \&wheel_avd, '${audio_delay}');
	},
	l_play => sub {
		button_handler(@_, 'pause');
	},
	l_track_r => sub {
		button_handler(@_, 'frame_step');
	},
	r_play => sub {
		mode_handler(@_, RIGHT, 'rframe', 'r_wheel', sub {
			mplayer_do 'frame_step';
		});
	},
	r_treble => sub {
		my $val = re_range(@_);
		mplayer_do "pausing_keep brightness $val 1";
		if($val == 0) {
			light 'r_phones';
		} else {
			dim 'r_phones';
		}
	},
	r_mid => sub {
		my $val = re_range(@_);
		mplayer_do "pausing_keep contrast $val 1";
		if($val == 0) {
			light 'r_phones';
		} else {
			dim 'r_phones';
		}
	},
	r_bass => sub {
		my $val = 4 * $_[0] / 127;
		$val = 1.0 if($_[0] == 32 || $_[0] == 0);
		mplayer_do "pausing_keep speed_set $val";
		if($val == 1.0) {
			light 'r_phones';
		} else {
			dim 'r_phones';
		}
	},
	# currently broken
#	xfader => sub {
#		my $val = 2* ($_[0] / 127) - 1;
##		$val = 0 if($_[0] == 63 || $_[0] == 64);
#		mplayer_do "pausing_keep set_property balance $val";
#		if($val == 0) {
#			light 'r_phones';
#		} else {
#			dim 'r_phones';
#		}
#	},
	r_phones => sub {
		dim 'r_phones';
	},
	r_arc => sub {
		button_handler(@_, 'pausing_keep vo_fullscreen');
	},
	r_master => sub {
		button_handler(@_, "pausing_keep osd");
	},
	l_master => sub {
		my $time = scalar localtime;
		$time =~ s/ /_/g;
		button_handler(@_, "pausing_keep osd_show_text $time");
	},
	l_arc => sub {
		button_handler(@_, "pausing_keep osd_show_progression");
	},
	'r_pitch+' => sub {
		button_handler(@_, "pausing_keep sub_select");
	},
	'r_pitch-' => sub {
		button_handler(@_, "pausing_keep switch_audio");
	},
);

while(1) {
	my ($type, $flags, $tag, $queue, $time, $source, $destination, $data) = 
		MIDI::ALSA::input();
	my ($useless1, $useless2, $useless3, $useless4, $knob, $val) = @$data;

	if($type == MIDI::ALSA::SND_SEQ_EVENT_CONTROLLER) {
		my $name = $knob_names[$knob];

		# execute the binding
		&{$bindings{$name}}($val) if defined $bindings{$name};
	}
}

close $mplayer_pipe; # will never get here anyway

__DATA__
0F l_fx_led
10 r_fx_led
0E l_cue_led
11 r_cue_led
0D l_loop_led
12 r_loop_led
16 l_tempo_led
1A r_tempo_led
0A l_arrow_led
04 r_arrow_led
09 l_cue_btn_led
03 r_cue_btn_led
08 l_play_led
02 r_play_led
7E l_phones_led
7D r_phones_led
31 xfader
38 joy_horiz
39 joy_vert
08 l_play
09 l_cue
36 l_wheel
0B l_track_l
0C l_track_r
0A l_beat
14 l_pitch-
13 l_pitch+
1B l_arc
15 l_phones
16 l_master
07 l_top
0F l_1
0E l_2
0D l_3
2E l_bass
2F l_mid
30 l_treble
34 l_pitch
32 l_tempo
02 r_play
03 r_cue
37 r_wheel
05 r_track_l
06 r_track_r
04 r_beat
18 r_pitch-
17 r_pitch+
1C r_arc
19 r_phones
1A r_master
01 r_top
10 r_1
11 r_2
12 r_3
2B r_bass
2C r_mid
2D r_treble
35 r_pitch
33 r_tempo
