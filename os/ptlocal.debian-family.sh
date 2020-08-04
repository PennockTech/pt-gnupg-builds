#!/bin/sh -eu

# Before I added this fallback logic, we were fine; we'd abort and no proxy would be setup.
# Then one time I paniced a little at an error message in output, so decided it
# might be better to be more explicit.
# Besides, we do want a proxy if the system is LSB, so using the fallback improves the odds of cachable setup.

if ! lsb_release="$(lsb_release -sc)"
then
  if test -f /etc/lsb-release; then
    . /etc/lsb-release
    lsb_release="$DISTRIB_CODENAME"
  else
    printf >&2 '%s: %s\n' "$(basename "$0" .sh)" "unknown release, can't find LSB, no proxy being setup (probably fine)"
    exit 1
  fi
fi

case "$lsb_release" in
*)
  cat > /etc/apt/apt.conf.d/70proxy <<'EOPROXY'
Acquire::http::Proxy "http://cheddar.lan:3142";
EOPROXY
  ;;
esac
