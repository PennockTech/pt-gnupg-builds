#!/bin/bash -eu
#
# This is run locally outside the VM.
# We're not pure-posix-sh, we use 'local' in functions.
# So we declare as bash.  So use [[..]]

progname="$(basename -s .sh "$0")"
note() { printf '%s: %s\n' "$progname" "$*"; }

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
    if [[ -n "${PT_RESUME_BUILD:-}" ]]; then
      vagrant provision "$machine"
    else
      vagrant up --provision "$machine"
    fi
  fi
  mkdir -pv "$outputs"
  vagrant ssh-config "$machine" > "$sshconf"
  rsync -e "ssh -F $sshconf" -cWrv "${machine}:/out/" "$outputs/./"
  rm -f "$sshconf"
  if [[ -z "${PT_MACHINE_KEEP:-}" ]]; then
    vagrant destroy -f "$machine"
  fi
  set +x
}

deploy_one() {
  # We are agnostic here as to things like "aptly for Debian-ish systems", but
  # that's all that was supported in-repo when this comment was last updated,
  # so for now we'll assume aptly for this description.
  #
  # We access AWS from two places: from the aptly box, which has *limited*
  # credentials available to it via classic AWS configuration, and locally on
  # the laptop, which uses 99designs/aws-vault to heavily restrict access to
  # credentials.
  #
  # The deploy script sets up the shell fragments to be run on the aptly box
  # and so references those credentials.  Separately, we have a
  # caching-invalidation tool, run locally on the laptop, and which can't just
  # set a profile name and call it done, because the script is Python using boto,
  # rather than dispatching through our aws shim.  But we can let the tool know
  # how to get credentials _from_ aws-vault.
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

  cmdline=("$deploy" "$machine")
  if [[ -n "${PT_INITIAL_DEPLOY:-}" ]]; then
    cmdline+=('-initial')
  fi

  set +e
  "${cmdline[@]}"
  ev=$?
  set -e

  case $ev in
    0) ;;
    3) note >&2 "[$machine] deploy failed but indicated non-fatal" ;;
    *) note >&2 "[$machine] deploy failed exiting $ev"; exit $ev ;;
  esac

  ./tools/caching_invalidate "$machine"
}

if [[ -f site-local.env ]]; then
  # shellcheck disable=SC1091
  . ./site-local.env
else
  note "missing file site-local.env; see README, might be badly tuned"
fi

if [[ $# -eq 0 ]]; then
  note "available boxes:" $(jq -r < confs/machines.json '.[].name')
  note "consider: vagrant box update"
  exit
fi

./tools/host.presetup.sh
PT_BUILD_CONFIGS_DIR=./confs PT_BUILD_TARBALLS_DIR="./in" \
  ./vscripts/deps.py --prepare-outside --base-dir . --gnupg-trust-model tofu

[[ "$1" == local ]] && exit 0
[[ "$1" == all ]] && set $(jq -r < confs/machines.json '.[].name')

for machine
do
  build_one "$machine" "out/$machine"
done

if [[ -z "${PT_SKIP_DEPLOY:-}" && -z "${PT_SKIP_GPGDELAY_PROMPT:-}" ]]; then
  echo ""
  echo "Done with any builds, going to copy/deploy packages into repos."
  echo "This will prompt for a PGP passphrase, if key is so protected."
  echo "That has a timeout.  So be ready."
  echo ""
  read -p 'Hit enter when ready ...' ok
fi

# Trust that we have aws-vault available?
#if [[ ! -r "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}" ]]; then
#  note >&2 "Missing aws credentials, is the volume mounted?"
#  exit 1
#fi

for machine
do
  deploy_one "$machine"
done

