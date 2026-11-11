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
case "$HOST" in
  ''|*[!a-zA-Z0-9.-]*) echo "Invalid deployment hostname." >&2; exit 1 ;;
esac
ssh_vm() { ssh -i "$KEY" -o ConnectTimeout=15 "$REMOTE" "$@"; }

[ -f "$CFG" ] || { echo "Missing $CFG (development.json with API_BASE_URL=https://$HOST)"; exit 1; }

# The VM may be deallocated to save credit, and SSH only allows the operator's last IP.
if command -v az >/dev/null 2>&1; then
  STATE=$(az vm get-instance-view -g "$RG" -n "$VM" \
    --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv 2>/dev/null || true)
  if [ "$STATE" != "VM running" ]; then
    echo "VM is '${STATE:-unknown}'; starting it..."
    az vm start -g "$RG" -n "$VM" -o none ||
      { echo "Could not start $VM in $RG (run 'az login'?)."; exit 1; }
  fi
  IP=$(curl -fsS https://api.ipify.org) || { echo "Could not look up this machine's public IP."; exit 1; }
  az network nsg rule update -g "$RG" --nsg-name "$NSG" -n default-allow-ssh \
    --source-address-prefixes "$IP/32" -o none ||
    { echo "Could not allow SSH from $IP on $NSG (run 'az login'?)."; exit 1; }
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

TMP=$(mktemp -d)
WT="$TMP/facetrack-main"
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
git -C "$ROOT" worktree add --detach -q "$WT" origin/main

for app in teacher student; do
  (cd "$WT/apps/$app" && "$ROOT/scripts/flutter" pub get --enforce-lockfile >/dev/null &&
    "$ROOT/scripts/flutter" build web --release --base-href "/$app/" --dart-define-from-file="$CFG")
done
WEB_ROOT=/srv/facetrack
WEB_STAGE=$(ssh_vm 'set -e
stage=$(mktemp -d /srv/facetrack/release-XXXXXXXX)
chmod 755 "$stage"
mkdir "$stage/teacher" "$stage/student"
printf "%s\n" "$stage"')
case "$WEB_STAGE" in
  "$WEB_ROOT"/release-[a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9]) ;;
  *) echo "Invalid remote staging directory." >&2; exit 1 ;;
esac
for app in teacher student; do
  if ! rsync -az -e "ssh -i '$KEY'" "$WT/apps/$app/build/web/" "$REMOTE:$WEB_STAGE/$app/"; then
    ssh_vm "rm -rf '$WEB_STAGE'" || true
    exit 1
  fi
done
activate_web() {
  ssh_vm "python3 - '$WEB_ROOT' '$WEB_STAGE' 'https://$HOST'" < "$ROOT/deploy/azure/activate_web.py"
}
if [ "${1:-}" = "--web-only" ]; then
  activate_web
  echo "Both web apps updated and verified."
  exit 0
fi

# Unpack into a fresh folder so files deleted from main do not linger, carry the git-ignored
# private files (.env, .local/) across, then swap. The containers bind-mount /opt/facetrack, so
# every service is recreated on the new tree; the previous tree is restored if that fails and is
# removed only once worker and agent run from the new one.
ssh_vm 'sudo rm -rf /opt/facetrack.new && sudo install -d -o azureuser -g azureuser /opt/facetrack.new'
git -C "$ROOT" archive --format=tar origin/main | ssh_vm 'tar -xf - -C /opt/facetrack.new'
rsync -az -e "ssh -i '$KEY'" "$ROOT/deploy/azure/activate_web.py" "$REMOTE:$WEB_STAGE/"
ssh_vm "WEB_STAGE='$WEB_STAGE' WEB_BASE='https://$HOST' sh -s" <<'REMOTE_DEPLOY'
set -e
cd /opt
cp -p facetrack/services/api/.env facetrack.new/services/api/.env
cp -p facetrack/services/worker/.env facetrack.new/services/worker/.env
# .local holds root-owned container temp files, and /opt itself is root-owned.
sudo cp -a facetrack/.local facetrack.new/.local
sudo rm -rf facetrack.old
sudo mv facetrack facetrack.old
sudo mv facetrack.new facetrack
running() {
  for service in worker agent; do
    [ "$(docker compose ps --status running -q "$service")" ] || return 1
  done
}
rollback() {
  echo "Deploy failed: restoring the previous tree." >&2
  cd /opt
  sudo rm -rf facetrack.failed
  sudo mv facetrack facetrack.failed || exit 1
  sudo mv facetrack.old facetrack || exit 1
  cd facetrack
  timeout 600 docker compose up -d --build --force-recreate --wait || true
  exit 1
}
cd /opt/facetrack
# timeout: --wait alone can block forever on a service that never settles.
timeout 600 docker compose up -d --build --force-recreate --wait || rollback
running || rollback
curl -fsS --max-time 10 http://127.0.0.1:8000/health/ready >/dev/null || rollback
curl -fsS --max-time 10 "$WEB_BASE/health/ready" >/dev/null || rollback
python3 "$WEB_STAGE/activate_web.py" /srv/facetrack "$WEB_STAGE" "$WEB_BASE" || rollback
sudo rm -rf /opt/facetrack.old /opt/facetrack.failed
docker compose ps --format "{{.Service}} {{.State}}"
REMOTE_DEPLOY
echo "Services and both web apps updated and verified."
