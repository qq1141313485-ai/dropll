#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${CAIMASTER_PLAN_DEPLOY_DIR:-/opt/caimaster-api}"
SYSTEMD_DIR="${CAIMASTER_SYSTEMD_DIR:-/etc/systemd/system}"
PYTHON_BIN="${CAIMASTER_PLAN_PYTHON:-${TARGET_DIR}/.venv/bin/python3.11}"
STAMP="$(date +%Y%m%d-%H%M%S)"

PLAN_FILES=(
  plans.py
  plan_admin.html
  privacy.html
  support.html
  plan_source_common.py
  plan_source_sync.py
  plan_image_classifier.py
  deploy_check.py
  app_plan_smoke.py
  manage_api_env.py
  patch_api_app.py
  verify_plan_release.py
  requirements.txt
)

usage() {
  cat <<'USAGE'
Usage: install_plan_content.sh [--target /opt/caimaster-api] [--python /path/to/python] [--install-deps] [--patch-api-app] [--enable-timer] [--skip-deploy-check] [--skip-dry-run] [--no-env-init]

Copies plan-content backend files to the target directory, creates backups,
installs systemd unit files when writable, runs syntax/deploy checks, and
optionally runs source-sync dry-run and enables the timer.

Environment overrides:
  CAIMASTER_PLAN_DEPLOY_DIR
  CAIMASTER_SYSTEMD_DIR
  CAIMASTER_PLAN_PYTHON
USAGE
}

INSTALL_DEPS=0
ENABLE_TIMER=0
SKIP_DRY_RUN=0
ENV_INIT=1
SKIP_DEPLOY_CHECK=0
PATCH_API_APP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_DIR="$2"
      PYTHON_BIN="${CAIMASTER_PLAN_PYTHON:-${TARGET_DIR}/.venv/bin/python3.11}"
      shift 2
      ;;
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --install-deps)
      INSTALL_DEPS=1
      shift
      ;;
    --patch-api-app)
      PATCH_API_APP=1
      shift
      ;;
    --enable-timer)
      ENABLE_TIMER=1
      shift
      ;;
    --skip-dry-run)
      SKIP_DRY_RUN=1
      shift
      ;;
    --skip-deploy-check)
      SKIP_DEPLOY_CHECK=1
      shift
      ;;
    --no-env-init)
      ENV_INIT=0
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

backup_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    cp -a "$path" "${path}.bak-${STAMP}"
  fi
}

same_path() {
  local left="$1"
  local right="$2"
  [[ "$(cd "$(dirname "$left")" && pwd)/$(basename "$left")" == "$(cd "$(dirname "$right")" && pwd)/$(basename "$right")" ]]
}

install_file() {
  local name="$1"
  local source="${SOURCE_DIR}/${name}"
  local target="${TARGET_DIR}/${name}"
  if [[ ! -f "$source" ]]; then
    echo "Missing source file: $source" >&2
    exit 1
  fi
  if same_path "$source" "$target"; then
    return
  fi
  backup_file "$target"
  install -m 0644 "$source" "$target"
}

echo "Installing plan content files to ${TARGET_DIR}"
mkdir -p "$TARGET_DIR" "${TARGET_DIR}/plan-media"

for file in "${PLAN_FILES[@]}"; do
  install_file "$file"
done
if ! same_path "${SOURCE_DIR}/install_plan_content.sh" "${TARGET_DIR}/install_plan_content.sh"; then
  backup_file "${TARGET_DIR}/install_plan_content.sh"
  install -m 0755 "${SOURCE_DIR}/install_plan_content.sh" "${TARGET_DIR}/install_plan_content.sh"
fi

if [[ ! -f "${TARGET_DIR}/plan_source_map.json" ]]; then
  install -m 0600 "${SOURCE_DIR}/plan_source_map.example.json" "${TARGET_DIR}/plan_source_map.json"
  echo "Created ${TARGET_DIR}/plan_source_map.json from example"
fi

if [[ ! -f "${TARGET_DIR}/api.env" ]]; then
  install -m 0600 "${SOURCE_DIR}/api.env.example" "${TARGET_DIR}/api.env"
  echo "Created ${TARGET_DIR}/api.env from example"
fi

if [[ -d "$SYSTEMD_DIR" && -w "$SYSTEMD_DIR" ]]; then
  for unit in caimaster-plan-source-sync.service caimaster-plan-source-sync.timer; do
    backup_file "${SYSTEMD_DIR}/${unit}"
    install -m 0644 "${SOURCE_DIR}/${unit}" "${SYSTEMD_DIR}/${unit}"
  done
else
  echo "Skipping systemd unit install; ${SYSTEMD_DIR} is not writable"
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python not found at ${PYTHON_BIN}" >&2
  echo "Create the server virtualenv first, or pass --python /path/to/python" >&2
  exit 1
fi

if [[ "$INSTALL_DEPS" == "1" ]]; then
  "$PYTHON_BIN" -m pip install -r "${TARGET_DIR}/requirements.txt"
fi

if [[ "$ENV_INIT" == "1" ]]; then
  echo "Initializing api.env defaults and admin token"
  "$PYTHON_BIN" "${TARGET_DIR}/manage_api_env.py" --env "${TARGET_DIR}/api.env" init
fi

if [[ -f "${TARGET_DIR}/api.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${TARGET_DIR}/api.env"
  set +a
fi

echo "Running Python syntax check"
PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-${TARGET_DIR}/.pycache}" "$PYTHON_BIN" -m py_compile \
  "${TARGET_DIR}/plans.py" \
  "${TARGET_DIR}/plan_source_common.py" \
  "${TARGET_DIR}/plan_source_sync.py" \
  "${TARGET_DIR}/deploy_check.py" \
  "${TARGET_DIR}/app_plan_smoke.py" \
  "${TARGET_DIR}/manage_api_env.py" \
  "${TARGET_DIR}/patch_api_app.py" \
  "${TARGET_DIR}/verify_plan_release.py"

if [[ "$PATCH_API_APP" == "1" ]]; then
  echo "Patching FastAPI app.py to install plan routes"
  "$PYTHON_BIN" "${TARGET_DIR}/patch_api_app.py" --app "${TARGET_DIR}/app.py"
fi

if [[ "$SKIP_DEPLOY_CHECK" != "1" ]]; then
  echo "Running deployment check"
  (
    cd "$TARGET_DIR"
    "$PYTHON_BIN" deploy_check.py
  )
else
  echo "Skipping deployment check"
fi

if [[ "$SKIP_DRY_RUN" != "1" ]]; then
  echo "Running source sync dry-run"
  (
    cd "$TARGET_DIR"
    CAIMASTER_PLAN_SOURCE_DRY_RUN=1 "$PYTHON_BIN" plan_source_sync.py
  )
fi

if [[ "$ENABLE_TIMER" == "1" ]]; then
  systemctl daemon-reload
  systemctl enable --now caimaster-plan-source-sync.timer
  systemctl start caimaster-plan-source-sync.service
  systemctl status caimaster-plan-source-sync.timer --no-pager
else
  echo "Timer not enabled. Re-run with --enable-timer after checks pass."
fi

echo "Plan content deployment complete."
