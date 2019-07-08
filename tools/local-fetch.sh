#!/bin/sh -eu
set -eu

# This is for use outside the VMs/Containers/whatever, to fetch the manifests
# and check signatures once, before build work begins.

./tools/host.presetup.sh
PT_BUILD_CONFIGS_DIR=./confs PT_BUILD_TARBALLS_DIR="./in" \
  ./vscripts/deps.py --prepare-outside --base-dir . --gnupg-trust-model tofu

printf 'Vagrant targets: '
jq -r < confs/machines.json '.[]|select(has("box"))|.name' | sort | xargs

printf 'Docker targets: '
jq -r < confs/machines.json '.[]|select(has("docker"))|.name' | sort | xargs

# vim: set sw=2 et :
