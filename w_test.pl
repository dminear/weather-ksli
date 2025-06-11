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
#use Memcached::Client;
use IO::Socket::INET;
use Time::Local;
use Redis::Client;
use Carp;
use Env;

my $debug = 0;

my $redishost = $ENV{'REDISHOST'} || 'localhost';
my $memcachehost = $ENV{'MEMCACHEHOST'} || 'localhost';
my $web = $ENV{'WEB'} || 'local';

if ($web eq 'local') {
	print "Using local data file\n";
} else {
	print "Using web request for data\n";
}

my %monthlookup = qw(Jan 0 Feb 1 Mar 2 Apr 3 May 4 Jun 5 Jul 6 Aug 7 Sep 8 Oct 9 Nov 10 Dec 11);

# where to grab the weather data
my $weatherurl = "http://www.weather.gov/xml/current_obs/KSLI.xml";

print "connecting to redis host $redishost\n";
my $redis = Redis::Client->new( 'host' => $redishost, port => 6379 );

# connect to memcache
print "connecting to memcache host $memcachehost\n";
my $memd = new Cache::Memcached {
#my $memd = Memcached::Client->new( {
	'servers' => [ $memcachehost . ":11211" ],
	'debug' => 0,
	};

my %elements = (
	"temp_f" => "temp",
	"dewpoint_f" => "dewpt",
	"relative_humidity" => "humid",
	"weather" => "weather",
	"observation_time_rfc822" => "time",
	"suggested_pickup_period" => "pickper",
	"suggested_pickup" => "pickup",
	);

my @content;
while(<DATA>) {
	chomp;
	if ($web eq 'local') {
		push @content, $_;
	}
}

my $ua = new LWP::UserAgent; $ua->agent("$0/0.1 " . $ua->agent);
$ua->agent("Mozilla/8.0");
# my $proxy = "http://proxy.addr.here:8080";
# $ua->proxy('http', $proxy);

# pretend we are very capable browser
my $req = new HTTP::Request 'GET' => "$weatherurl";
$req->header('Accept' => 'text/xml');

my $last_time = Date_to_Time( Today_and_Now() );
my $x;

#print "\n\ncontent is\n\n" . Dumper(@content);

while (1) {
	#send request
	my $res = $ua->request($req);
	#check the outcome
	if ($res->is_success || defined $content[0] ) {
		eval {
			if (defined $content[0]) {
				$x = XMLin( join "", @content );
				#print "content:", Dumper($x);
				print "setting memcache...\n";
				$memd->set("weather", join "", @content);
			} else {
				print "\n\nusing web!\n\n";
				$x = XMLin( $res->content );
				print "setting memcache...\n";
				$memd->set("weather", $res->content);

				$req = new HTTP::Request 'GET' => "https://forecast.weather.gov/data/METAR/KSLI.1.txt";
				$req->header('Accept' => 'text/plain');
				$res = $ua->request($req);

				if($res->is_success) {
					$redis->hset('weather', 'METAR', grep( /^METAR/, split( /\n/, $res->content )));
				}
			}
			print "\n\nsetting redis...\n\n";
			foreach (keys %$x)  {
				#print "key ", $_, " value ",  $x->{$_}, "\n";
				$redis->hset('weather', $_, $x->{$_} );
			}
			print "done\n";
		};
		#print "Content: " . $res->content;
		#print Dumper( $x );

		if ($@) {	# error
			print "error retrieving page, waiting...\n";
			sleep 120;
			next;	# try again
		}

		if ($debug) {
			my @t = localtime(time);
			print join( ':',@t[2,1,0]), " ";
			my $fo = new FileHandle( ">>$$.txt") or warn "Cannot append to $$.txt\n";
			foreach my $i (sort keys( %elements)) {
				print $elements{$i} . " " . $x->{$i} . ", " if $i =~ /temp|humid|weather|time/;
				print $fo $elements{$i} . " " . $x->{$i} . "   " if defined $fo;
			}		
			print "\n";
			print $fo "\n" if defined $fo;
			#All this means is you got some html back . . .
			undef $fo;	# close file
		}

		#print ">>>>>>>>>>>> memcache value for key weather is:\n" . $memd->get("weather");

		#print ">>>>>>>>>>>> redis hash is\n" . Dumper($redis->hgetall('weather'));


		# wait for the next time
		if ($x->{suggested_pickup_period} > 0) {
			# figure wait time
			my $minutes = (Localtime())[4];
			#print "current minutes is $minutes\n";
			$x->{suggested_pickup} =~ /(\d+)/;
			my $sugg_pickup = $1;		# what minute in the hour
			my $minutes_to_pickup = $x->{suggested_pickup_period} - $minutes + $sugg_pickup;
			if ($minutes_to_pickup > $x->{suggested_pickup_period} - 1 + $sugg_pickup) {
				$minutes_to_pickup -= $x->{suggested_pickup_period};
			}
			# randomize the pickup a little
			my $sleeptime = $minutes_to_pickup * 60 + int(rand(300)) + 120;
			print "sleeping suggested time of " . $sleeptime / 60 . " minutes\n";
			sleep $sleeptime;
		} else {
			print "waiting for an hour...\n";
			sleep 3600;		# sleep an hour
		}
	} else {
		print "Error: " . $res->status_line . "\n";
	}
}

__DATA__
<?xml version="1.0" encoding="ISO-8859-1"?>
<?xml-stylesheet href="latest_ob.xsl" type="text/xsl"?>
<current_observation version="1.0" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.weather.gov/view/current_observation.xsd">
<credit>NOAA's National Weather Service</credit><credit_URL>https://weather.gov/</credit_URL>
<image><url>http://forecast.weather.gov/images/xml_badge.png</url>
<title>NOAA's National Weather Service</title>
<link>https://www.weather.gov</link></image><suggested_pickup>15 minutes after the hour</suggested_pickup>
<suggested_pickup_period>60</suggested_pickup_period><location>Los Alamitos Army Airfield, CA</location>
<station_id>KSLI</station_id><latitude>33.79628</latitude><longitude>-118.04179</longitude>
<observation_time>Last Update on Jun 9 2025, 8:55 am PDT</observation_time>
<observation_time_rfc822>Mon, 09 Jun 2025 08:55:00 -0700</observation_time_rfc822>
<weather>OvercastClouds</weather><temperature_string>63.5 F (17.5 C)</temperature_string>
<temp_f>63.5</temp_f>
<temp_c>17.5</temp_c>
<relative_humidity>85</relative_humidity><wind_string>Southeast at 4.6 MPH (4 KT)</wind_string><wind_dir>Southeast</wind_dir><wind_degrees>150</wind_degrees>
<wind_mph>4.6</wind_mph><wind_kt>4</wind_kt><pressure_string>1013.8 mb</pressure_string>
<pressure_mb>1013.8</pressure_mb><pressure_in>29.93</pressure_in><dewpoint_string>58.8 F (14.9 C)</dewpoint_string>
<dewpoint_f>58.8</dewpoint_f><dewpoint_c>14.9</dewpoint_c>
<visibility_mi>10.00</visibility_mi><icon_url_base>http://forecast.weather.gov/images/wtf/small/</icon_url_base><two_day_history_url>http://forecast.weather.gov/data/obhistory/KSLI.html</two_day_history_url>
<icon_url_name>ovc.png</icon_url_name>
<ob_url>http://forecast.weather.gov/data/METAR/KSLI.1.txt</ob_url><disclaimer_url>https://www.weather.gov/disclaimer.html</disclaimer_url>
<copyright_url>https://www.weather.gov/disclaimer.html</copyright_url><privacy_policy_url>https://www.weather.gov/notice.html</privacy_policy_url></current_observation>
