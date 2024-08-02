FROM debian
MAINTAINER Dan Minear <dan@minear.name>
RUN apt-get -y update && apt-get -y install apt-utils
RUN apt-get -y install build-essential 
RUN apt-get -y install openssl
RUN apt-get -y install libexpat1-dev libssl-dev zlib1g-dev 
RUN echo y | cpan XML::Simple
RUN cpan Net::SSLeay
RUN cpan IO::Socket::SSL
RUN cpan LWP::UserAgent
RUN cpan LWP::Protocol::https
RUN cpan -f Date::Calc
RUN cpan Cache::Memcached
COPY weather.pl  /usr/local/bin/
RUN chmod +x /usr/local/bin/weather.pl
RUN chmod 777 /tmp
CMD ["perl", "/usr/local/bin/weather.pl"]
