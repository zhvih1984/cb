FROM ruby:alpine

RUN \
  apk --no-cache add su-exec && \
  gem install sinatra && \
  addgroup -S -g 500 www && \
  adduser -S -G www -u 500 www && \
  mkdir /opp

ADD http_server.rb /opt/http_server.rb
ADD http_server.sh /usr/local/bin/http_server
RUN chmod +x /usr/local/bin/http_server

CMD ["/usr/local/bin/http_server"]
