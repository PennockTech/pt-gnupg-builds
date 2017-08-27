#!/bin/bash -eu

cd ~/src

readonly env_file='./build-env.bash'
rm -f "$env_file"
touch "$env_file"

for arg
do
  case "$arg" in
    MIRROR=*)
      MIRROR="${arg#MIRROR=}"
      export MIRROR
      typeset -p MIRROR >> "$env_file"
      ;;
    PKG_EMAIL=*)
      PKG_EMAIL="${arg#PKG_EMAIL=}"
      export PKG_EMAIL
      typeset -p PKG_EMAIL >> "$env_file"
      ;;
    PKG_VERSIONEXT=*)
      PKG_VERSIONEXT="${arg#PKG_VERSIONEXT=}"
      export PKG_VERSIONEXT
      typeset -p PKG_VERSIONEXT >> "$env_file"
      ;;
    *)
      printf >&2 "%s: %s\n" "$0" "ignoring unhandled arg: $arg"
      ;;
  esac
done

env > "/out/debug.env.$(hostname).log"
/vagrant/vscripts/deps.py > "/out/debug.$(hostname).log"
