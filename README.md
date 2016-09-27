## Perl program to query National Weather Service

The weather.pl script runs in a Perl Docker container and queries the XML data
for KSLI Los Alamitos, which is an airport near my home.  It parses it up and
stores it to a memcache server for later pickup from a webserver.  It also
stores a summary data line on the end of the script. This has been changed to
store in a file.

This was made to be a detector for turning on the sprinklers, which has yet 
to be hooked up.  The idea is that over time we try to integrate how "dry"
the environment is by looking at the humidity and temperature and then 
come up with a trigger that should water the lawn.

The getweather.pl is a cgi-bin script that grabs the memcache data and serves
it out. As you can see, the script is rather short so there's not a lot to do.

Figuring out the sprinkler time seems easy in theory, but in practice it's
difficult.

This is my experiment with automated Docker builds.

You can see the program in use at
http://www.scrappintwins.com/cgi-bin/getweather.pl. It looks a little funky
because it's just the XML, but I could get the XSL file to translate to
pretty XHTML.
