#!/bin/sh -eu

case "$(lsb_release -sc)" in
*)
  cat > /etc/apt/apt.conf.d/70proxy <<'EOPROXY'
Acquire::http::Proxy "http://cheddar.lan:3142";
EOPROXY
  ;;
esac
