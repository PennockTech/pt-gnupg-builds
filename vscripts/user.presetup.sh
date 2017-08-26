#!/bin/sh -eu

# shellcheck source=../params.env
. /vagrant/params.env

# Trying to use system ruby, gem, etc is a pain.
# If someone comes up with an fpm alternative in Go or Rust or other sane
# language, I'll jump.  Fast.
#
# We shouldn't need any of this supporting framework.  We have a short-lived OS
# image, it's okay to litter Ruby "Everywhere".

echo "$0: GnuPG SWDB and tarballs signing keys setup"
gpg --import /vagrant/pgp-swdb-signing-key.asc /vagrant/tarballs-keyring.asc
# We'd like to use:  gpg --tofu-policy good $swdb_key
# but we don't yet know that we have a version of GnuPG good enough
# so instead we hard-code as trusted the keys we verify against.
printf "%s\n" "$pgp_ownertrusts" | xargs -n 1 | gpg --import-ownertrust
gpg --check-trustdb

mkdir -pv ~/src
cd ~/src
echo "Fetching SWDB and verifying"
if [ -f swdb.lst ] && [ -f swdb.lst.sig ]; then
  :
else
  curl -Ss --remote-name-all https://versions.gnupg.org/swdb.lst https://versions.gnupg.org/swdb.lst.sig
fi
gpg --trust-model direct --verify swdb.lst.sig

