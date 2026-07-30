from __future__ import annotations

import argparse
import re
import shutil
import sys
import time
from pathlib import Path


DEFAULT_APP_PATH = Path("/opt/caimaster-api/app.py")
IMPORT_LINE = "from match_analysis import install_match_analysis_routes"
APP_ASSIGNMENT_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*FastAPI\s*\(")
INSTALL_CALL_RE = re.compile(r"\binstall_match_analysis_routes\s*\(")


class PatchError(RuntimeError):
    pass


def _find_insert_position(lines: list[str]) -> int:
    last_import = -1
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("import ") or stripped.startswith("from "):
            last_import = index
            continue
        if last_import >= 0 and stripped and not stripped.startswith("#"):
            break
    return last_import + 1 if last_import >= 0 else 0


def _find_app_assignment(lines: list[str]) -> tuple[int, str]:
    for index, line in enumerate(lines):
        match = APP_ASSIGNMENT_RE.match(line)
        if match:
            return index, match.group(1)
    raise PatchError("Could not find FastAPI app assignment.")


def _find_call_position(lines: list[str], app_index: int) -> int:
    balance = 0
    seen_open = False
    for index in range(app_index, len(lines)):
        line = lines[index]
        balance += line.count("(") - line.count(")")
        if "(" in line:
            seen_open = True
        if seen_open and balance <= 0:
            return index + 1
    return app_index + 1


def patch_text(source: str) -> tuple[str, bool]:
    lines = source.splitlines()
    changed = False
    has_import = any(IMPORT_LINE in line for line in lines)
    has_call = any(INSTALL_CALL_RE.search(line) for line in lines)
    if has_import and has_call:
        return source, False
    if not has_import:
        lines.insert(_find_insert_position(lines), IMPORT_LINE)
        changed = True
    if not has_call:
        app_index, app_name = _find_app_assignment(lines)
        lines.insert(_find_call_position(lines, app_index), f"install_match_analysis_routes({app_name})")
        changed = True
    trailing_newline = "\n" if source.endswith("\n") else ""
    return "\n".join(lines) + trailing_newline, changed


def patch_file(path: Path, dry_run: bool = False) -> bool:
    if not path.exists():
        raise PatchError(f"Missing app file: {path}")
    source = path.read_text(encoding="utf-8")
    updated, changed = patch_text(source)
    if not changed:
        print(f"{path}: already patched")
        return False
    if dry_run:
        print(f"{path}: would patch")
        return True
    backup = path.with_name(
        f"{path.name}.bak-match-analysis-{time.strftime('%Y%m%d-%H%M%S')}"
    )
    shutil.copy2(path, backup)
    path.write_text(updated, encoding="utf-8")
    print(f"{path}: patched")
    print(f"backup: {backup}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch FastAPI app.py to install match-analysis routes."
    )
    parser.add_argument("--app", default=str(DEFAULT_APP_PATH))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        patch_file(Path(args.app), dry_run=args.dry_run)
    except PatchError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
