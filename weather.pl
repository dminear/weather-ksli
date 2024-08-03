#!/usr/bin/perl -w
# Program to read KSLI XML weather data.  It writes the XML to memcache for a
# webserver to pick up, and also sends the temperature and humidity to a
# redis database.
#
# Dan Minear

use strict;
use XML::Simple;
use LWP::UserAgent;
use Data::Dumper;
use FileHandle;
use Date::Calc qw(:all);
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use Net::SMTP;
use Cache::Memcached;
use IO::Socket::INET;
use Time::Local;

my %monthlookup = qw(Jan 0 Feb 1 Mar 2 Apr 3 May 4 Jun 5 Jul 6 Aug 7 Sep 8 Oct 9 Nov 10 Dec 11);

my $carbon_port = 2003;
my $carbon_host = "carbonhost.lan";


my $mailhost = "mail.scrappintwins.com";
my $maildestination = 'dan@minear.name';

# where to grab the weather data
my $weatherurl = "http://www.weather.gov/xml/current_obs/KSLI.xml";

# this script used to add the readings onto the end of this file, so there was an option to read the data
# and send it to graphite. We don't append to this script anymore so we could remove this.
#
if (defined $ARGV[0] && $ARGV[0] eq "graphite" ) {	# put the stored values into graphite
	my $sock = IO::Socket::INET->new( 
					PeerAddr => $carbon_host,
					PeerPort => $carbon_port,
					Proto => 'tcp',
					) or die "Cannot open socket: $!";

	while(<DATA>) {
		chomp;
# humid 34   time Wed, 04 Sep 2013 12:58:00 -0700   temp 91.0   weather A Few Clouds   pickper 60   dewpt 58.6   pickup 15 minutes after the hour
		my @l = split /\s+/;
		next if ($l[0] !~ /^humid/ || $l[1] !~ /\d/);
		my $humid = $l[1];
		my $day = $l[4];
		my $month = $l[5];
		my $year = $l[6];
		my $time = $l[7];
		my $temp = $l[10];
		my ($h,$m,$s) = split /:/, $time;
		next if $temp == 0;
			
		my $t = timelocal($s, $m, $h, $day, $monthlookup{$month}, $year);
		
		print "----- $month $day $year $time temp $temp humid $humid ", scalar localtime $t, "\n";
		# now build the string
		my $hmsg = "stats.gauges.weather.KSLI.relative_humidity $humid $t\n";
		my $tmsg = "stats.gauges.weather.KSLI.temp_f $temp $t\n";
		print $sock $hmsg . $tmsg;
	}
	close $sock;
	close DATA;
	exit 0;
}

# connect to memcache
my $memd = new Cache::Memcached {
	'servers' => [ "ops.scrappintwins.com.lan:11211" ],
	'debug' => 0,
	};

my $dry_trigger = 24 * 0.5 * 3;		# 24 hours at 50% relative humidity for 2 days

my %elements = (
	"temp_f" => "temp",
	"dewpoint_f" => "dewpt",
	"relative_humidity" => "humid",
	"weather" => "weather",
	"observation_time_rfc822" => "time",
	"suggested_pickup_period" => "pickper",
	"suggested_pickup" => "pickup",
	);

my $ua = new LWP::UserAgent; $ua->agent("$0/0.1 " . $ua->agent);
$ua->agent("Mozilla/8.0");
# my $proxy = "http://proxy.addr.here:8080";
# $ua->proxy('http', $proxy);

# pretend we are very capable browser
my $req = new HTTP::Request 'GET' => "$weatherurl";
$req->header('Accept' => 'text/xml');

my $last_time = Date_to_Time( Today_and_Now() );
my $last_hum = 100;
my $integrated_dry = 0;
#print "Now is $last_time\n";

my $x;

while (1) {
	#send request
	my $res = $ua->request($req);
	#check the outcome
	if ($res->is_success) {
		eval { $x = XMLin( $res->content );
			$memd->set("weather", $res->content);
		};
		if ($@) {	# error
			sleep 120;
			next;	# try again
		}
		my @t = localtime(time);
		print join( ':',@t[2,1,0]), " ";
		my $fo = new FileHandle( ">>/tmp/$$.txt") or warn "Cannot append to /tmp/$$.txt\n";
		my $udpsock = IO::Socket::INET->new(
			PeerPort => 8125,
			#PeerAddr => 'stats.minear.homeunix.com',
			PeerAddr => 'ops.scrappintwins.com.lan',
			Proto => 'udp') or warn "Cannot connect to udp socket\n";

		foreach my $i (sort keys( %elements)) {
			print $elements{$i} . " " . $x->{$i} . ", " if $i =~ /temp|humid|weather|time/;

			$udpsock->send("weather.KSLI.$i:" . $x->{$i} . "|g\n") if defined $udpsock && $i =~ /temp|humid/;
			print $fo $elements{$i} . " " . $x->{$i} . "   " if defined $fo;
		}		

		print "\n";
		print $fo "\n" if defined $fo;

		$udpsock->close if defined $udpsock;

		#All this means is you got some html back . . .

		$x->{"observation_time_rfc822"} =~ /\w+,\s+(\d+)\s+(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)/;
		my @obs_time = ($3, Decode_Month($2), $1, $4, $5, $6);
		my $obs_time = Date_to_Time(@obs_time);
		my $hum  = $x->{"relative_humidity"};
		#print "Observation time is $obs_time and humidity is $hum\n";
		if ($last_time < $obs_time && $hum >=0 && $hum <=100 ) {	# calculate
			my $time_diff  = ($obs_time - $last_time) / 3600;
			print "Time difference is $time_diff hours, performing calculations.\n";
			# figure the dryness
			my $drystart = 100 - $last_hum;
			my $dryend = 100 - $hum;
			my $min = min $drystart, $dryend;
			my $max = max $drystart, $dryend;

			my $rect_area = $min * $time_diff;
			my $tri_area = 0.5 * ($max - $min) * $time_diff;
			$integrated_dry += ($rect_area + $tri_area) / 100;

			# check weather for rain
			if ($x->{weather} =~ /Rain/) {
				print "Rain in weather, resetting.\n";
				print $fo "Rain in weather, resetting integrated dryness.\n" if defined $fo;
				$integrated_dry = 0;
			}

			# save for next time
			$last_time = $obs_time;
			$last_hum = $hum;
			print "Integrated dryness is $integrated_dry / $dry_trigger\n";
			if ($integrated_dry > $dry_trigger) {
				trigger( $fo );
				$integrated_dry = 0;	# reset
			}
		}
		undef $fo;	# close file

		if ($x->{suggested_pickup_period} > 0) {
			# figure wait time
			my $minutes = (Localtime())[4];
			#print "current minutes is $minutes\n";
			$x->{suggested_pickup} =~ /(\d+)/;
			my $sugg_pickup = $1;
			my $minutes_to_pickup = $x->{suggested_pickup_period} - $minutes + $sugg_pickup;
			if ($minutes_to_pickup > $x->{suggested_pickup_period} - 1 + $sugg_pickup) {
				$minutes_to_pickup -= $x->{suggested_pickup_period};
			}
			# randomize the pickup a little
			my $sleeptime = $minutes_to_pickup * 60 + int(rand(300)) + 120;
			#print "sleeping suggested time of " . $sleeptime / 60 . " minutes\n";
			sleep $sleeptime;
		} else {
			sleep 3600;		# sleep an hour
		}
	} else {
		print "Error: " . $res->status_line . "\n";
	}
}

sub trigger {
	my $fo = shift;
	print "TRIGGER!!!!\n";
	print $fo "TRIGGER!!!\n" if defined $fo;

	# send email
	my $smtp = Net::SMTP->new($mailhost);
	if (defined $smtp) {
		$smtp->mail($ENV{USER});
		$smtp->to("pager");
		$smtp->data();
		$smtp->datasend("To: $maildestination\n");
		$smtp->datasend("Subject: Sprinkler trigger\n");
		$smtp->datasend("\n");
		$smtp->datasend("Sprinkler trigger\n");
		$smtp->dataend();
		$smtp->quit;
	} else {
		print $fo "Could not mail, bummer.\n" if defined $fo;
	}
}

__END__
