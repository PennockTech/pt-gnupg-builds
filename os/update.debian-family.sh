#!/bin/sh -eu

umask 022
export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
pt_apt_get() { apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" "$@"; }

echo "$0: basic system package updates"
rm -f /etc/timezone
echo UTC > /etc/timezone
dpkg-reconfigure tzdata
unset TZ
pt_apt_get update
# no ability to sanely replace kernels, while Vagrant should have gotten a
# recent enough system for us, that for our purposes whatever kernel
# we have is fine.  So stick to `upgrade` not `dist-upgrade`
pt_apt_get upgrade
pt_apt_get autoremove
dpkg -l | grep '^rc' | awk '{ print $2 }' | xargs apt-get --assume-yes purge

echo "$0: apt packages for building GnuPG and friends"

# For when we support getting "current versions" direct from repo:
pt_apt_get install apt-transport-https

pt_apt_get install build-essential
pt_apt_get build-dep gnupg2 pinentry gnutls-bin
pt_apt_get install libsqlite3-dev libncurses5-dev lzip jq xz-utils
# ruby-dev for fpm
pt_apt_get install ruby ruby-dev python3 git curl

# Ideally we'd not use root for fpm/ruby but it's a short-lived OS image.
# Doing this as the user is "not sane", alas.  Could use rbenv etc, but
# that's a lot of framework and interpreter compilation when we just want
# fpm as a means to an end.
echo "$0: gem install fpm"
gem install --no-ri --no-rdoc fpm
