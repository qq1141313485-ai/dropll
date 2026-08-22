#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SOURCE_DIR}/../.." && pwd)"
OUTPUT_DIR="${1:-${REPO_ROOT}/dist}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PACKAGE_NAME="caimaster-plan-content-${STAMP}"
WORK_DIR="$(mktemp -d)"

FILES=(
  README.md
  api.env.example
  app_plan_smoke.py
  caimaster-plan-source-sync.service
  caimaster-plan-source-sync.timer
  deploy_check.py
  deploy_plan_content_remote.sh
  install_plan_content.sh
  manage_api_env.py
  package_plan_content.sh
  patch_api_app.py
  plan_admin.html
  privacy.html
  support.html
  plan_image_classifier.py
  plan_source_common.py
  plan_source_map.example.json
  plan_source_sync.py
  plans.py
  requirements.txt
  test_app_plan_smoke.py
  test_deploy_check.py
  test_manage_api_env.py
  test_plan_activity.py
  test_plan_aliases.py
  test_plan_image_classifier.py
  test_patch_api_app.py
  test_plan_source_sync.py
  test_plan_sync_summary.py
  test_verify_plan_release.py
  verify_plan_release.py
)

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
mkdir -p "${WORK_DIR}/${PACKAGE_NAME}"

for file in "${FILES[@]}"; do
  source="${SOURCE_DIR}/${file}"
  target="${WORK_DIR}/${PACKAGE_NAME}/${file}"
  if [[ ! -f "$source" ]]; then
    echo "Missing package file: $source" >&2
    exit 1
  fi
  case "$file" in
    *.sh|*.service|*.timer)
      sed 's/\r$//' "$source" > "$target"
      chmod 0644 "$target"
      ;;
    *)
      install -m 0644 "$source" "$target"
      ;;
  esac
done
chmod 0755 "${WORK_DIR}/${PACKAGE_NAME}/install_plan_content.sh"
chmod 0755 "${WORK_DIR}/${PACKAGE_NAME}/deploy_plan_content_remote.sh"
chmod 0755 "${WORK_DIR}/${PACKAGE_NAME}/package_plan_content.sh" 2>/dev/null || true

for script in "${WORK_DIR}/${PACKAGE_NAME}"/*.sh; do
  bash -n "$script"
done

ARCHIVE="${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"

(
  cd "$WORK_DIR"
  tar -czf "$ARCHIVE" "$PACKAGE_NAME"
)

(
  cd "$OUTPUT_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
  else
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
  fi
)

echo "Created $ARCHIVE"
echo "Created $CHECKSUM"
echo "Upload and install:"
echo "  tar -xzf $(basename "$ARCHIVE")"
echo "  cd $PACKAGE_NAME"
echo "  ./install_plan_content.sh --skip-dry-run"
