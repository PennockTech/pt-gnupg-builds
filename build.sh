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

deploy_one() {
  local -r machine="${1:-need a machine name}"
  if [[ -n "${PT_SKIP_DEPLOY:-}" ]]; then
    note "[$machine] skipping deploy-to-reposerver because PT_SKIP_DEPLOY set"
    return 0
  fi

  bs="$(jq -r --arg m "$machine" < confs/machines.json '.[]|select(.name==$m).base_script')"
  deploy="./os/deploy.${bs:-default}.sh"

  if [[ ! -f "$deploy" ]]; then
    note >&2 "[$machine] no deploy script (wanted: '${deploy}')"
    return
  fi

  set +e
  "$deploy" "$machine"
  ev=$?
  set -e

  case $ev in
    0) ;;
    3) note >&2 "[$machine] deploy failed but indicated non-fatal" ;;
    *) note >&2 "[$machine] deploy failed exiting $ev"; exit $ev ;;
  esac
}

if [[ -f site-local.env ]]; then
  # shellcheck disable=SC1091
  . ./site-local.env
else
  note "missing file site-local.env; see README, might be badly tuned"
fi

if [[ $# -eq 0 ]]; then
  printf "%s: %s" "${progname}" "available boxes: "
  jq -r < confs/machines.json '.[].name' | xargs
  exit
fi

for machine
do
  build_one "$machine" "out/$machine"
done

for machine
do
  deploy_one "$machine"
done

