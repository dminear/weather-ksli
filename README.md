## Perl program to query National Weather Service

This scirpt queries for the XML for KSLI Los Alamitos, parses it up,
and stores it to a memcache server for later pickup from a webserver.  It
also stores a summary data line on the end of the script.

This was made to be a detector for turning on the sprinklers, which has yet 
to be hooked up.  The idea is that over time we try to integrate how "dry"
the environment is by looking at the humidity and temperature and then 
come up with a trigger that should water the lawn.

Seems easy in theory, but in practice it's difficult.

This is my experiment with automated Docker builds.

You can see the program in use at http://www.scrappintwins.com/cgi-bin/getweather.pl
