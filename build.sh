#!/bin/bash -eu
#
# This is run locally outside the VM.
# We're not pure-posix-sh, we use 'local' in functions.
# So we declare as bash.  So use [[..]]

progname="$(basename "$0")"
note() { printf "%s: %s\n" "$progname" "$*"; }

build_one() {
  local -r machine="${1:-need a machine name}"
  local -r outputs="${2:-need an outputs dir}"
  local -r sshconf="./tmp.ssh-config.$machine"
  if [[ -n "${PT_SKIP_BUILD:-}" ]]; then
    note "[$machine] skipping build because PT_SKIP_BUILD set"
    return 0
  fi
  set -x
  if [[ -z "${PT_MACHINE_MUST_EXIST:-}" ]]; then
    vagrant up "$machine"
  fi
  mkdir -pv "$outputs"
  vagrant ssh-config "$machine" > "$sshconf"
  scp -F "$sshconf" -r "${machine}:/out/*" "$outputs/./"
  rm -f "$sshconf"
  if [[ -z "${PT_MACHINE_KEEP:-}" ]]; then
    vagrant destroy -f "$machine"
  fi
  set +x
}

if [[ $# -eq 0 ]]; then
  printf "%s: %s" "${progname}" "available boxes: "
  jq -r < confs/machines.json '.[].name' | xargs
  exit
fi

for machine
do
  build_one "$machine" "out/$machine"

  bs="$(jq -r --arg m "$machine" < confs/machines.json '.[]|select(.name==$m).base_script')"
  deploy="./os/deploy.${bs:-default}.sh"
  if [[ -f "$deploy" ]]; then
    "$deploy" "$machine"
  else
    note >&2 "[$machine] no deploy script (wanted: '${deploy}')"
  fi
done
