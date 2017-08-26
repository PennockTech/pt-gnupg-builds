#!/bin/bash -eu
#
# This is run locally outside the VM.
# We're not pure-posix-sh, we use 'local' in functions.
# So we declare as bash.  So use [[..]]

build_one() {
  local -r machine="${1:-need a machine name}"
  local -r outputs="${2:-need an outputs dir}"
  local -r sshconf="./tmp.ssh-config.$machine"
  set -x
  if [[ -z "${PT_MACHINE_MUST_EXIST:-}" ]]; then
    vagrant up "$machine"
  fi
  mkdir -pv "$outputs"
  vagrant ssh-config "$machine" > "$sshconf"
  scp -F "$sshconf" -r "${machine}:/out/" "$outputs"
  if [[ -z "${PT_MACHINE_KEEP:-}" ]]; then
    vagrant destroy -f "$machine"
  fi
}

for machine
do
  build_one "$machine" "out/$machine"
done
