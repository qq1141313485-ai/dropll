#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${CAIMASTER_API_DIR:-/opt/caimaster-api}"
PYTHON_BIN="${CAIMASTER_API_PYTHON:-${TARGET_DIR}/.venv/bin/python3.11}"
SERVICE_NAME="${CAIMASTER_API_SERVICE:-caimaster-api.service}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESTART=0
SMOKE_MATCH_ID=""

usage() {
  cat <<'USAGE'
Usage: install_match_analysis.sh [--target /opt/caimaster-api] [--python /path/to/python] [--restart] [--smoke-match 2040634]

Copies the match-analysis package, patches app.py idempotently, and runs
syntax checks. The API service is restarted only with --restart.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_DIR="$2"
      PYTHON_BIN="${CAIMASTER_API_PYTHON:-${TARGET_DIR}/.venv/bin/python3.11}"
      shift 2
      ;;
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    --smoke-match)
      SMOKE_MATCH_ID="$2"
      shift 2
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

if [[ ! -f "${TARGET_DIR}/app.py" ]]; then
  echo "Missing ${TARGET_DIR}/app.py" >&2
  exit 1
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python not found: ${PYTHON_BIN}" >&2
  exit 1
fi

TARGET_PACKAGE="${TARGET_DIR}/match_analysis"
if [[ -e "$TARGET_PACKAGE" ]]; then
  cp -a "$TARGET_PACKAGE" "${TARGET_PACKAGE}.bak-${STAMP}"
fi
mkdir -p "$TARGET_PACKAGE"
install -m 0644 "${SOURCE_DIR}/match_analysis.py" "$TARGET_PACKAGE/match_analysis.py"
install -m 0644 "${SOURCE_DIR}/__init__.py" "$TARGET_PACKAGE/__init__.py"

PYTHONPYCACHEPREFIX="${TARGET_DIR}/.pycache" "$PYTHON_BIN" -m py_compile \
  "$TARGET_PACKAGE/match_analysis.py" \
  "${SOURCE_DIR}/patch_api_app.py"

"$PYTHON_BIN" "${SOURCE_DIR}/patch_api_app.py" --app "${TARGET_DIR}/app.py"
PYTHONPYCACHEPREFIX="${TARGET_DIR}/.pycache" "$PYTHON_BIN" -m py_compile \
  "${TARGET_DIR}/app.py"

if [[ "$RESTART" != "1" ]]; then
  echo "Files installed and checked. Service was not restarted."
  exit 0
fi

systemctl restart "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager

if [[ -n "$SMOKE_MATCH_ID" ]]; then
  "$PYTHON_BIN" - "$SMOKE_MATCH_ID" <<'PY'
import json
import sys
import urllib.request

match_id = sys.argv[1]
url = f"http://127.0.0.1:8787/v1/matches/{match_id}/analysis"
with urllib.request.urlopen(url, timeout=20) as response:
    payload = json.load(response)
if payload.get("matchId") != match_id:
    raise SystemExit("analysis smoke returned the wrong match")
availability = payload.get("availability") or {}
if not any(availability.values()):
    raise SystemExit("analysis smoke returned no available sections")
print(json.dumps({"matchId": match_id, "availability": availability}, ensure_ascii=False))
PY
fi

echo "Match analysis deployment complete."
