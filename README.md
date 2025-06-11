## Perl program to query National Weather Service

The weather.pl script runs in a Perl Docker container and queries the XML data
for KSLI Los Alamitos.  It parses it up and
stores it to a redis server for later pickup from a webserver.

The getweather.pl is a cgi-bin script that grabs the memcache data and serves
it out. As you can see, the script is rather short so there's not a lot to do.
