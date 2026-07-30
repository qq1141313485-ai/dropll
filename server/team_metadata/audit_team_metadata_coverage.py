#!/usr/bin/env python3
"""Audit exact team-metadata coverage for current bettable matches."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _read_json_url(url: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "caimaster-team-audit/1"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def build_report(
    matches_payload: dict[str, Any],
    manifest_payload: dict[str, Any],
) -> dict[str, Any]:
    appearances: dict[str, list[str]] = {}
    matches = [
        item
        for item in (matches_payload.get("items") or [])
        if isinstance(item, dict)
    ]
    for match in matches:
        label = " ".join(
            part
            for part in (
                str(match.get("number") or "").strip(),
                str(match.get("league") or "").strip(),
            )
            if part
        )
        for key in ("home", "away"):
            name = str(match.get(key) or "").strip()
            if name:
                appearances.setdefault(name, []).append(label)

    mapped = manifest_payload.get("teams")
    mapped_names = set(mapped) if isinstance(mapped, dict) else set()
    missing = [
        {"name": name, "matches": labels}
        for name, labels in sorted(appearances.items())
        if name not in mapped_names
    ]
    total = len(appearances)
    covered = total - len(missing)
    return {
        "checkedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "matchCount": len(matches),
        "teamCount": total,
        "coveredCount": covered,
        "missingCount": len(missing),
        "coverage": 1.0 if total == 0 else round(covered / total, 4),
        "missing": missing,
    }


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        path.chmod(0o644)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8787")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("/opt/caimaster-api/team_metadata/cache/manifest.json"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/opt/caimaster-api/team_metadata/coverage.json"),
    )
    args = parser.parse_args()
    matches = _read_json_url(
        f"{args.base_url.rstrip('/')}/v1/matches/bettable?limit=150"
    )
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    report = build_report(matches, manifest)
    _write_json(args.output, report)
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
