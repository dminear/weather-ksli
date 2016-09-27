#!/usr/bin/perl -w
#
# This is a script that can be put in the cgi-bin directory of
# a webserver to query Memcache and display the last updated
# weather data.

use Cache::Memcached;

my $memd = new Cache::Memcached {
	'servers' => [ "localhost:11211" ],
	'debug' => 0,
};

my $w = $memd->get("weather");

print "Content-type: text/xml\n\n";

if ($w) {
	print $w;
} else {
	print "Nothing found\n";
}
