#!/usr/bin/perl -w
#
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
my $carbon_host = "stats.minear.homeunix.com";

my $mailhost = "mail.minear.homeunix.com";
my $maildestination = 'dan@minear.name';

if (defined $ARGV[0] && $ARGV[0] eq "graphite" ) {	# put the stored values into graphite
	my $sock = IO::Socket::INET->new( 
					PeerAddr => $carbon_host,
					PeerPort => $carbon_port,
					Proto => 'tcp',
					);
	die "Cannot open socket: $!" if ! $sock;
	my $fin = FileHandle->new("/tmp/$0") || die "Cannot read /tmp/$0: $!";

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


my $memd = new Cache::Memcached {
	'servers' => [ "192.168.0.30:11211" ],
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
my $location = "http://www.weather.gov/xml/current_obs/KSLI.xml";

my $myurl = $location;
my $ua = new LWP::UserAgent; $ua->agent("$0/0.1 " . $ua->agent);
$ua->agent("Mozilla/8.0");
# my $proxy = "http://proxy.addr.here:8080";
# $ua->proxy('http', $proxy);

# pretend we are very capable browser
my $req = new HTTP::Request 'GET' => "$myurl";
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
		if ($@) {
			sleep 120;
			next;
		}
		my @t = localtime(time);
		print join( ':',@t[2,1,0]), " ";
		my $fo = new FileHandle( ">>/tmp/$0"  );
		my $udpsock = IO::Socket::INET->new(PeerPort => 8125, PeerAddr => 'stats.minear.homeunix.com', Proto => 'udp');
		if (defined $fo) {	
			foreach my $i (sort keys( %elements)) {
				print $elements{$i} . " " . $x->{$i} . ", " if $i =~ /temp|humid|weather|time/;

				$udpsock->send("weather.KSLI.$i:" . $x->{$i} . "|g\n") if defined $udpsock && $i =~ /temp|humid/;
				print $fo $elements{$i} . " " . $x->{$i} . "   ";
			}		

			print "\n";
			print $fo "\n";
		}
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
				print $fo "Rain in weather, resetting integrated dryness.\n";
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
	} else {
		print "Error: " . $res->status_line . "\n";
	} 
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
		sleep 3600;
	}
}

sub trigger {
	my $fo = shift;
	print "TRIGGER!!!!\n";	
	if(defined $fo) {
		print $fo "TRIGGER!!!\n";
	}
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
		print $fo "Could not mail, bummer.\n";
	}
}

__END__
