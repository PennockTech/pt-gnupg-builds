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
  esac
done

env > "/out/debug.env.$(hostname).log"
/vagrant/vscripts/deps.py > "/out/debug.$(hostname).log"
