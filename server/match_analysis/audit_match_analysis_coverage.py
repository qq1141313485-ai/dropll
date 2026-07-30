#!/usr/bin/env python3
"""Audit detail-analysis coverage for current bettable football matches."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REQUIRED = (
    "headToHead",
    "recentHome",
    "recentAway",
    "keyPlayers",
    "futureHome",
    "futureAway",
)
OPTIONAL = ("standings", "injuries")


def _json(url: str, timeout: int = 40) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "caimaster-audit/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def build_report(
    matches: list[dict[str, Any]],
    fetch_analysis: Any,
) -> dict[str, Any]:
    rows = []
    for match in matches:
        started = time.monotonic()
        match_id = str(match.get("id") or match.get("matchId") or "")
        label = " ".join(
            value
            for value in (
                str(match.get("number") or "").strip(),
                str(match.get("home") or "").strip(),
                "vs",
                str(match.get("away") or "").strip(),
            )
            if value
        )
        try:
            payload = fetch_analysis(match_id)
            availability = payload.get("availability")
            availability = availability if isinstance(availability, dict) else {}
            missing = [key for key in REQUIRED if availability.get(key) is not True]
            rows.append(
                {
                    "matchId": match_id,
                    "label": label,
                    "latencyMs": round((time.monotonic() - started) * 1000),
                    "missingRequired": missing,
                    "optional": {
                        key: availability.get(key) is True for key in OPTIONAL
                    },
                    "error": "",
                }
            )
        except Exception as error:
            rows.append(
                {
                    "matchId": match_id,
                    "label": label,
                    "latencyMs": round((time.monotonic() - started) * 1000),
                    "missingRequired": list(REQUIRED),
                    "optional": {key: False for key in OPTIONAL},
                    "error": type(error).__name__,
                }
            )
    failures = [row for row in rows if row["error"]]
    incomplete = [row for row in rows if row["missingRequired"]]
    return {
        "checkedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "matchCount": len(rows),
        "failureCount": len(failures),
        "incompleteCount": len(incomplete),
        "healthy": not failures and not incomplete,
        "maxLatencyMs": max((row["latencyMs"] for row in rows), default=0),
        "matches": rows,
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
        "--output",
        type=Path,
        default=Path("/opt/caimaster-api/work/match-analysis-coverage.json"),
    )
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")
    payload = _json(f"{base_url}/v1/matches/bettable?limit=150")
    matches = [
        item for item in (payload.get("items") or []) if isinstance(item, dict)
    ]

    def fetch(match_id: str) -> dict[str, Any]:
        encoded = urllib.parse.quote(match_id, safe="")
        return _json(f"{base_url}/v1/matches/{encoded}/analysis")

    report = build_report(matches, fetch)
    _write_json(args.output, report)
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
