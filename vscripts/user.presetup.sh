#!/bin/sh -eu

# shellcheck source=../confs/params.env
. /vagrant/confs/params.env

# Trying to use system ruby, gem, etc is a pain.
# If someone comes up with an fpm alternative in Go or Rust or other sane
# language, I'll jump.  Fast.
#
# We shouldn't need any of this supporting framework.  We have a short-lived OS
# image, it's okay to litter Ruby "Everywhere".

# We use --batch because Vagrant doesn't supply a tty during provision and some
# versions of GnuPG require it.

echo "$0: GnuPG SWDB and tarballs signing keys setup"
gpg --batch --import /vagrant/confs/pgp-swdb-signing-key.asc /vagrant/confs/tarballs-keyring.asc
# We'd like to use:  gpg --tofu-policy good $swdb_key
# but we don't yet know that we have a version of GnuPG good enough
# so instead we hard-code as trusted the keys we verify against.
printf "%s\n" "$pgp_ownertrusts" | xargs -n 1 | gpg --batch --import-ownertrust
gpg --batch --check-trustdb

mkdir -pv ~/src
cd ~/src
echo "Fetching SWDB and verifying"
if [ -f swdb.lst ] && [ -f swdb.lst.sig ]; then
  :
else
  if curl -Ss --remote-name-all https://versions.gnupg.org/swdb.lst https://versions.gnupg.org/swdb.lst.sig
  then
    :
  elif [ -f /in/swdb.lst ]; then
    echo >&2 "$0: WARNING: versions.gnupg.org down?"
    echo >&2 "$0: using possibly stale date from /in/swdb.lst"
    cp /in/swdb.* .
  fi
fi
# On stretch/GnuPG-2.1.18, there's no implicit file, so specify it explicitly.
gpg --batch --trust-model direct --verify swdb.lst.sig swdb.lst

