#!/usr/bin/perl

# /*************************************************************************** 
#  *   leanstick -- http://www.yiannnos.com/leanstick                        * 
#  *                                                                         * 
#  *   This program is free software; you can redistribute it and/or modify  * 
#  *   it under the terms of the GNU General Public License as published by  * 
#  *   the Free Software Foundation; either version 2 of the License, or     * 
#  *   (at your option) any later version.                                   * 
#  *                                                                         * 
#  *   This program is distributed in the hope that it will be useful,       * 
#  *   but WITHOUT ANY WARRANTY; without even the implied warranty of        * 
#  *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         * 
#  *   GNU General Public License for more details.                          * 
#  *                                                                         * 
#  *   You should have received a copy of the GNU General Public License     * 
#  *   along with this program; if not, write to the                         * 
#  *   Free Software Foundation, Inc.,                                       * 
#  *   59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.             * 
#  *                                                                         * 
#  *   Licensed under the GNU GPL                                            * 
#  ***************************************************************************/ 
#
# A script to map joystik/gamepad events to shell commands
#
# Created by Yiannis Pericleous <yiannnos@gmail.com>

use strict;
use IO::Select;
use IO::File;

use constant AXIS_MAX => 32767;
use constant NEG_AXIS_MAX => -32767;

my $VERSION = 0.2;
my $API_VERSION = 0.2;
my $APP_NAME = 'leanstick';
my $DEFAULT_PROFILE_NAME = ' default';
my $ACTIVE_PROFILE_FILE = "/tmp/$APP_NAME.active";
my $STICKY_PROFILE_NAME = 'sticky';

my $BUTTON = 1;
my $AXIS = 2;
my $STICK = 3;
my $COMBO = 99;

my $DELAY = 0.01;
my $NOSTICK_DELAY = 1;

my $BTN_UP	= 0;
my $BTN_DOWN = 1;
my $BTN_PRESS = 2;

my $AXIS_MOVE = 0;
my $AXIS_UP = 1;
my $AXIS_DOWN = 2;
my $AXIS_PRESS = 3;
my $AXIS_TAP = 4;

my $STICK_MOVE = 0;

my $COMBO_EVENT = 1;

my $AXIS_THRESH = 10; # %
my $TAP_THRESH	= 15;

my %external;
my %internal;
my %buttons;
my %axis;
my %stick;
my %macros;

my @profiles;
my $profiles_n;

my $device = "/dev/input/js0";
my $config_file = "$ENV{HOME}/.$APP_NAME";
my $last_time = 0;

# command line flags
my ($force_quit, $print_version, $print_help, $print_config, $print_event, $execute);
my @single_opts;

# crappy command line parsing!!
while (my $opt = shift @ARGV) {

	# -j : joystick
	if ($opt eq "-j") {
		$device = shift @ARGV;
		usage() unless $device;
	}

	# -h : help
	elsif ($opt eq "-h") {
		$print_help = 1;
		push @single_opts, $opt;
	}

	# -f : config file
	elsif ($opt eq "-f") {
		$config_file = shift @ARGV;
		usage() unless $config_file;
	}

	# -a : axis threshold
	elsif ($opt eq "-a") {
		$AXIS_THRESH = shift @ARGV;
		usage() unless $AXIS_THRESH;
		unless ($AXIS_THRESH =~ m/^\d+$/ and $AXIS_THRESH >= 0 and $AXIS_THRESH <= 90) {
			print STDERR "Error: -a argument must be between 0 and 90\n";
			exit 1;
		}
	}

	# -t : tap threshold
	elsif ($opt eq "-t") {
		$TAP_THRESH = shift @ARGV;
		usage() unless $TAP_THRESH;
		unless ($TAP_THRESH =~ m/^\d+$/ and $TAP_THRESH >= 0) {
			print STDERR "Error: -t argument must be greater than or equal to 0\n";
			exit 1;
		}
	}
	
	# -q : quit
	elsif ($opt eq "-q") {
		$force_quit = 1;
		push @single_opts, $opt;
	}

	# -v : version	
	elsif ($opt eq "-v") {
		$print_version = 1;
		push @single_opts, $opt;
	}
	
	# -p : print config
	elsif ($opt eq "-p") {
		$print_config = 1;
		push @single_opts, $opt;
	}
	
	# -e : print event
	elsif ($opt eq "-e") {
		$print_event = 1;
		push @single_opts, $opt;
	}
	
	# -x : execute
	elsif ($opt eq "-x") {
		$execute = shift @ARGV;
		usage() unless $execute;
		push @single_opts, $opt;
	}
}

if (scalar @single_opts > 1) {
	my $args = join(' ', @single_opts);
	print STDERR "Error: the arguments $args cannot be used together\n";
	exit 1;
}

version() if $print_version;
usage() if $print_help;

# get all leanstick processes
my $proc = `ps axo "%p,%a" | grep "perl.* .*$APP_NAME.pl" | grep -v grep|cut -d',' -f1`;
my @procs = split(/\n/, $proc);

# if force quit, stop any other running leanstick
foreach (@procs) {
	kill 'INT', $_ if ($_ != $$) and $force_quit;
}
exit 0 if $force_quit;

# is leanstick already running?
die ("$APP_NAME is already running...\n") if scalar @procs > 1 
		and not ($print_config or $print_event or $execute);

# set the CTRL-C handler
$SIG{INT} = \&quit;

# try to find the joystick device
my $js = {};
eval {
	js_init($js, $device);
};
error("Could not connect to joystick ($device)") 
		unless $js->{fh} or $print_config or $execute;

open(CONF, $config_file) 
	or error("Failed to open configuration file ($config_file)");

my $active_profile_i;
my $active_profile = $DEFAULT_PROFILE_NAME;
my ($comment, $comment_clear);

$comment = "";

# parse the configuration file
while(<CONF>) {

	# handle comment line
	if (m/^\s*#+\s*(.+)\s*$/) {
		my $m;
		$comment = "" if $comment_clear;
		$m = $1 if m/^\s*#+\s*(.+?)\s*#*\s*$/;
		if ($m) {
			$comment .= "\n" if $comment;
			$comment .= $m;
		}
		undef $comment_clear;
	}
	else {
		$comment_clear = 1;	
	}

	# match profile change
	if (m/^\s*profile\s*=\s*(\w.*)\s*$/i) {
		$active_profile = $1;
		$active_profile = $STICKY_PROFILE_NAME 
			if $active_profile =~ m/$STICKY_PROFILE_NAME/i;
		push @profiles, $active_profile;
		undef $comment;
		undef $comment_clear;
	}
	
	# parse action strings
	add_action($3, $BUTTON, $1, $BTN_UP, $4)
		if (m/^\s*button\s*(\d+)\s*(up)?\s*(:|=)\s*(.+)\s*$/i);

	add_action($2, $BUTTON, $1, $BTN_DOWN, $3)
		if (m/^\s*button\s*(\d+)\s*down\s*(:|=)\s*(.+)\s*$/i);

	add_action($5, $BUTTON, $1, $BTN_PRESS, $6, $4)
		if (m/^\s*button\s*(\d+)\s*press(ed)?\s*(delay\s*(\d+))?\s*(:|=)\s*(.+)\s*$/i);
	
	add_action($6, $AXIS, $1, $AXIS_UP, $7, 0, lc $2)
		if (m/^\s*axis\s*(\d+)\s*((neg)|(pos))\s*(up)?\s*(:|=)\s*(.+)\s*$/i);
	
	add_action($5, $AXIS, $1, $AXIS_DOWN, $6, 0, lc $2)
		if (m/^\s*axis\s*(\d+)\s*((neg)|(pos))\s*down\s*(:|=)\s*(.+)\s*$/i);
	
	add_action($5, $AXIS, $1, $AXIS_TAP, $6, 0, lc $2)
		if (m/^\s*axis\s*(\d+)\s*((neg)|(pos))\s*tap\s*(:|=)\s*(.+)\s*$/i);
	
	add_action($8, $AXIS, $1, $AXIS_PRESS, $9, $7, lc $2)
		if (m/^\s*axis\s*(\d+)\s*((neg)|(pos))\s*press(ed)?\s*(delay\s*(\d+))?\s*(:|=)\s*(.+)\s*$/i);
	
	add_action($8, $AXIS, $1, $AXIS_MOVE, $9, $7, lc $2)
		if (m/^\s*axis\s*(\d+)\s*((neg)|(pos))\s*move(d)?\s*(delay\s*(\d+))?\s*(:|=)\s*(.+)\s*$/i);	
	
	add_action($3, $STICK, $1, $STICK_MOVE, $4)
		if (m/^\s*stick\s*(\d+)(\s*move)?\s*(:|=)\s*(.+)\s*$/i);
	
	# and a really long regex for combo actions!
	add_combo_action($1, $11, $12, $10)
		if (m/^(\s*((axis)|(button))\s*(\d+)\s*((neg)|(pos))?\s*\+\s*\w.+?)\s*(delay\s*(\d+))?\s*(:|=)\s*(.+)\s*$/i);

	# handle macros
	add_macro($1, $3, $5)
		if (m/^\s*macro\s*([a-z_]+)(\((\s*[a-z]+\s*(,\s*[a-z]+\s*)*)?\))?\s*=\s*(.+)\s*$/i);
}
close CONF;

# not needed anymore
undef $comment;
undef $comment_clear;

# -x argument
if ($execute) {

	# fill in the axis stuff
	my $max = AXIS_MAX;
	my $res = __execute($execute);
	exit $res;
}
print_config() if $print_config;

$profiles_n = scalar @profiles;

# first profile is the active one
set_active_profile(0, 1);


my $res;

# loop
my $otime = 0;
my $intern;

# used for printing the action
my ($listen_to_events, $no_change_count, $last_event);

while (1) {

	unless ($js->{fh}) {
		sleep($NOSTICK_DELAY);
		eval {
			js_init($js, $device);
		};
	}
	my @event = js_poll($js, $DELAY) if $js->{fh};

	if ($print_event) {
		
		if (not @event 	and $listen_to_events eq 2 and $no_change_count eq 50) {
			print $last_event;
			exit 0;
		}
		
		$no_change_count = 0 if @event;
		$no_change_count++ if not @event;

		$listen_to_events = 2
			if @event and $listen_to_events;

		$listen_to_events = 1
			if not @event and not $listen_to_events;	
	}

	$otime++;
	undef $intern;

	foreach (@event) {
		my $type = $_->{type};
		my $number = $_->{number};
		my $value = $_->{value};
		my $time = $_->{time};
		
		if ($type eq $BUTTON) {
			execute($type, $value, $number);
			$buttons{$number}{pressed} = $value;
			$buttons{$number}{delay} = 0;
		}
		elsif ($type eq $AXIS) {
			my $pcnt = ($value * 100) / AXIS_MAX;
			my $old_ax = $axis{$number}{value} > 0? "pos": "neg";
			my $ax = $value > 0? "pos": "neg";

			# check if pressed state changed
			my $state = axis_state($number, $pcnt);
			execute($type, $state, $number, 0, $axis{$number}{value})
				 if $state eq $AXIS_UP;
			
			execute($type, $state, $number, 0, $value)
				 if $state eq $AXIS_DOWN;
			
			execute($type, $AXIS_TAP, $number, 0, $axis{$number}{value})
				if $state  eq $AXIS_UP 
					and not over_tap_thresh($number, $otime)
					and $axis{$number}{maxed};

			$axis{$number}{time} = $otime if $state eq $AXIS_DOWN;
			$axis{$number}{maxed} = 0 if $state eq $AXIS_DOWN;
			$axis{$number}{maxed} = 1 if $state ne $AXIS_DOWN 
					and ($value gt (AXIS_MAX - (AXIS_MAX/10) )
							or $value lt (NEG_AXIS_MAX + (AXIS_MAX/10)));
			$axis{$number}{delay} = 0;
			$axis{$number}{value} = $value;
			$axis{$number}{pcnt} = $pcnt;

			my $stick_n = int($number / 2);
			my $stick_i = $number % 2;
			$stick{$stick_n}{delay} = 0;
			$stick{$stick_n}{$stick_i}{value} = $value;
			$stick{$stick_n}{$stick_i}{pcnt} = $pcnt;
		}
		my $t = ($time - $last_time);
		$last_time = $time;
    }

	my @combo;
	my $combo_delay;

	# handle actions for other buttons that are still pressed
	foreach (keys %buttons) {
		if ($buttons{$_}{pressed}) {
			execute($BUTTON, $BTN_PRESS, $_, $buttons{$_}{delay});
			push @combo, "$BUTTON-$_";
			$combo_delay = $buttons{$_}{delay}
				if not $combo_delay or $combo_delay > $buttons{$_}{delay};
		}
		$buttons{$_}{delay}++;
	}
	
	# handle actions for axis's that are still moving
	foreach (keys %axis) {
		if (over_threshold ($axis{$_}{pcnt})) {
			my $ax = $axis{$_}{value} > 0? "pos": "neg";
			if (over_tap_thresh($_, $otime) or not tap_defined($_, $ax)) {
				execute($AXIS, $AXIS_PRESS, $_, $axis{$_}{delay}, $axis{$_}{value});	
				execute_axis_move($_, $axis{$_}{delay}, $axis{$_}{value});

				push @combo, "$AXIS-$_-$ax";
				$combo_delay = $axis{$_}{delay}
					if not $combo_delay or $combo_delay > $axis{$_}{delay};
			}
		}
		$axis{$_}{delay}++;
	}
	
	# handle actions for sticks
	foreach (keys %stick) {
		if (over_threshold ($stick{$_}{0}{pcnt}) or
				over_threshold ($stick{$_}{1}{pcnt})) {
			execute_stick_move($_, $stick{$_}{delay}, 
				$stick{$_}{0}{value}, $stick{$_}{1}{value});
		}
		$stick{$_}{delay}++;
	}

	# if more than 1 button/axis pressed, execute corresponding combo action
	if (scalar @combo > 1) {
		my $combohash = combo_hash(@combo);
		execute($COMBO, $COMBO_EVENT, $combohash, $combo_delay);
	}

	# internal actions
	if ($intern) {

		# profile changes
		if ($intern =~ m/^\s*profile\s+previous\s*$/i) {
			print "$APP_NAME: profile previous\n";
			my $i = ($active_profile_i + $profiles_n - 1) % $profiles_n;
			set_active_profile($i, -1);
		}
		elsif ($intern =~ m/^\s*profile\s+next\s*$/i) {
			print "$APP_NAME: profile next\n";
			my $i = ($active_profile_i + $profiles_n + 1) % $profiles_n;
			set_active_profile($i, 1);
		}
		elsif ($intern =~ m/^\s*profile\s+named\s+(\w.*)\s*$/i) {
			my $i = 0;
			my $ai = -1;
			foreach (@profiles) {
				$ai = $i if ($_ eq $1);
				$i++;
			}
			if ($ai > -1) {
				print "$APP_NAME: profile named $1\n";
				set_active_profile($ai);
			}
		}

		# quit !
		elsif ($intern =~ m/^\s*exit\s*$/i) {
			print "$APP_NAME: exit\n";
			cleanup();
			exit 0;
		}
	}
}

cleanup();
exit 0;

####################################################################


# checks if axis was moved towars or away (up/down) from 0 or if 
# it stayed pressed
sub axis_state
{
	my ($number, $value) = @_;
	my $old_value = $axis{$number}{value};
	$old_value = ($old_value * 100) / AXIS_MAX;

	$old_value = over_threshold($old_value); 
	$value = over_threshold($value);

	return $AXIS_PRESS if ($old_value == $value and $value);
	return $AXIS_UP if ($old_value and not $value);
	return $AXIS_DOWN if ($value and not $old_value);
	return $AXIS_MOVE;
}

# checks if given precentage is over the AXIS THRESHOLD
sub over_threshold
{
	my $value = shift;
	return 1 if $value > $AXIS_THRESH;
	return -1 if $value < -$AXIS_THRESH;
	return 0;
}
sub over_tap_thresh
{
	my ($number, $time) = @_;
	return 1 if $time - $axis{$number}{time} > $TAP_THRESH;
	return 0;
}
sub tap_defined
{
	my ($number, $ax) = @_;
	return 1 if $external{$active_profile}{$AXIS}{$number}{$AXIS_TAP}{$ax};
	return 1 if $internal{$active_profile}{$AXIS}{$number}{$AXIS_TAP}{$ax};
	return 0;
}

# expand the macros in the given string
sub expand_macros
{
	my ($command) = @_;

	my $ret = "";

	# match everything that looks like a macro
	# we must be able to match anything of the form:
	# $macro_name(argument, $another_macro(arg1, arg2))
	while($command =~ m/\$([a-z_]+)(\(((([^,\(\)]+?)|([^,\(\)]*?\(.*?\)[^,\(\)]*?))(,(([^,\(\)]+?)|([^,\(\)]*?\(.*?\)[^,\(\)]*?)))*)?\))?([^a-zA-Z_]|\z)/i ) {
		my $macro = $1;

		# split the argument list into an array
		my @args = ();
		my @argchars = split(//, $3);
		my ($paren, $arg);
		$arg = '';
		foreach (@argchars) {
			if ($_ eq ',' and not $paren) {
				push @args, $arg if $arg;
				$arg = '';
			}
			else {
				$paren = 1 if $_ eq '(';
				undef $paren if $_ eq ')';
				$arg .= $_;
			}
		}
		push @args, $arg if $arg;
		my $lastchar = $11;

		my $replacement = $&;
		my $preceeding = $`;
		$command = $';

		# is there such a macro defined?
		if (defined $macros{$macro}) {
			my $m = $macros{$macro};
			my $nargs = @args;
			my @keys = sort { $b <=> $a } keys %$m;

			# find a definition with matching number of args, if possible
			my $bestmatch;
			foreach (@keys) {
				$bestmatch = $_ if $nargs <= $_;
			}

			# if we have something close enough do the expansion
			if (defined $bestmatch) {
				my $m = $macros{$macro}{$bestmatch};
				my @arglist = @{$m->{arglist}};
				my $def = $m->{definition};
				my $argn = scalar @arglist;
				$replacement = $def;

				# replace arguments
				foreach (0 .. $argn - 1) {
					my $nm = $arglist[$_];
					my $rep = $args[$_] || "";
					#$rep = expand_macros($rep);
					$replacement =~ s/\$\{$nm\}/$rep/g;
				}
				$replacement = expand_macros($replacement);
				$replacement .= $lastchar;
			}
			else {
				print "Failed to expand macro $replacement: Invalid number of arguments\n";
			}
		}
		$ret .= "$preceeding$replacement";
	}

	# add any leftovers
	$ret .= $command;
	return $ret;
}

# execute a command
sub execute 
{
	if ($print_event) {
		my ($type, $value, $number, $delay, $axis_val) = @_;	
		$last_event =  "$type.$number" if not $axis_val;
		$last_event =  "$type.$number.neg" if $axis_val > 0;
		$last_event =  "$type.$number.pos" if $axis_val < 0;
	}
	else {
		_execute($active_profile, @_);
		_execute($STICKY_PROFILE_NAME, @_);
	}
}

sub _execute  
{
	my $res;
	my ($prof, $type, $value, $number, $delay, $axis_val) = @_;	
	my $action = $external{$prof}{$type}{$number}{$value} if not $axis_val;
	$action = $external{$prof}{$type}{$number}{$value}{neg} if $axis_val > 0;
	$action = $external{$prof}{$type}{$number}{$value}{pos} if $axis_val < 0;

	# now this should not happen
	return if $type == $AXIS and not $axis_val;

	# loop and execute each action in the order it 
	# was read from the conf file
	foreach (@$action) {
		__execute($_->{command})
			if (not $_->{delay} or not $delay % $_->{delay})
	}
	
	# we only execute only one internal event each loop, so, we'll
	# save it for last but execute the first one we find
	unless ($intern) {
		$intern = $internal{$prof}{$type}{$number}{$value} unless $axis_val;
		$intern = $internal{$prof}{$type}{$number}{$value}{neg} if $axis_val > 0;
		$intern = $internal{$prof}{$type}{$number}{$value}{pos} if $axis_val < 0;
	}
}

# handle AXIS_MOVE events differently
sub execute_axis_move
{
	if ($print_event) {
		my ($number, $delay, $axis_val) = @_;	
		$last_event =  "$AXIS.$number.neg" if $axis_val > 0;
		$last_event =  "$AXIS.$number.pos" if $axis_val < 0;
	}
	else {
		_execute_axis_move($active_profile, @_);
		_execute_axis_move($STICKY_PROFILE_NAME, @_);
	}
}
sub _execute_axis_move
{
	my ($res, $action, $values, $other_axis);
	my ($prof, $number, $delay, $axis_val) = @_;	
	$action = $external{$prof}{$AXIS}{$number}{$AXIS_MOVE}{neg} if $axis_val < 0;
	$action = $external{$prof}{$AXIS}{$number}{$AXIS_MOVE}{pos} if $axis_val > 0;

	# calculate some values
	$other_axis = ($number % 2 == 1)? $number - 1: $number + 1;
	my $other_val = $axis{$other_axis}{value};
	my $pcnt = int(($axis_val * 100) / AXIS_MAX);
	my $other_pcnt = int(($other_val * 100) / AXIS_MAX);
	$pcnt *= -1 if $pcnt < 0;
	$other_pcnt *= -1 if $other_pcnt < 0;

	$values->{v1} = $axis_val;
	$values->{v2} = $other_val;
	$values->{p1} = $pcnt;
	$values->{p2} = $other_pcnt;

	foreach (@$action) {
		
		__execute($_->{command}, $values)
			if (not $_->{delay} or not $delay % $_->{delay});
	}
	
	# we only execute only one internal event each loop, so, we'll
	# save it for last but execute the first one we find
	unless ($intern) {
		$intern = $internal{$prof}{$AXIS}{$number}{$AXIS_MOVE}{neg} if $axis_val > 0;
		$intern = $internal{$prof}{$AXIS}{$number}{$AXIS_MOVE}{pos} if $axis_val < 0;
	}
	

}

# handle STICK MOVE EVENTS
sub execute_stick_move
{
	unless ($print_event) {
		_execute_stick_move($active_profile, @_);
		_execute_stick_move($STICKY_PROFILE_NAME, @_);
	}
}
sub _execute_stick_move
{
	my ($res, $action);
	my ($prof, $number, $delay, $v1, $v2) = @_;	
	$action = $external{$prof}{$STICK}{$number}{$STICK_MOVE};

	# calculate percentages
	my $p1 = int(($v1 * 100) / AXIS_MAX);
	my $p2 = int(($v2 * 100) / AXIS_MAX);

	foreach (@$action) {

		__execute($_->{command}, {
				v1 => $v1,
				v2 => $v2,
				p1 => $p1,
				p2 => $p2,
				
			})
			if (not $_->{delay} or not $delay % $_->{delay});
	}
	
	# we only execute only one internal event each loop, so, we'll
	# save it for last but execute the first one we find
	$intern = $internal{$prof}{$STICK}{$number}{$STICK_MOVE}
		unless ($intern);
}

# expand internal leanstick variables in the command
sub __expand_internal_variables
{
	my ($command, $values) = @_;
	my ($p1, $p2, $v1, $v2);
	if(defined $values) {
		$p1 = $values->{p1};
		$p2 = $values->{p2};
		$v1 = $values->{v1};
		$v2 = $values->{v2};
	}
	else {
		$p1 = 100;
		$p2 = 100;
		$v1 = AXIS_MAX;
		$v2 = AXIS_MAX;
	}

	$command =~ s/\$\{\%\}/$p1/g;
	$command =~ s/\#\{\%\}/$p2/g;
	$command =~ s/\$\{\!\}/$v1/g;
	$command =~ s/\#\{\!\}/$v2/g;

	while ($command =~ m/\$\{(x)?(\d+)\}/) {
		my $val = int($2 * $p1 / 100);
		$val = int($2 * $p1 * $p1/ 10000) if $1;
		$val *= -1 if $p1 < 0 and $1;
		$command =~ s/\$\{$1$2\}/$val/g;
	}
	while ($command =~ m/\#\{(x)?(\d+)\}/) {
		my $val = int($2 * $p2 / 100);
		$val = int($2 * $p2 * $p2/ 10000) if $1;
		$val *= -1 if $p2 < 0 and $1;
		$command =~ s/\#\{$1$2\}/$val/g;
	}

	$command =~ s/\$\{profile\}/$active_profile/g;
	return $command;
}
# execute the given command, expanding the macros
sub __execute 
{
	my ($command, $values) = @_;
	$command = expand_macros($command);
	$command = __expand_internal_variables($command, $values);

	print "$APP_NAME exec: $command\n";
	my $res = system $command;
	print "$command exited with : $res\n" if $res;
	return $res;
}

# add a macro!
sub add_macro
{
	my ($name, $arglist, $def) = @_;
	my @args;
	my %hash;

	@args = split(/ *, */, $arglist) if $arglist;
	my $nargs = @args;

	$hash{definition} = $def;
	$hash{arglist} = \@args;
	$macros{$name}{$nargs} = \%hash;
}


# add an action (!)
sub add_action
{
	my ($action_type, $type, $number, $event, $command, $delay, $axis) = @_;
	my $action;
	my $arrayref;

	# get and clear the comment
	my $comm = $comment;
	$comment = "";

	# make sure the profile exists
	push @profiles, $active_profile unless @profiles;

	# the command is a shell command
	if ($action_type eq ":") {
		$action->{command} = "$command";
		$action->{delay} = $delay;
		$action->{comment} = $comm;

		$external{$active_profile}{$type}{$number}{$event} = []
			unless $external{$active_profile}{$type}{$number}{$event} or $axis;
	
		$external{$active_profile}{$type}{$number}{$event}{$axis} = []
			unless not $axis or $external{$active_profile}{$type}{$number}{$event}{$axis};
		
		$arrayref = $external{$active_profile}{$type}{$number}{$event}{$axis} if $axis;
		$arrayref = $external{$active_profile}{$type}{$number}{$event} if not $axis;
		push @$arrayref, $action;
	}

	# the command is an internal command
	else {
		$internal{$active_profile}{$type}{$number}{$event}{$axis} = $command if $axis;
		$internal{$active_profile}{$type}{$number}{$event} = $command if not $axis;
	}
}

# simply sorts and joins an array
sub combo_hash
{
	my $hash = "";
	my @sorted = sort @_;
	foreach (@sorted) {
		$hash .= "_" . $_;
	}
	return $hash;
}

# determine the buttons/axis to associate the action, then call add_action
sub add_combo_action
{
	my ($combo, $action_type, $command, $delay) = @_;
	my $events;
	my $match;
	my $prev;
	my %hash;

	# loop through the input string
	while ($combo ne "") {
		if ($combo =~ m/^([^+]+)\+(.*)$/) {
			$match = $1;
			$combo = $2;
		}
		else {
			$match = $combo;
			$combo = "";
		}
		
		# match: button X
		if ($match =~ m/^\s*button\s*(\d+)\s*$/i) {
			$prev = $BUTTON;
			$hash{"$BUTTON-$1"} = 1;
		}

		# match: axis X pos/neg
		elsif ($match =~ m/^\s*axis\s*(\d+)\s*((neg)|(pos))?\s*$/i) {
			my $ax = "pos" unless $2;
			$ax = lc $2 if $2;
			$prev = $AXIS;
			$hash{"$AXIS-$1-$ax"} = 1;
		}

		# match a number
		elsif ($match =~ m/^\s*(\d+)\s*$/i) {
				return unless $prev;
				$hash{"$BUTTON-$1"} = 1 if $prev eq $BUTTON;
				$hash{"$AXIS-$1-pos"} = 1 if $prev eq $AXIS;
		}

		# match number and neg/pos
		elsif ($match =~ m/^\s*(\d+)\s*((neg)|(pos))\s*$/i) {
				return unless $prev;
				return unless $prev eq $AXIS;
				$hash{"$AXIS-$1-$2"} = 1 if $prev eq $AXIS;
		}
		else {
			# we shall never accept failure!
			return;
		}
		
	}
	return unless scalar keys(%hash) > 1;
	
	my $combohash = combo_hash(keys %hash);
	add_action($action_type, $COMBO, $combohash, $COMBO_EVENT, $command, $delay);
	
	return 1;
}

sub quit
{
	my $status = shift or 0;
	print "quitting $APP_NAME...\n";
	cleanup();
	exit $status;
}

sub error
{
	print STDERR "$APP_NAME: ";
	print STDERR shift;
	print STDERR "\n";
	exit 1;
}

sub usage
{
	print "$APP_NAME v.$VERSION\n\n";
	print "$APP_NAME reads a configuration file that maps joystick events to\n";
	print "shell commands. By default it looks for a file named .leanstick in the\n";
	print "user's home directory. Use the -f option to specify a different config file.\n";
	print "For a detailed description of the config file's format see the README file.\n\n";
	print "Usage : $APP_NAME.pl [OPTION] ...\n";
	print "  -j <ARG>  joystick, specify the device to use\n";
	print "  -f <ARG>  file, specify the configuration file to use\n";
	print "  -t <NUM>  tap threshold, specify how up to many \n";
	print "            miliseconds an axis event is considered a tap\n";
	print "  -a <NUM>  axis threshold, percentage over which if an\n";
	print "            axis moves it triggers an axis event\n";
	print "  -h        help, print this message\n";
	print "  -q        quit, force any running instance of $APP_NAME to quit\n";
	print "  -v        version, print the version number\n";
	print "  -p        print configuation, prints out the current configuration\n";
	print "  -e        print event, prints out the first joystick event and quits\n";
	print "  -x <ARG>  execute the given command, expanding all the macros\n";
	exit 1;
}

sub version
{
	print "$APP_NAME v.$VERSION a.$API_VERSION\n";
	exit 0;
}

# print the current configuration
sub print_config
{
	my ($t, $n, $e, $a, $actions);
	
	# loop through the profiles
	foreach (@profiles) {
		my $p = $_;

		# profile name
		print ".$p\n";
		my $ext = -2;

		# loop through the profile's actions, 
		# both external and internal
		foreach (\%external, \%internal) {
			$ext++;
			my %mode = %$_;
			my $prof = $mode{$p};
			foreach (keys %$prof) {
				my $type = $prof->{$_};		
				$t = $_;
				foreach (keys %$type) {
					my $num = $type->{$_};		
					$n = $_;
					foreach (keys %$num) {
						my $ev = $num->{$_};		
						$e = $_;
						if ($t eq 2) {
							foreach (keys %$ev) {
								$actions = $ev->{$_};
								$a = $_;
								print "$t.$n.$e.$a\n";
								print_actions($ext, $actions)
							}
						}
						else {
							$actions = $ev;		
							print "$t.$n.$e\n";
							print_actions($ext, $actions)
						}
					}	
				}
			}
		}
	}
	print "===\n";
	# print out the macros
	foreach (keys %macros) {
		my $m = $_;
		my $h1 = $macros{$_};
		foreach (keys %$h1) {
			my $h2 = $h1->{$_};
			print "$m";
			print ".$_" foreach (@{$h2->{arglist}});
			print "\n";
			print $h2->{definition};
			print "\n";
		} 
	}
	exit 0;
}

sub cleanup {
	`rm -rf $ACTIVE_PROFILE_FILE`;
}

sub print_actions
{
	my ($ext, $actions) = @_;
	if ($ext) {
		foreach (@$actions) {
			if ($_->{comment}) {
				print "###\n";
				print $_->{comment};
				print "\n###\n";
			}
			print ":";
			print "(" . $_->{delay} . ")" if $_->{delay};
			print $_->{command} . "\n";
		}
	}
	else {
		print "=$actions\n";
	}
}

sub set_active_profile
{
	my ($n, $offset) = @_;
	if ($profiles_n > 1 and $profiles[$n] eq $STICKY_PROFILE_NAME) {
		# we don't allow to switch to the sticky profile
		return unless $offset;
		$n = ($n + $profiles_n + $offset) % $profiles_n;
	}
	$active_profile = $profiles[$n];
	$active_profile_i = $n;
	`echo .$active_profile > $ACTIVE_PROFILE_FILE`;
}

#############################################33
#Linux::Input::Joystick
#
sub js_init {
	my $js = shift;
	my $filename = shift;
	$js->{fh} = IO::File->new("< $filename");
	$js->{timeout} = 0.01;
	die($!) unless ($js->{fh});
}

sub js_selector {
	my $js = shift;
	unless ($js->{__io_select}) {
    	$js->{__io_select} = IO::Select->new($js->{fh});
	}
	return $js->{__io_select};
}


sub js_poll {
  my $js     = shift;
  my $timeout  = shift || ref($js)->{timeout};
  my $selector = js_selector($js);
  my @ev;
  while ($selector and my ($fh) = $selector->can_read($timeout)) {
    my $buffer;
    my $len = sysread($fh, $buffer, 8); #Linux::Input::Joystick->event_bytes);
	if ($len) {
	    my ($time, $value, $type, $number) = unpack('LsCC', $buffer);
	    my $event = {
    	  time    => $time,
	      type    => $type,
	      number  => $number,
	      value   => $value,
	    };
    	push @ev, $event;
	}
	else {
		print STDERR "leanstick error: Could not poll joystick\n";
    	undef $js->{fh};
    	undef $js->{__io_select};
		undef $selector;
		return undef;
	}
  }
  return @ev;
}
