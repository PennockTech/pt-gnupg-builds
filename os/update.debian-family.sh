#!/bin/sh -eu

umask 022
export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
pt_apt_get() { apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" "$@"; }

echo "$0: basic system package updates"
rm -f /etc/timezone
echo UTC > /etc/timezone
want_install_tzdata=false
if dpkg -s tzdata >/dev/null 2>&1; then
  dpkg-reconfigure tzdata
else
  want_install_tzdata=true
fi
unset TZ

if [ -f /tmp/done.gnupg.baseupdate ]; then
  echo "$0: skipping core update/upgrade"
else
  if ! grep -q '^deb-src' /etc/apt/sources.list; then
    sed -n 's/^deb /deb-src /p' < /etc/apt/sources.list > /etc/apt/sources.list.d/std-sources.list
  fi

  pt_apt_get update
  # no ability to sanely replace kernels, while Vagrant should have gotten a
  # recent enough system for us, that for our purposes whatever kernel
  # we have is fine.  So stick to `upgrade` not `dist-upgrade`
  pt_apt_get upgrade
  pt_apt_get autoremove
  if $want_install_tzdata; then
    pt_apt_get install tzdata
  fi
  dpkg -l | grep '^rc' | awk '{ print $2 }' | xargs apt-get --assume-yes purge
  date > /tmp/done.gnupg.baseupdate
fi

### AT THIS POINT: we can install extra packages
# In order to use `apt-key add` we need gnupg* installed.
if which gpg >/dev/null 2>&1 || which gpg2 >/dev/null 2>&1; then
  true
else
  pt_apt_get install gnupg2
fi

### THIS WILL NEED A GNUPG PACKAGE OF SOME KIND:
# If we have override packages for this OS for anything installed as a
# build-dep below then we'll need the key trusted early.
# (This bit me with `jq` on trusty).
apt-key add /vagrant/confs/apt-repo-keyring.asc


echo "$0: apt packages for building GnuPG and friends"

# For when we support getting "current versions" direct from repo:
pt_apt_get install apt-transport-https

pt_apt_get install build-essential lsb-release
case $(lsb_release -sc) in
  *)
    pt_apt_get build-dep gnutls-bin
    ;;
esac

# Be careful to not include [ed: what???] here
pt_apt_get build-dep gnupg2 pinentry
# We include sqlite3 because our package now declares a dependency upon it,
# as the most portable (albeit _wrong_) way to get sqlite and readline libs
# of the correct versions installed.
pt_apt_get install libsqlite3-dev libncurses5-dev lzip jq xz-utils sqlite3
# ruby-dev for fpm;
#
# python-pip for our build scripts; probably xenial?  trusty wants python3-pip
# Focal no longer has python-pip.  All seem to have python3-pip.
pt_apt_get install ruby ruby-dev python3 git curl python3-pip
pt_apt_get install python-pip || true

# gnutls aux tools: libopts25 libunbound2
# pinentry: libsecret-1-0
unbound=libunbound2
if apt-cache show libunbound8 >/dev/null 2>&1; then unbound=libunbound8; fi
pt_apt_get install libopts25 $unbound libsecret-1-0
unset unbound

# Ideally we'd not use root for fpm/ruby but it's a short-lived OS image.
# Doing this as the user is "not sane", alas.  Could use rbenv etc, but
# that's a lot of framework and interpreter compilation when we just want
# fpm as a means to an end.
#
# nb 2019-05: fpm now requires ruby2, trusty is 1.9.1 by default; also
#             Gem::Version not yet part of stdlib there.
if ruby -e 'if !RUBY_VERSION.start_with?("1."); then exit(1); end'; then
  echo "$0: installing ruby2.0 on ancient system"
  #
  # ouch; instead of:
  ##pt_apt_get install ruby2.0
  ##gem_cmd='gem2.0'
  #
  # we hit gem2.0 "uninitialized constant Gem::SafeYAML"
  # because gem2.0 triggers
  # which leads to <https://www.mail-archive.com/search?l=ubuntu-bugs@lists.ubuntu.com&q=subject:%22%5C%5BBug+1777174%5C%5D+Re%5C%3A+2.0.0.484%5C-1ubuntu2.10+triggers+uninitialized+constant+Gem%5C%3A%5C%3ASafeYAML+on+calling+gem2.0+install%22&o=newest&f=1>
  #
  pt_apt_get install ruby2.0=2.0.0.484-1ubuntu2 libruby2.0=2.0.0.484-1ubuntu2 libffi-dev ruby2.0-dev build-essential
  ruby2.0 -S gem install psych --version 2.0.17
  pt_apt_get install ruby2.0 libruby2.0
  gem_cmd='ruby2.0 -r yaml -r rubygems/safe_yaml -S gem2.0'
  #
else
  gem_cmd='gem'
fi
echo "$0: $gem_cmd install fpm"
$gem_cmd install --no-ri --no-rdoc fpm

pip_cmd=pip
if which pip3 >/dev/null 2>&1; then pip_cmd=pip3; fi
echo "$0: $pip_cmd install requests"
$pip_cmd install requests

echo "$0: OS-agnostic package installer wrapper"
sudo='sudo'
if ! which sudo >/dev/null 2>&1; then sudo=''; fi
mkdir -pv /usr/local/bin
cat > /usr/local/bin/pt-build-pkg-install <<EOBPI
#!/bin/sh
exec $sudo dpkg -i "\$@"
EOBPI
chmod 755 /usr/local/bin/pt-build-pkg-install
cat > /usr/local/bin/pt-build-pkg-uninstall <<EOBPU
#!/bin/sh
$sudo dpkg -r "\$@"
$sudo dpkg -P "\$@"
EOBPU
chmod 755 /usr/local/bin/pt-build-pkg-uninstall

# We really need to nuke any system headers for libgmp
pt_apt_get remove libgmp-dev:amd64 || true
pt_apt_get remove libgmp-dev || true

# -----------------------------8< cut here >8-----------------------------
# If we ever have non-debian stuff, we'll probably want to move stuff after
# here out to a separate root-run setup stage.
mkdir -pv /out
# Let the chown fail, as it will in docker as root
chown -R "${SUDO_UID:-vagrant}:${SUDO_GID:-vagrant}" /out || true
