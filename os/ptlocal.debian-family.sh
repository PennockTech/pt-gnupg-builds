#!/bin/sh -eu

case "$(lsb_release -sc)" in
trusty)
  # My creaking proxy is not working for HTTPS with Trusty
  true
  ;;
*)
  cat > /etc/apt/apt.conf.d/70proxy <<'EOPROXY'
Acquire::http::Proxy "http://cheddar.lan:3142";
EOPROXY
  ;;
esac
