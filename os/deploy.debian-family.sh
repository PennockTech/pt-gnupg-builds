#!/bin/bash -eu

readonly MACHINE="${1:?need a machine to sync content for}"

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
  # -e will exit 1 if no result (null, etc)
  jq < confs/machines.json -r -e \
    --arg m "$MACHINE" \
    --arg field "$field" \
    '.[]|select(.name==$m)[$field]'"${subselect}"
}

debs=("out/$MACHINE"/*.deb)  # nb: relies upon nullglob
[[ ${#debs} -eq 0 ]] && die "no debs found in out/$MACHINE/"

note "debs found: ${debs[*]}"
repo="$(machine_get repo)" || skipme_die "no repo defined"
repo_endpoints=( $(machine_get repo_endpoints '[]' || echo 'none') )

# None of the quoting here protects against single-quotes in the package names;
# we accept this threat, on basis that those _shouldn't_ have made it this far.
# In fact, the aptly invocation will not protect against whitespace either.

ssh -T "$SSH_USERHOST" <<EOSSH
mkdir -pv '${REPO_INGEST_DIR}'
EOSSH

rsync -cWv -- "${debs[@]}" "${SSH_USERHOST}:${REPO_INGEST_DIR}/./"

if $REPO_NEED_GPG_AGENT; then
  agent_start='eval "\$(gpg-agent --daemon)"'
  agent_end='gpgconf --kill gpg-agent'
else
  agent_start=':' agent_end=':'
fi
if [[ -n "${REPO_PATH_PREPEND:-}" ]]; then
  path_fixup="export PATH=\"${REPO_PATH_PREPEND}:\\\$PATH\""
else
  path_fixup=':'
fi

# packages are added to repos
# snapshots are created from repos
# publishing switches a distribution+endpoint between snapshots
# FIXME: multiple distributions in one repo??

ssh -T "$SSH_USERHOST" <<EOSSH
set -eux
cd '${REPO_INGEST_DIR}'
aptly repo add '${REPO_NAME}' ${debs[@]##*/}
snap='${REPO_SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)'
aptly snapshot create "\$snap" from repo '${REPO_NAME}'
rm -rf .publish
cat > .publish <<EOPUBLISH
#!/bin/sh -eu
$path_fixup
$agent_start
aptly_publish() { aptly publish -gpg-key '${REPO_KEY}' -architectures '${REPO_ARCHS}' "\\\$@" ; }
EOPUBLISH
for endpoint in ${repo_endpoints[@]} ; do
  [ \$endpoint = none ] && continue
  printf >> .publish "aptly_publish switch '%s' '%s' '%s'\n" '${REPO_DISTRIBUTION}' "\$endpoint" "\$snap"
done
printf >> .publish '%s\n' '${agent_end}'
chmod 755 .publish
EOSSH

ssh -t "$SSH_USERHOST" "${REPO_INGEST_DIR}/.publish"

