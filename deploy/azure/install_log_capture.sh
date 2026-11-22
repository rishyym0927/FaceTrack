#!/bin/sh
# Install persistent log capture on the Azure VM (run ON the VM, or via ssh, as a sudoer).
#
#   sudo deploy/azure/install_log_capture.sh            # install or update (idempotent)
#   sudo deploy/azure/install_log_capture.sh --status   # show what is installed and captured
#   sudo deploy/azure/install_log_capture.sh --uninstall   # remove the service; keeps the logs
#
# From a Mac (the repo copy of this folder is what gets installed):
#   scp -i ~/.ssh/facetrack_azure -r deploy/azure/log_capture.py deploy/azure/install_log_capture.sh \
#       azureuser@facetrack.centralindia.cloudapp.azure.com:/tmp/ft-logcapture/
#   ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com \
#       'sudo sh /tmp/ft-logcapture/install_log_capture.sh'
#
# What it does:
#   - copies log_capture.py to /usr/local/lib/facetrack/ (outside /opt/facetrack, which every
#     deploy replaces)
#   - systemd service facetrack-log-capture: follows every container of the compose project
#     "facetrack" read-only with `docker logs -f` and appends to /var/log/facetrack/<service>.log
#   - logrotate (hourly timer): rotates a file at 200 MB or daily, keeps 14 days, compressed.
#     Worst case on disk is a few hundred MB.
#
# What it never does: restart or reconfigure a container, edit /opt/facetrack, or change
# compose.yaml. Containers keep their own json-file logs exactly as before.
set -eu

LIB=/usr/local/lib/facetrack
OUT=/var/log/facetrack
STATE_DIR=/var/lib/facetrack-log-capture
UNIT=/etc/systemd/system/facetrack-log-capture.service
ROTATE_CONF=/etc/logrotate.d/facetrack
ROTATE_UNIT=/etc/systemd/system/facetrack-logrotate.service
ROTATE_TIMER=/etc/systemd/system/facetrack-logrotate.timer
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

case "${1:-}" in
  --status)
    systemctl is-active facetrack-log-capture 2>&1 || true
    systemctl list-timers facetrack-logrotate.timer --no-pager 2>&1 | head -3 || true
    ls -la "$OUT" 2>&1 | head -20
    du -sh "$OUT" 2>&1 || true
    df -h /var | tail -1
    exit 0 ;;
  --uninstall)
    systemctl disable --now facetrack-log-capture facetrack-logrotate.timer 2>/dev/null || true
    rm -f "$UNIT" "$ROTATE_UNIT" "$ROTATE_TIMER" "$ROTATE_CONF"
    systemctl daemon-reload
    echo "Removed the service. Captured logs are still in $OUT and $STATE_DIR."
    exit 0 ;;
  '') ;;
  *) echo "Unknown option $1" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }
command -v logrotate >/dev/null 2>&1 || { echo "logrotate is required (apt install logrotate)." >&2; exit 1; }
[ -f "$HERE/log_capture.py" ] || { echo "log_capture.py must sit next to this script." >&2; exit 1; }
python3 -m py_compile "$HERE/log_capture.py"

install -d -m 0755 "$LIB"
install -d -m 0750 -o root -g adm "$OUT"
install -d -m 0750 "$STATE_DIR"
install -m 0755 "$HERE/log_capture.py" "$LIB/log_capture.py"

cat > "$UNIT" <<'EOF'
[Unit]
Description=FaceTrack persistent container log capture (read-only)
After=docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/facetrack/log_capture.py --out /var/log/facetrack --state /var/lib/facetrack-log-capture/state.json
Restart=always
RestartSec=5
# It only reads container logs (through the docker CLI) and writes its own two folders.
NoNewPrivileges=true
Nice=10

[Install]
WantedBy=multi-user.target
EOF

# copytruncate: the capture keeps appending to the same path while logrotate rotates it.
# Size and age are both bounded: a file rotates at 200 MB or daily, rotated files are
# compressed and removed after 14 days or 14 rotations.
cat > "$ROTATE_CONF" <<'EOF'
/var/log/facetrack/*.log {
    daily
    maxsize 200M
    rotate 14
    maxage 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root adm
}
EOF

# logrotate normally runs once a day; hourly keeps maxsize meaningful during a busy week.
cat > "$ROTATE_UNIT" <<'EOF'
[Unit]
Description=Rotate FaceTrack captured logs

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/facetrack
EOF
cat > "$ROTATE_TIMER" <<'EOF'
[Unit]
Description=Hourly FaceTrack log rotation

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

logrotate --debug "$ROTATE_CONF" >/dev/null 2>&1 || { echo "logrotate rejected its configuration." >&2; exit 1; }
systemctl daemon-reload
systemctl enable facetrack-log-capture.service
systemctl restart facetrack-log-capture.service  # picks up an updated script; resumes from its state
systemctl enable --now facetrack-logrotate.timer
sleep 4
systemctl is-active facetrack-log-capture
ls -la "$OUT"
echo
echo "Installed. Logs of every container, from now on and from what Docker still holds, are in"
echo "$OUT. Check later with: sudo sh $0 --status"
