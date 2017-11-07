#!/bin/sh -eu

script_dir="$(dirname "$0")"
CONFS_DIR="${script_dir:?}/../confs"
DOWNLOADS_DIR="${script_dir:?}/../in"

# shellcheck source=../confs/params.env
. "${CONFS_DIR:?}/params.env"
: "${pgp_ownertrusts:?}"

# Trying to use system ruby, gem, etc is a pain.
# If someone comes up with an fpm alternative in Go or Rust or other sane
# language, I'll jump.  Fast.
#
# We shouldn't need any of this supporting framework.  We have a short-lived OS
# image, it's okay to litter Ruby "Everywhere".

echo "$0: GnuPG SWDB and tarballs signing keys setup"
gpg --import "${CONFS_DIR:?}/pgp-swdb-signing-key.asc" "${CONFS_DIR:?}/tarballs-keyring.asc"

mkdir -pv "${DOWNLOADS_DIR:?}"
cd "${DOWNLOADS_DIR:?}"
echo "Fetching SWDB and verifying"
if [ -f swdb.lst ] && [ -f swdb.lst.sig ]; then
  :
else
  curl -Ss --remote-name-all https://versions.gnupg.org/swdb.lst https://versions.gnupg.org/swdb.lst.sig
fi
for key in $pgp_ownertrusts ; do
  gpg --tofu-policy good ${key%:?:}
done
gpg --tofu-default-policy=unknown --trust-model tofu --verify swdb.lst.sig
