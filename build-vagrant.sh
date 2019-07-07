#!/usr/bin/env bash
set -eu
#
# This is run locally outside the VM.
# We're not pure-posix-sh, we use 'local' in functions.
# So we declare as bash.  So use [[..]]
readonly ControlHelp='Env vars:
  PT_SKIP_BUILD=t to skip builds
  PT_MACHINE_MUST_EXIST=t to avoid machine provisioning
  PT_RESUME_BUILD=t to just provision, instead of build
  PT_MACHINE_KEEP=t to not destroy the VM afterwards

  PT_SKIP_DEPLOY=t to skip deploys
  PT_SKIP_GPGDELAY_PROMPT=t to continue on immediately without prompt
    -- the prompt helps avoids timeouts by making sure you are present
  PT_INITIAL_DEPLOY=t for initial setup of apt repo for this system
'

progname="$(basename -s .sh "$0")"
note() { printf '%s: %s\n' "$progname" "$*"; }
die() { note >&2 "$@"; exit 1; }

if [[ ${BASH_VERSINFO[0]} -ge 5 ]] || [[ ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 2 ]]; then
  : # we have associative arrays, hurrah!
else
  if [[ "$BASH" == "/bin/bash" ]] && [[ -x /usr/local/bin/bash ]]; then
    note "trying to get a newer bash"
    exec /usr/local/bin/bash "$0" "$@" || die "failed to re-exec with newer bash"
  else
    die "this bash is too old (need 4.2+, have $BASH_VERSION)"
  fi
fi

declare -A deferred_deploy_commands
declare -A deferred_deploy_targets

# Bash bug IMO: ${#assoc_array[@]} triggers -u unbound if no elements
deferred_deploy_commands[dummy]='will_be_unset'

is_valid_machine() {
  local -r machine="${1:-need a machine name}"
  jq --arg want "$machine" -er < confs/machines.json 'isempty(.[] | select(has("box")) | select(.name == $want)) | not' >/dev/null
}

build_one() {
  local -r machine="${1:-need a machine name}"
  local -r outputs="${2:-need an outputs dir}"
  local -r sshconf="./tmp.ssh-config.$machine"
  if ! is_valid_machine "$machine"; then
    die "invalid machine name: $machine"
  fi
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
  if ! is_valid_machine "$machine"; then
    die "invalid machine name: $machine"
  fi
  if [[ -n "${PT_SKIP_DEPLOY:-}" ]]; then
    note "[$machine] skipping deploy-to-reposerver because PT_SKIP_DEPLOY set"
    return 0
  fi

  local bs deploy can_batch cmdline ev previous
  bs="$(jq -r --arg m "$machine" < confs/machines.json '.[]|select(has("box"))|select(.name==$m).base_script')"
  deploy="./os/deploy.${bs:-default}.sh"
  can_batch="./os/deploy.${bs:-default}.can-batch"

  if [[ ! -f "$deploy" ]]; then
    note >&2 "[$machine] no deploy script (wanted: '${deploy}')"
    return
  fi

  cmdline=("$deploy" "$machine")
  if [[ -n "${PT_INITIAL_DEPLOY:-}" ]]; then
    cmdline+=('-initial')
  fi
  if [[ -f "$can_batch" ]]; then
    # This is why we have the version re-exec song-and-dance.
    previous="${deferred_deploy_commands[${bs:-default}]:-}"
    if [[ -n "$previous" && "$previous" != "$deploy" ]]; then
      die "mismatch in base command for '${bs:-default}': '$previous' vs '$deploy'"
    fi
    deferred_deploy_commands[${bs:-default}]="$deploy"
    deferred_deploy_targets[${bs:-default}]+=" ${machine}"
    cmdline+=('-copy-only')
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

  if [[ ! -f "$can_batch" ]]; then
    ./tools/caching_invalidate "$machine"
  fi
}

deploy_deferred() {
  if [[ -n "${PT_SKIP_DEPLOY:-}" ]]; then
    return
  fi
  # the targets contain whitespace which we should split on
  # shellcheck disable=SC2068
  if [[ "${#deferred_deploy_targets[@]}" -le 1 ]]; then
    note "no deferred deploys"
    return
  fi
  unset deferred_deploy_targets[dummy]
  local group
  for group in "${!deferred_deploy_commands[@]}"; do
    "${deferred_deploy_commands[$group]}" -deferred ${deferred_deploy_targets[$group]}
  done
  ./tools/caching_invalidate ${deferred_deploy_targets[@]}
}

if [[ -f site-local.env ]]; then
  # shellcheck disable=SC1091
  . ./site-local.env
else
  note "missing file site-local.env; see README, might be badly tuned"
fi

if [[ "${1:-}" == "--help" || "${1:-help}" == "help" ]]; then
  note "invoke with 'local' to just fetch/verify sources"
  note "invoke with 'all' or a list of machine-names to build"
  note "environment variables control more"
  note ''
  # we want to not preserve newlines, so not "$(...)" for this jq
  # shellcheck disable=SC2046
  note "available boxes ['all']:" $(jq -r < confs/machines.json '.[]|select(has("box"))|.name')
  note "consider: vagrant box update"
  note "$ControlHelp"
  [[ -f "$HOME/.aws/config" ]] || die "missing ~/.aws/config"
  exit
fi

if [[ "$OSTYPE" != darwin* ]]; then
  note "Not macOS, skipping sleep prevention"
else
  if [[ -z "${PT_CAFFEINATE_UNNEEDED:-}" ]]; then
    note "about to re-exec self under caffeinate"
    note " (builds can take a long time, avoid system sleep)"
    export PT_CAFFEINATE_UNNEEDED=true
    exec caffeinate "$0" "$@" || \
      die "exec failed: $?"
  else
    note "now running with caffeinate (or inhibited)"
  fi
fi

if [[ -n "${PT_SKIP_BUILD:-}" ]]; then
  note "local: skipping pre-build setup because PT_SKIP_BUILD set"
else
  ./tools/host.presetup.sh
  PT_BUILD_CONFIGS_DIR=./confs PT_BUILD_TARBALLS_DIR="./in" \
    ./vscripts/deps.py --prepare-outside --base-dir . --gnupg-trust-model tofu
fi

[[ "$1" == local ]] && exit 0
# We want to split on whitespace
# shellcheck disable=SC2046
[[ "$1" == all ]] && set $(jq -r < confs/machines.json '.[]|select(has("box"))|.name')

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
  read -r -p 'Hit enter when ready ...'
fi
[[ -f "$HOME/.aws/config" ]] || die "missing ~/.aws/config"

# Trust that we have aws-vault available?
#if [[ ! -r "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}" ]]; then
#  note >&2 "Missing aws credentials, is the volume mounted?"
#  exit 1
#fi

for machine
do
  deploy_one "$machine"
done
deploy_deferred

# vim: set sw=2 et :
