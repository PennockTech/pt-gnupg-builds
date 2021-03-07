# variables for tuning the deploy

REPO_NAME="pt-$MACHINE"
REPO_DISTRIBUTION="$MACHINE"

SSH_USERHOST='pdp@morales'
REPO_INGEST_DIR="IN-packages/gnupg-$MACHINE"
REPO_SNAP_PREFIX="${REPO_NAME}-gnupg"
REPO_KEY='0x8AC8EE39F0C68907'
REPO_ARCHS='amd64,i386,armel,armhf,arm64'
REPO_NEED_GPG_AGENT='true'
#REPO_PATH_PREPEND='/opt/gnupg/bin'
