#!/bin/sh -eu

umask 022
export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
pt_apt_get() { apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" "$@"; }

echo "$0: basic system package updates"
rm -f /etc/timezone
echo UTC > /etc/timezone
dpkg-reconfigure tzdata
unset TZ

# If we have override packages for this OS for anything installed as a
# build-dep below then we'll need the key trusted early.
# (This bit me with `jq` on trusty).
apt-key add /vagrant/confs/apt-repo-keyring.asc

if [ -f /tmp/done.gnupg.baseupdate ]; then
  echo "$0: skipping core update/upgrade"
else
  pt_apt_get update
  # no ability to sanely replace kernels, while Vagrant should have gotten a
  # recent enough system for us, that for our purposes whatever kernel
  # we have is fine.  So stick to `upgrade` not `dist-upgrade`
  pt_apt_get upgrade
  pt_apt_get autoremove
  dpkg -l | grep '^rc' | awk '{ print $2 }' | xargs apt-get --assume-yes purge
  date > /tmp/done.gnupg.baseupdate
fi

echo "$0: apt packages for building GnuPG and friends"

# For when we support getting "current versions" direct from repo:
pt_apt_get install apt-transport-https

pt_apt_get install build-essential
case $(lsb_release -sc) in
  trusty)
    pt_apt_get install automake
    pt_apt_get build-dep gnutls28
    ;;
  *)
    pt_apt_get build-dep gnutls-bin
    ;;
esac

# Be careful to not include here
pt_apt_get build-dep gnupg2 pinentry
pt_apt_get install libsqlite3-dev libncurses5-dev lzip jq xz-utils
# ruby-dev for fpm;
# python-pip for our build scripts; probably xenial?  trusty wants python3-pip
pt_apt_get install ruby ruby-dev python3 git curl python-pip python3-pip

# Ideally we'd not use root for fpm/ruby but it's a short-lived OS image.
# Doing this as the user is "not sane", alas.  Could use rbenv etc, but
# that's a lot of framework and interpreter compilation when we just want
# fpm as a means to an end.
echo "$0: gem install fpm"
gem install --no-ri --no-rdoc fpm

echo "$0: pip install requests"
pip install requests

echo "$0: OS-agnostic package installer wrapper"
mkdir -pv /usr/local/bin
cat > /usr/local/bin/pt-build-pkg-install <<'EOBPI'
#!/bin/sh
exec sudo dpkg -i "$@"
EOBPI
chmod 755 /usr/local/bin/pt-build-pkg-install

# -----------------------------8< cut here >8-----------------------------
# If we ever have non-debian stuff, we'll probably want to move stuff after
# here out to a separate root-run setup stage.
mkdir -pv /out
chown -R "${SUDO_UID:-vagrant}:${SUDO_GID:-vagrant}" /out
