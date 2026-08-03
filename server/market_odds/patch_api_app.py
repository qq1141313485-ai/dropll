from __future__ import annotations

import argparse
import re
import shutil
import sys
import time
from pathlib import Path


DEFAULT_APP_PATH = Path("/opt/caimaster-api/app.py")
IMPORT_LINE = "from market_odds import install_market_odds_routes"
APP_ASSIGNMENT_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*FastAPI\s*\(")
INSTALL_CALL_RE = re.compile(r"\binstall_market_odds_routes\s*\(")


class PatchError(RuntimeError):
    pass


def _find_import_position(lines: list[str]) -> int:
    last_import = -1
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(("import ", "from ")):
            last_import = index
            continue
        if last_import >= 0 and stripped and not stripped.startswith("#"):
            break
    return last_import + 1 if last_import >= 0 else 0


def patch_text(source: str) -> tuple[str, bool]:
    lines = source.splitlines()
    changed = False
    if not any(IMPORT_LINE in line for line in lines):
        lines.insert(_find_import_position(lines), IMPORT_LINE)
        changed = True
    if not any(INSTALL_CALL_RE.search(line) for line in lines):
        app_index = next(
            (
                index
                for index, line in enumerate(lines)
                if APP_ASSIGNMENT_RE.match(line)
            ),
            None,
        )
        if app_index is None:
            raise PatchError("Could not find FastAPI app assignment.")
        balance = 0
        call_index = app_index + 1
        for index in range(app_index, len(lines)):
            balance += lines[index].count("(") - lines[index].count(")")
            if balance <= 0:
                call_index = index + 1
                break
        app_name = APP_ASSIGNMENT_RE.match(lines[app_index]).group(1)  # type: ignore[union-attr]
        lines.insert(call_index, f"install_market_odds_routes({app_name})")
        changed = True
    return "\n".join(lines) + ("\n" if source.endswith("\n") else ""), changed


def patch_file(path: Path, dry_run: bool = False) -> bool:
    if not path.exists():
        raise PatchError(f"Missing app file: {path}")
    updated, changed = patch_text(path.read_text(encoding="utf-8"))
    if not changed:
        return False
    if dry_run:
        return True
    backup = path.with_name(f"{path.name}.bak-market-odds-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, backup)
    path.write_text(updated, encoding="utf-8")
    print(f"backup: {backup}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default=str(DEFAULT_APP_PATH))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        changed = patch_file(Path(args.app), args.dry_run)
    except PatchError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("patched" if changed else "already patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
