#!/bin/bash -eu

REPO="${1:?need an apt repo line}"

readonly cacert_dir=/usr/local/share/ca-certificates
readonly certin_dir=/vagrant/certs

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
pt_apt_get() { apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" "$@"; }

pt_apt_get install ca-certificates

mkdir -pv "$cacert_dir"
for F in "$certin_dir"/*.pem
do
  T="$(basename "$F")"
  T="${T%.pem}.crt"
  cp -v "$F" "$cacert_dir/$T"
done
update-ca-certificates

printf "%s\n" > /etc/apt/sources.list.d/gnupg-builds.list "$REPO"
case "$REPO" in
  *https:*)
    t1="${REPO#deb https://}"
    echo > /etc/apt/apt.conf.d/71noproxy "Acquire::https::Proxy::${t1%%/*} \"DIRECT\";"
    ;;
esac

pt_apt_get update

bootstrap_via_older_ptgnupg=false
case "$(lsb_release -sc)" in
xenial)
  # The GnuPG2 does not handle the Ed25519 signature used for
  # signing the GnuPG 2.2.22 release
  bootstrap_via_older_ptgnupg=true
  ;;
esac

if "$bootstrap_via_older_ptgnupg"; then
  echo >&2 'Installing older version of optgnupg-gnupg to bootstrap'
  pt_apt_get install optgnupg-gnupg
  touch /var/run/bootstrap.older.optgnupg-gnupg
fi
