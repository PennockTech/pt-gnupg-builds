#!/bin/bash -eu

readonly MACHINE="${1:?need a machine to sync content for}"
if [[ "${2:-.}" == "-initial" ]]; then
  readonly InitialPublish=true
else
  readonly InitialPublish=false
fi

# shellcheck source=../confs/deploy.sh
. ./confs/deploy.sh
# is allowed to rely upon $MACHINE

readonly NON_FATAL_EXIT=3
readonly progname="$(basename -s .sh "$0")"
note() { printf "%s: [%s] %s\n" "$progname" "$MACHINE" "$*" ; }
warn() { note "$@" >&2 ; }
die() { warn "$@"; exit 1 ; }
skipme_die() { warn "$@"; exit $NON_FATAL_EXIT ; }

shopt -s nullglob

machine_get() {
  local field="${1:?need a field to get from machines.json}"
  local subselect="${2:-}"
  shift 2
  # -e will exit 1 if no result (null, etc)
  jq < confs/machines.json -r -e \
    --arg m "$MACHINE" \
    --arg field "$field" \
    "$@" \
    '.[]|select(.name==$m)[$field]'"${subselect}"
}

debs=("out/$MACHINE"/*.deb)  # nb: relies upon nullglob
[[ ${#debs} -eq 0 ]] && die "no debs found in out/$MACHINE/"

note "debs found: ${debs[*]}"

repo_endpoints=( $(machine_get repo_endpoints '[].spec' || echo 'none') )
[[ "${repo_endpoints[1]:-}" == "none" ]] && skipme_die "no repo defined"

aws_profiles=()
for (( i=0 ; i < ${#repo_endpoints[@]}; i++)); do
  ep="${repo_endpoints[$i]}"
  profile="$(machine_get repo_endpoints '[]|select(.spec==$spec)["aws_profile"]' --arg spec "$ep" || true)"
  [[ "${profile:-null}" == "null" ]] && profile=''
  aws_profiles[$i]="$profile"
done

# None of the quoting here protects against single-quotes in the package names;
# we accept this threat, on basis that those _shouldn't_ have made it this far.
# In fact, the aptly invocation will not protect against whitespace either.

ssh -T "$SSH_USERHOST" <<EOSSH
mkdir -pv '${REPO_INGEST_DIR}/old'
EOSSH

rsync -cWv -- "${debs[@]}" "${SSH_USERHOST}:${REPO_INGEST_DIR}/./"

if $REPO_NEED_GPG_AGENT; then
  agent_start='eval "$(gpg-agent --daemon)"'
  agent_end='gpgconf --kill gpg-agent'
else
  agent_start=':' agent_end=':'
fi
if [[ -n "${REPO_PATH_PREPEND:-}" ]]; then
  path_fixup="export PATH=\"${REPO_PATH_PREPEND}:\$PATH\""
else
  path_fixup=':'
fi

# packages are added to repos
# snapshots are created from repos
# publishing switches a distribution+endpoint between snapshots
# FIXME: multiple distributions in one repo??

case "$OSTYPE" in
linux-gnu)
  publish_fn="$(mktemp -t publish.XXXXXXXXXX)"
  ;;
darwin*)
  publish_fn="$(mktemp -t publish)"
  ;;
*)
  die "need to know how to invoke mktemp(1) on $OSTYPE";;
esac
cat >> "$publish_fn" <<EOPUBLISH
#!/bin/sh -eu
$path_fixup
$agent_start
aptly_publish() { aptly publish -gpg-key '${REPO_KEY}' -architectures '${REPO_ARCHS}' "\$@" ; }

cd '${REPO_INGEST_DIR}'
aptly repo add '${REPO_NAME}' ${debs[@]##*/}
snap='${REPO_SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)'
aptly snapshot create "\$snap" from repo '${REPO_NAME}'
mv *.deb old/./
EOPUBLISH

for (( i=0 ; i < ${#repo_endpoints[@]}; i++)); do
  endpoint="${repo_endpoints[$i]}"
  aws_profile="${aws_profiles[$i]}"
  [[ $endpoint == none ]] && continue
  echo
  if [[ "${aws_profile:-}" == "" ]]; then
    printf "%s\n" "unset AWS_PROFILE || true"
  else
    printf "%s\n" "export AWS_PROFILE='${aws_profile}'"
  fi
  if $InitialPublish; then
    printf 'aptly_publish snapshot -distribution="%s" "%s" "%s"\n' "${REPO_DISTRIBUTION}" '$snap' "${endpoint}"
  else
    printf 'aptly_publish switch "%s" "%s" "%s"\n' "${REPO_DISTRIBUTION}" "${endpoint}" '$snap'
  fi
done >> "$publish_fn"

printf >> "$publish_fn" '\n%s\n' "${agent_end}"

chmod 0755 "$publish_fn"
scp "$publish_fn" "${SSH_USERHOST}:${REPO_INGEST_DIR}/./.publish"
rm "$publish_fn"

ssh -t "$SSH_USERHOST" "${REPO_INGEST_DIR}/.publish"
