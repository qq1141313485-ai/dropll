#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST=""
REMOTE_DIR="/tmp/caimaster-plan-content-upload"
TARGET_DIR="/opt/caimaster-api"
PYTHON_BIN="/opt/caimaster-api/.venv/bin/python3.11"
BASE_URL="${CAIMASTER_API_BASE_URL:-https://api.cclloo.com}"
SERVICE_NAME="caimaster-api.service"
PATCH_API_APP=0
INSTALL_DEPS=0
ENABLE_TIMER=0
REQUIRE_DATA=0
RESTART_API=1
USE_SUDO=0
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage: deploy_plan_content_remote.sh --host user@server [options]

Builds the plan-content package locally, uploads it with scp, verifies checksum
on the server, installs files, optionally patches app.py, restarts the API, and
runs verify_plan_release.py.

Options:
  --host user@server         SSH target. Required.
  --remote-dir PATH          Upload directory on server. Default: /tmp/caimaster-plan-content-upload
  --target PATH              API target directory. Default: /opt/caimaster-api
  --python PATH              Server Python. Default: /opt/caimaster-api/.venv/bin/python3.11
  --base-url URL             Public API base URL. Default: https://api.cclloo.com
  --service NAME             API systemd service. Default: caimaster-api.service
  --patch-api-app            Let install_plan_content.sh patch /opt/caimaster-api/app.py
  --install-deps             Run pip install -r requirements.txt on server
  --enable-timer             Enable and start the sync timer
  --require-data             Require public plan data during final verification
  --skip-restart             Do not restart the API service
  --sudo                     Run install/restart/timer commands through sudo
  --dry-run                  Build and print planned SSH/SCP actions, but do not connect
  --yes                      Required for real deployment; confirms upload/restart/verify
USAGE
}

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="$2"
      shift 2
      ;;
    --target)
      TARGET_DIR="$2"
      shift 2
      ;;
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --service)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --patch-api-app)
      PATCH_API_APP=1
      shift
      ;;
    --install-deps)
      INSTALL_DEPS=1
      shift
      ;;
    --enable-timer)
      ENABLE_TIMER=1
      shift
      ;;
    --require-data)
      REQUIRE_DATA=1
      shift
      ;;
    --skip-restart)
      RESTART_API=0
      shift
      ;;
    --sudo)
      USE_SUDO=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "--host is required" >&2
  usage >&2
  exit 2
fi

require_command find
require_command scp
require_command sed
require_command ssh
require_command tar
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "Missing required command: shasum or sha256sum" >&2
  exit 1
fi

if [[ "$DRY_RUN" != "1" && "$ASSUME_YES" != "1" ]]; then
  echo "Refusing real deployment without --yes." >&2
  echo "Run with --dry-run first, then add --yes when the printed actions look correct." >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Building upload package"
"${SOURCE_DIR}/package_plan_content.sh" "$WORK_DIR"
ARCHIVE="$(find "$WORK_DIR" -maxdepth 1 -name 'caimaster-plan-content-*.tar.gz' -print | sort | tail -n 1)"
CHECKSUM="${ARCHIVE}.sha256"
PACKAGE_FILE="$(basename "$ARCHIVE")"
CHECKSUM_FILE="$(basename "$CHECKSUM")"
PACKAGE_DIR="${PACKAGE_FILE%.tar.gz}"

if [[ ! -f "$ARCHIVE" || ! -f "$CHECKSUM" ]]; then
  echo "Package creation failed" >&2
  exit 1
fi

echo "Verifying local checksum"
(
  cd "$WORK_DIR"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "$CHECKSUM_FILE"
  else
    sha256sum -c "$CHECKSUM_FILE"
  fi
)

INSTALL_ARGS=("--target" "$TARGET_DIR" "--python" "$PYTHON_BIN" "--skip-dry-run")
if [[ "$PATCH_API_APP" == "1" ]]; then
  INSTALL_ARGS+=("--patch-api-app")
fi
if [[ "$INSTALL_DEPS" == "1" ]]; then
  INSTALL_ARGS+=("--install-deps")
fi
if [[ "$ENABLE_TIMER" == "1" ]]; then
  INSTALL_ARGS+=("--enable-timer")
fi

VERIFY_ARGS=("--base-url" "$BASE_URL")
if [[ "$REQUIRE_DATA" == "1" ]]; then
  VERIFY_ARGS+=("--require-data")
fi

REMOTE_SCRIPT="$(
  cat <<REMOTE
set -euo pipefail
cd $(shell_quote "$REMOTE_DIR")
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 -c $(shell_quote "$CHECKSUM_FILE")
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c $(shell_quote "$CHECKSUM_FILE")
else
  echo "Missing shasum or sha256sum on server" >&2
  exit 1
fi
rm -rf $(shell_quote "$PACKAGE_DIR")
tar -xzf $(shell_quote "$PACKAGE_FILE")
cd $(shell_quote "$PACKAGE_DIR")
$(shell_quote "$PYTHON_BIN") -m unittest test_plan_aliases.py
$(shell_quote "$PYTHON_BIN") -m unittest test_plan_activity.py
$(shell_quote "$PYTHON_BIN") -m unittest test_plan_sync_summary.py
$(shell_quote "$PYTHON_BIN") -m unittest test_plan_image_assignments.py
REMOTE
)"

INSTALL_COMMAND="./install_plan_content.sh"
for arg in "${INSTALL_ARGS[@]}"; do
  INSTALL_COMMAND+=" $(shell_quote "$arg")"
done
if [[ "$USE_SUDO" == "1" ]]; then
  INSTALL_COMMAND="sudo ${INSTALL_COMMAND}"
fi
REMOTE_SCRIPT+=$'\n'"$INSTALL_COMMAND"

if [[ "$RESTART_API" == "1" ]]; then
  if [[ "$USE_SUDO" == "1" ]]; then
    REMOTE_SCRIPT+=$'\n'"sudo systemctl restart $(shell_quote "$SERVICE_NAME")"
  else
    REMOTE_SCRIPT+=$'\n'"systemctl restart $(shell_quote "$SERVICE_NAME")"
  fi
fi

VERIFY_COMMAND="cd $(shell_quote "$TARGET_DIR") && $(shell_quote "$PYTHON_BIN") verify_plan_release.py"
for arg in "${VERIFY_ARGS[@]}"; do
  VERIFY_COMMAND+=" $(shell_quote "$arg")"
done
if [[ "$USE_SUDO" == "1" ]]; then
  VERIFY_COMMAND="cd $(shell_quote "$TARGET_DIR") && sudo $(shell_quote "$PYTHON_BIN") verify_plan_release.py"
  for arg in "${VERIFY_ARGS[@]}"; do
    VERIFY_COMMAND+=" $(shell_quote "$arg")"
  done
fi
REMOTE_SCRIPT+=$'\n'"$VERIFY_COMMAND"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run only. No SSH or SCP command will be executed."
  echo "Temporary package: $ARCHIVE"
  echo "Temporary checksum: $CHECKSUM"
  echo "Temporary files are removed when dry-run exits."
  echo
  echo "Would create remote directory:"
  echo "  ssh $(shell_quote "$HOST") \"mkdir -p $(shell_quote "$REMOTE_DIR")\""
  echo
  echo "Would upload:"
  echo "  scp $(shell_quote "$ARCHIVE") $(shell_quote "$CHECKSUM") $(shell_quote "${HOST}:${REMOTE_DIR}/")"
  echo
  echo "Would run remote script:"
  echo "$REMOTE_SCRIPT"
  exit 0
fi

echo "Creating remote upload directory: ${HOST}:${REMOTE_DIR}"
ssh "$HOST" "mkdir -p $(shell_quote "$REMOTE_DIR")"

echo "Uploading package"
scp "$ARCHIVE" "$CHECKSUM" "${HOST}:${REMOTE_DIR}/"

echo "Running remote install and verification"
ssh "$HOST" "bash -s" <<<"$REMOTE_SCRIPT"
echo "Remote plan-content deployment complete."
