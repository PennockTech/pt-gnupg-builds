#!/bin/sh -eu

umask 022
export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
pt_apt_get() { apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" "$@"; }
rm -f /etc/timezone
echo UTC > /etc/timezone
dpkg-reconfigure tzdata
unset TZ
pt_apt_get update
pt_apt_get dist-upgrade
pt_apt_get autoremove
dpkg -l | grep '^rc' | awk '{ print $2 }' | xargs apt-get --assume-yes purge
