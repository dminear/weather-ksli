FROM amd64/perl:5.38
LABEL author="Dan Minear <dan@minear.name>"
RUN apt-get -y update && apt-get -y install apt-utils curl wget
RUN apt-get -y install build-essential 
RUN apt-get -y install openssl
RUN apt-get -y install libexpat1-dev libssl-dev zlib1g-dev 
RUN cpanm --force Net::HTTP
RUN cpanm IO::Socket::SSL
RUN cpanm XML::Simple
RUN cpanm Redis::Client
RUN cpanm LWP::UserAgent
RUN cpanm LWP::Protocol::https
RUN cpanm Net::SSLeay
RUN cpanm File::Slurp
RUN cpanm -f Date::Calc
RUN cpanm Cache::Memcached
COPY weather.pl  /usr/local/bin/
COPY w_test.pl  /usr/local/bin/
RUN chmod +x /usr/local/bin/weather.pl
RUN chmod +x /usr/local/bin/w_test.pl
RUN chmod 777 /tmp
#CMD ["perl", "/usr/local/bin/weather.pl"]
CMD ["perl", "/usr/local/bin/w_test.pl"]
