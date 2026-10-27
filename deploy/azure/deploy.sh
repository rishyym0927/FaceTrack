#!/bin/sh
# Redeploy FaceTrack to the Azure VM from a Mac with the repo, the private files and the SSH key.
# Ships exactly origin/main (never uncommitted local edits), keeps the server's private .env files
# and model files, rebuilds the containers and the two web apps. See docs/DEPLOY_AZURE.md.
#   deploy/azure/deploy.sh            # code + web apps + restart
#   deploy/azure/deploy.sh --web-only # only rebuild and upload the web apps
set -eu
HOST=${FACETRACK_HOST:-facetrack.centralindia.cloudapp.azure.com}
KEY=${FACETRACK_SSH_KEY:-$HOME/.ssh/facetrack_azure}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CFG="$ROOT/.local/flutter/production.json"
REMOTE="azureuser@$HOST"
ssh_vm() { ssh -i "$KEY" "$REMOTE" "$@"; }

[ -f "$CFG" ] || { echo "Missing $CFG (development.json with API_BASE_URL=https://$HOST)"; exit 1; }
git -C "$ROOT" fetch -q origin
REV=$(git -C "$ROOT" rev-parse --short origin/main)
echo "Deploying origin/main $REV to $HOST"

WT=$(mktemp -d)/facetrack-main
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
git -C "$ROOT" worktree add --detach -q "$WT" origin/main

for app in teacher student; do
  (cd "$WT/apps/$app" && "$ROOT/scripts/flutter" pub get --enforce-lockfile >/dev/null &&
    "$ROOT/scripts/flutter" build web --release --base-href "/$app/" --dart-define-from-file="$CFG")
  rsync -az --delete -e "ssh -i $KEY" "$WT/apps/$app/build/web/" "$REMOTE:/srv/facetrack/$app/"
done
[ "${1:-}" = "--web-only" ] && { echo "Web apps updated."; exit 0; }

# Code only: tar does not delete files, and the git-ignored .env files and .local/ are never in the archive.
git -C "$ROOT" archive --format=tar origin/main | ssh_vm 'cd /opt/facetrack && tar -xf -'
ssh_vm 'cd /opt/facetrack && docker compose up -d --build && sleep 5 && docker compose ps --format "{{.Service}} {{.State}}"'
curl -fsS "https://$HOST/health/ready" && echo
