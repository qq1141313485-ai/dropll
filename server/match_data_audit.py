#!/usr/bin/env python3
"""Audit public match feeds for status and score inconsistencies."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


SHANGHAI = timezone(timedelta(hours=8))
LIVE_STATES = {"live", "halftime"}


def _get_json(base_url: str, path: str) -> dict[str, Any]:
    url = f"{base_url.rstrip('/')}{path}"
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "caimaster-audit/1"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def _items(base_url: str, path: str) -> list[dict[str, Any]]:
    values = _get_json(base_url, path).get("items", [])
    return [value for value in values if isinstance(value, dict)]


def _parse_score(value: Any) -> tuple[int, int] | None:
    if not isinstance(value, str):
        return None
    parts = value.strip().replace("-", ":").split(":")
    if len(parts) != 2:
        return None
    try:
        home, away = (int(part.strip()) for part in parts)
    except ValueError:
        return None
    if home < 0 or away < 0:
        return None
    return home, away


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=SHANGHAI)
    return parsed.astimezone(SHANGHAI)


def _label(match: dict[str, Any]) -> str:
    return " ".join(
        str(match.get(key) or "")
        for key in ("id", "number", "home", "away")
    ).strip()


def audit(base_url: str) -> dict[str, Any]:
    today = _items(base_url, "/v1/matches?scope=today&limit=300")
    home = _items(base_url, "/v1/matches/live?limit=300")
    results = _items(base_url, "/v1/matches/results?limit=300")
    now = datetime.now(SHANGHAI)
    errors: list[str] = []
    warnings: list[str] = []

    feeds = {"today": today, "home": home, "results": results}
    for feed_name, matches in feeds.items():
        ids = [str(match.get("id") or match.get("matchId") or "") for match in matches]
        duplicates = sorted(match_id for match_id, count in Counter(ids).items() if match_id and count > 1)
        if duplicates:
            errors.append(f"{feed_name}: duplicate ids {','.join(duplicates)}")

    by_id: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    for feed_name, matches in feeds.items():
        for match in matches:
            match_id = str(match.get("id") or match.get("matchId") or "")
            if match_id:
                by_id.setdefault(match_id, []).append((feed_name, match))

    for match_id, copies in by_id.items():
        states = {str(match.get("matchState") or "") for _, match in copies}
        finals = {str(match.get("finalScore") or "") for _, match in copies}
        if len(states) > 1:
            errors.append(f"{match_id}: conflicting states {sorted(states)}")
        if len(finals) > 1:
            errors.append(f"{match_id}: conflicting final scores {sorted(finals)}")

    for feed_name, matches in feeds.items():
        for match in matches:
            label = _label(match)
            state = str(match.get("matchState") or "")
            score = _parse_score(match.get("score"))
            final_score = _parse_score(match.get("finalScore"))
            half_score = _parse_score(match.get("halfTimeScore"))
            kickoff = _parse_time(match.get("kickoff"))
            titan_updated = _parse_time(match.get("titanLastUpdated"))

            if state == "finished" and final_score is None:
                errors.append(f"{feed_name}: finished without final score: {label}")
            if state == "not_started" and (score is not None or final_score is not None):
                errors.append(f"{feed_name}: not-started match has score: {label}")
            if state in LIVE_STATES and score is None:
                warnings.append(f"{feed_name}: live match has no score: {label}")
            if half_score and final_score and (
                half_score[0] > final_score[0] or half_score[1] > final_score[1]
            ):
                errors.append(f"{feed_name}: half score exceeds final score: {label}")

            official = match.get("officialResults")
            if isinstance(official, dict):
                official_score = _parse_score(official.get("sectionsNo999"))
                if official_score and final_score and official_score != final_score:
                    errors.append(f"{feed_name}: official/final score mismatch: {label}")

            if state in LIVE_STATES and kickoff and now - kickoff > timedelta(hours=4):
                errors.append(f"{feed_name}: live state over four hours after kickoff: {label}")
            if state in LIVE_STATES and (
                titan_updated is None or now - titan_updated > timedelta(minutes=5)
            ):
                warnings.append(f"{feed_name}: live source older than five minutes: {label}")

    result_ids = {str(match.get("id") or match.get("matchId") or "") for match in results}
    for match in home:
        match_id = str(match.get("id") or match.get("matchId") or "")
        if match.get("matchState") == "finished" or match_id in result_ids:
            errors.append(f"home: finished match still present: {_label(match)}")

    return {
        "checkedAt": now.isoformat(timespec="seconds"),
        "baseUrl": base_url.rstrip("/"),
        "counts": {name: len(matches) for name, matches in feeds.items()},
        "states": {
            name: dict(sorted(Counter(str(match.get("matchState") or "unknown") for match in matches).items()))
            for name, matches in feeds.items()
        },
        "errors": errors,
        "warnings": warnings,
        "ok": not errors,
    }


def append_history(
    path: Path,
    result: dict[str, Any],
    *,
    retention_days: int = 8,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cutoff = datetime.now(SHANGHAI) - timedelta(days=max(1, retention_days))
    retained: list[str] = []
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                record = json.loads(line)
                checked_at = _parse_time(record.get("checkedAt"))
            except (json.JSONDecodeError, AttributeError):
                continue
            if checked_at is not None and checked_at >= cutoff:
                retained.append(json.dumps(record, ensure_ascii=False))
    retained.append(json.dumps(result, ensure_ascii=False))
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text("\n".join(retained) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://api.cclloo.com")
    parser.add_argument("--history-file", type=Path)
    parser.add_argument("--retention-days", type=int, default=8)
    args = parser.parse_args()
    try:
        result = audit(args.base_url)
    except Exception as error:
        result = {
            "checkedAt": datetime.now(SHANGHAI).isoformat(timespec="seconds"),
            "baseUrl": args.base_url.rstrip("/"),
            "ok": False,
            "requestError": str(error),
        }
        if args.history_file:
            append_history(
                args.history_file,
                result,
                retention_days=args.retention_days,
            )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2
    if args.history_file:
        append_history(
            args.history_file,
            result,
            retention_days=args.retention_days,
        )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
