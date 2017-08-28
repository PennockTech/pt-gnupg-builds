# variables for tuning the deploy

case "$MACHINE" in
  trusty)
    REPO_NAME='spodhuis' # historical reasons
    ;;
  *)
    REPO_NAME="pt-$MACHINE"
    ;;
esac
REPO_DISTRIBUTION="$MACHINE"

SSH_USERHOST='fuji@orchard'
REPO_INGEST_DIR="IN-packages/gnupg-$MACHINE"
REPO_SNAP_PREFIX='spodhuis-gnupg'
REPO_KEY='0x8AC8EE39F0C68907'
REPO_ARCHS='amd64,i386,armel,armhf,arm64'
REPO_NEED_GPG_AGENT='true'
REPO_PATH_PREPEND='/opt/gnupg/bin'
