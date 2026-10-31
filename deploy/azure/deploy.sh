#!/bin/sh
# Redeploy FaceTrack to the Azure VM from a Mac with the repo, the private files and the SSH key.
# Ships exactly origin/main (never uncommitted local edits), keeps the server's private .env files
# and model files, rebuilds the containers and the two web apps. See docs/DEPLOY_AZURE.md.
#   deploy/azure/deploy.sh            # code + web apps + restart
#   deploy/azure/deploy.sh --web-only # only rebuild and upload the web apps
set -eu
HOST=${FACETRACK_HOST:-facetrack.centralindia.cloudapp.azure.com}
KEY=${FACETRACK_SSH_KEY:-$HOME/.ssh/facetrack_azure}
RG=${FACETRACK_RG:-facetrack-rg}
VM=${FACETRACK_VM:-facetrack-vm}
NSG=${FACETRACK_NSG:-facetrack-vmNSG}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CFG="$ROOT/.local/flutter/production.json"
REMOTE="azureuser@$HOST"
ssh_vm() { ssh -i "$KEY" -o ConnectTimeout=15 "$REMOTE" "$@"; }

[ -f "$CFG" ] || { echo "Missing $CFG (development.json with API_BASE_URL=https://$HOST)"; exit 1; }

# The VM may be deallocated to save credit, and SSH only allows the operator's last IP.
if command -v az >/dev/null 2>&1; then
  STATE=$(az vm get-instance-view -g "$RG" -n "$VM" \
    --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv 2>/dev/null || true)
  if [ "$STATE" != "VM running" ]; then
    echo "VM is '${STATE:-unknown}'; starting it..."
    az vm start -g "$RG" -n "$VM" -o none 2>/dev/null
  fi
  IP=$(curl -fsS https://api.ipify.org)
  az network nsg rule update -g "$RG" --nsg-name "$NSG" -n default-allow-ssh \
    --source-address-prefixes "$IP/32" -o none 2>/dev/null
  echo "SSH allowed from $IP"
else
  echo "Azure CLI not found: assuming the VM is running and SSH allows this IP."
fi
tries=0
until ssh_vm true 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 20 ] || { echo "Cannot reach $HOST over SSH."; exit 1; }
  sleep 6
done

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

# Unpack into a fresh folder so files deleted from main do not linger, carry the git-ignored
# private files (.env, .local/) across, then swap. The previous tree stays until the new one is up.
ssh_vm 'sudo rm -rf /opt/facetrack.new && sudo install -d -o azureuser -g azureuser /opt/facetrack.new'
git -C "$ROOT" archive --format=tar origin/main | ssh_vm 'tar -xf - -C /opt/facetrack.new'
ssh_vm 'set -e
cd /opt
cp -p facetrack/services/api/.env facetrack.new/services/api/.env
cp -p facetrack/services/worker/.env facetrack.new/services/worker/.env
# .local holds root-owned container temp files, and /opt itself is root-owned.
sudo cp -a facetrack/.local facetrack.new/.local
sudo rm -rf facetrack.old
sudo mv facetrack facetrack.old
sudo mv facetrack.new facetrack
cd facetrack
docker compose up -d --build
sudo rm -rf /opt/facetrack.old
sleep 5
docker compose ps --format "{{.Service}} {{.State}}"'
curl -fsS "https://$HOST/health/ready" && echo
