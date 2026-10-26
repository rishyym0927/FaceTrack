#!/bin/sh
# One-time setup for macOS / Linux (mirror of scripts/windows/setup.ps1).
# Creates ignored config from the checked-in examples, fetches Flutter
# dependencies, and optionally builds the Docker images.
#   scripts/setup.sh                 # config + flutter deps + docker build
#   scripts/setup.sh --skip-build    # skip the docker image build
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SKIP_BUILD=0
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=1

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. $2" >&2; exit 1; }
}
need git "Install git, then re-run."

# Flutter: the bundled toolchain (scripts/flutter) or a system install on PATH.
if [ ! -x "$ROOT/.tools/flutter/bin/flutter" ]; then
  need flutter "Install Flutter stable and add its bin folder to PATH."
fi

# --- ignored config from examples ---------------------------------------------
FLUTTER_CFG="$ROOT/.local/flutter/development.json"
if [ ! -f "$FLUTTER_CFG" ]; then
  mkdir -p "$(dirname "$FLUTTER_CFG")"
  cp "$ROOT/config/flutter.development.example.json" "$FLUTTER_CFG"
  echo "Created .local/flutter/development.json — fill its public Supabase values."
fi

API_ENV="$ROOT/services/api/.env"
if [ ! -f "$API_ENV" ]; then
  JOIN_KEY=$(
    (openssl rand -hex 32 2>/dev/null) ||
    (head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  )
  sed "s/REPLACE_WITH_64_HEX_DIGITS/$JOIN_KEY/" "$ROOT/services/api/.env.example" > "$API_ENV"
  echo "Created services/api/.env — fill its private database and Supabase values."
fi

# --- flutter deps -------------------------------------------------------------
for app in student teacher; do
  ( cd "$ROOT/apps/$app" && "$ROOT/scripts/flutter" pub get --enforce-lockfile )
done

# --- docker images (optional) -------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker compose -f "$ROOT/compose.yaml" build
  else
    echo "Docker not running — skipping image build. Start Docker and run 'make build' later."
  fi
fi

echo "Setup complete."
echo "Next: complete the ignored private configuration (see docs/LINUX_SETUP.md),"
echo "then run 'make up' (backend) or 'make console' (client model-test page)."
