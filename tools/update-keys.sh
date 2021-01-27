#!/bin/bash -eu
#
# To source this, set UPDATE_KEYS_SKIP_MAIN non-empty first, else
# we will exit.  If the functions trigger an error, we will still
# exit when invoked.  We unilaterally "set -eu" before parsing,
# and on main entry point, but if you call the individual functions,
# we don't reset there.
# Beware that we're written to assume we can force shell exit on error.
#
# We rely upon unquoted variable expansions being split on $IFS

set -eu
# This is optimistic, but won't help us get bad commands out for sh∈{bash,zsh}
# And in fact zsh pipefail seems confused by our craziness; this is what
# I get for not writing in Python or go.  Or assuming bash to start with.
# Or rc.
# Actually I now use bash so I can have comments in arrays for the *_keys variables
[ -n "${BASH_VERSION:-}" ] && set -o pipefail
[ -n "${ZSH_VERSION:-}" ] && setopt pipefail shwordsplit

tags=""
swdb_keys=(
  '6DAA6E64A76D2840571B4902528897B826403ADA'  # Werner Koch 2020-2030
  'D8692123C4065DEA5E0F3AB5249B39D24F25E3B6'  # Werner Koch 2011-2021
  '5B80C5754298F0CB55D8ED6ABCEF7E294B092E28'  # Andre Heinecke
  '4FA2082362FE73AD03B88830A8DC7067E25FBABB'  # Damien Goutte-Gattat
  )
swdb_file='confs/pgp-swdb-signing-key.asc'
tags="${tags} swdb"

# Tarballs for other software
tarballs_keys=(
  '6DAA6E64A76D2840571B4902528897B826403ADA'  # Werner Koch 2020-2030
  'D8692123C4065DEA5E0F3AB5249B39D24F25E3B6'  # Werner Koch 2011-2021
  '031EC2536E580D8EA286A9F22071B08A33BD3F06'  # NIIBE Yutaka
  '1F42418905D8206AA754CCDC29EE58B996865171'  # Nikos Mavrogiannopoulos (GnuTLS)
  '462225C3B46F34879FC8496CD605848ED7E69871'  # Daiki Ueno (GnuTLS)
  '343C2FF0FBEE5EC2EDBEF399F3599FF828C67298'  # Niels Möller
  )
tarballs_file='confs/tarballs-keyring.asc'
tags="${tags} tarballs"

# Apt Repo, for software I package myself
apt_keys=(
  '5CAF09C9C79F88B5D526D4058AC8EE39F0C68907'  # PT Repository Mgmt
  )
apt_file='confs/apt-repo-keyring.asc'
tags="${tags} apt"

: "${GPG:=gpg}"

# -----------------------------8< cut here >8-----------------------------

progname="$(basename -s .sh "$0")"
note() { printf >&2 "%s: %s\n" "$progname" "$*"; }
warn() { printf >&2 "%s: %s\n" "$progname" "$*"; }
die() { warn "$@"; exit 1; }

# eval me with tag name, get $keys and $file out
#
# Memo: if we're assuming bash anyway, why not just use namerefs and arrays?
#       it's not worth fixing for idealism since it's working now.
set_for_tag() {
  local tag="${1:?need a tag}"
  local keysvar filevar
  printf "%s " "$tags" | fgrep -q " ${tag} " || die "unknown tag: '${tag}'"
  # at this point, known tag, presumed safe or we would not have included it;
  # the vars it references are ours and presumed safe, so eval is safe.
  keysvar="${tag}_keys"
  filevar="${tag}_file"
  eval "printf \"$(printf "tag='%s' keys='\${%s[*]}' file='\${%s}';" \
    "${tag}" "${keysvar}" "${filevar}")\n\""
}

inspect_current() {
  local t; t="$(set_for_tag "$1")"; eval "${t:-false}"; unset t
  # Yes, the only good way to list is to import in not-really and verbose mode;
  # if we use "--homedir /nonexistent" then we get an error for not being able
  # to create the pubring; we can disable any options which adjust behavior
  # though.  Just not sure if we _should_ use /dev/null.
  #
  # Goal: preserve stdout; on stderr, filter so that of lines starting gpg:, we
  # keep only "gpg: pub ".  We want error messages from finding the command, etc
  # kept (if $GPG points to a bad program), we don't want lots of expired
  # signature complaints.
  #
  # We assume /dev/fd/N available or emulated.
  # We assume tee(1) won't fail.
  exec 3>&1
  {
    {
      "${GPG}" </dev/null --batch --options /dev/null \
        -n -v --import "$file" \
        2>&1 >&3
    } | tee /dev/fd/4 | { grep '^gpg: pub ' >&2 || true; }
  } 4>&1 | { grep -v '^gpg: ' >&2 || true; }
  exec 3>&-
}

_update_userkeyring() {
  local t; t="$(set_for_tag "$1")"; eval "${t:-false}"; unset t
  note "Updating in your keyring: $keys"
  "${GPG}" </dev/null --batch \
    --keyserver-options honor-keyserver-url,honor-pka-record \
    --refresh-keys $keys || true

  local email
  "${GPG}" </dev/null --batch \
    --with-colons --list-keys $keys | \
    awk -F: '/^uid:/ {print $10}' | sed -nEe 's/^.*<([^>]+)>.*$/\1/p' | \
    while read -r email; do
      gpg --locate-external-keys "$email" || true
    done
}

_update_file_from_userkeyring() {
  local t; t="$(set_for_tag "$1")"; eval "${t:-false}"; unset t
  local onekey
  note "Exporting to ${file}: ${keys}"
  for onekey in $keys; do
    echo "# $onekey"
    "${GPG}" </dev/null --batch \
      --armor \
      --export-options "export-local-sigs export-clean" \
      --export "$onekey"
    echo
  done > "$file"
}

update_for_tag() {
  _update_userkeyring "$1"
  _update_file_from_userkeyring "$1"
  note updated "$1"
}

_list_for_one_tag() {
  local t; t="$(set_for_tag "$1")"; eval "${t:-false}"; unset t
  printf >&2 'Keys known for tag: %s\n' "$1"
  printf '%s\n' "${keys}" | xargs -n 1
}

list_for_args() {
  if [ "$#" -eq 0 ]; then
    printf "Known tags:\n"
    printf "  %s\n" $tags
    return 0
  fi
  local user_t t2
  for user_t; do
    case "$user_t" in
    (all) for t2 in $tags; do _list_for_one_tag "$t2"; done ;;
    (*) _list_for_one_tag "$user_t" ;;
    esac
  done
}

main() {
  set -eu
  cmd="${1:-help}"
  case "$cmd" in
    list) shift; list_for_args "$@" ;;
    inspect) inspect_current "${2:?need a tag, see 'list'}" ;;
    update) update_for_tag "${2:?need a tag, see 'list'}" ;;
    all) for t in $tags; do update_for_tag $t; done ;;
    help) printf "Usage: %s list|all\n       %s inspect|update <tag>\n" "${progname}" "${progname}" ;;
    *) die "unknown command '${cmd}'" ;;
  esac
  exit 0
}

skip="${UPDATE_KEYS_SKIP_MAIN+true}"
"${skip:-false}" || main "$@"
