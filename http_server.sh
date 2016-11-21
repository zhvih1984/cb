#!/bin/ash
set -eu

if [ -n "${USER_ID:-}" ] && [ -n "${GROUP_ID:-}" ]; then
  echo "Changing user id to $USER_ID and group id to $GROUP_ID"
  deluser www
  addgroup -S -g $GROUP_ID www
  adduser -S -G www -u $USER_ID www
fi

echo "Starting as user id $(id -u www) and group id $(getent group www | cut -d : -f 3)"

/sbin/su-exec www /usr/local/bin/ruby /opt/http_server.rb
