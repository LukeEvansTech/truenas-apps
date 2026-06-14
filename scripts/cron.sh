#!/usr/bin/env bash
# Keep the doco-cd *bootstrap* current. App stacks update via doco-cd's own polling;
# this only re-runs the bootstrap compose when bootstrap/ changes. Wire as a TrueNAS
# cron job: /root/truenas-apps/scripts/cron.sh /root/truenas-apps
set -euo pipefail

REPO_DIR="${1:?Usage: $0 <repo-dir>}"
LOG_TAG="doco-cd-update"
log() { echo "[${LOG_TAG}] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }

cd "$REPO_DIR"
git fetch origin 2>/dev/null
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse '@{u}')
log "local=${LOCAL} remote=${REMOTE}"

if [ "$LOCAL" = "$REMOTE" ]; then
  log "No changes."
  exit 0
fi

git reset --hard "$REMOTE"

if git diff --quiet "${LOCAL}" HEAD -- bootstrap/; then
  log "Changes pulled but none in bootstrap/, doco-cd handles apps/."
  exit 0
fi

log "bootstrap/ changed — applying."
cd "${REPO_DIR}/bootstrap"
docker compose up -d
log "Done."
