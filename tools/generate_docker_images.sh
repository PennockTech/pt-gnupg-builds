#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."

progname="$(basename -s .sh "$0")"
note() { printf '%s: %s\n' "$progname" "$*"; }
die() { note >&2 "$@"; exit 1; }

readonly dockerfiles_dir=docker-cache

is_valid_machine() {
  local -r machine="${1:-need a machine name}"
  jq --arg want "$machine" -er < confs/machines.json 'isempty(.[] | select(has("docker")) | select(.name == $want)) | not' >/dev/null
}

generate() {
  local -r machine="${1:-need a machine name}"
  local base dockerfile tag_base tagd tagl
  base="$(jq --arg want "$machine" -er <confs/machines.json '.[]|select(.name == $want) | .docker[-1]')"
  dockerfile="${dockerfiles_dir}/Dockerfile-$machine"
  #tag_base="$(id -un)-${machine}-gnupg"
  tag_base="ptgnupg-${machine}"
  tagd="${tag_base}:$(date +%Y%m%d)"
  tagl="${tag_base}:latest"

  rm -fv "$dockerfile"
  cat > "$dockerfile" <<EODOCKER
FROM ${base}

WORKDIR /vagrant
ADD in/swdb* /in/
ADD os os/
ADD confs confs/

RUN os/ptlocal.debian-family.sh
RUN os/update.debian-family.sh

WORKDIR /
RUN rm -rf /in /vagrant /out
EODOCKER

  docker build --file "$dockerfile" --tag "$tagd" --tag "$tagl" .
}

: "${1:?need at least one machine name}"
mkdir -pv "$dockerfiles_dir"
for m
do
	generate "$m"
done
