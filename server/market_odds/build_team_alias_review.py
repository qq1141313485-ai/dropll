#!/usr/bin/env python3
"""Build a review-only team alias queue from time-aligned provider fixtures.

The output is intentionally not consumable by the production matchers. A human
must review candidates and place approved names in the explicit team map or the
team metadata whitelist.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


SHANGHAI = timezone(timedelta(hours=8))


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        # Official fixtures use local Beijing time without an offset.
        return parsed.replace(tzinfo=SHANGHAI) if parsed.tzinfo is None else parsed
    except ValueError:
        return None


def build_review_queue(
    coverage: dict[str, Any],
    provider_fixtures: dict[str, list[dict[str, Any]]],
    maximum_delta_minutes: int = 2,
) -> list[dict[str, Any]]:
    """Return only unambiguous, time-aligned alias candidates for review."""
    queue: list[dict[str, Any]] = []
    for item in coverage.get("items", []):
        if not isinstance(item, dict):
            continue
        if item.get("status") not in {"unmatched", "review"}:
            continue
        sport_key = str(item.get("sportKey") or "").strip()
        kickoff = _parse_time(item.get("kickoff"))
        home = str(item.get("home") or "").strip()
        away = str(item.get("away") or "").strip()
        if not sport_key or kickoff is None or not home or not away:
            continue
        provider_home = str(item.get("providerHome") or "").strip()
        provider_away = str(item.get("providerAway") or "").strip()
        if item.get("status") == "review" and provider_home and provider_away:
            queue.append(
                {
                    "status": "review_required",
                    "reason": str(item.get("reason") or "strict matcher requires review"),
                    "matchId": item.get("matchId"),
                    "number": item.get("number"),
                    "league": item.get("league"),
                    "kickoff": item.get("kickoff"),
                    "kickoffDeltaMinutes": item.get("kickoffDeltaMinutes"),
                    "providerEventId": item.get("providerEventId"),
                    "candidates": [
                        {"localName": home, "providerName": provider_home},
                        {"localName": away, "providerName": provider_away},
                    ],
                }
            )
            continue

        candidates: list[tuple[int, dict[str, Any]]] = []
        for fixture in provider_fixtures.get(sport_key, []):
            if not isinstance(fixture, dict):
                continue
            commence = _parse_time(fixture.get("commence_time"))
            provider_home = str(fixture.get("home_team") or "").strip()
            provider_away = str(fixture.get("away_team") or "").strip()
            if commence is None or not provider_home or not provider_away:
                continue
            delta = abs(int((commence - kickoff).total_seconds() // 60))
            if delta <= maximum_delta_minutes:
                candidates.append((delta, fixture))

        # A time collision is not a safe basis for alias creation.
        if len(candidates) != 1:
            continue
        delta, fixture = candidates[0]
        queue.append(
            {
                "status": "review_required",
                "reason": "unique provider fixture at matching kickoff",
                "matchId": item.get("matchId"),
                "number": item.get("number"),
                "league": item.get("league"),
                "kickoff": item.get("kickoff"),
                "kickoffDeltaMinutes": delta,
                "providerEventId": fixture.get("id"),
                "candidates": [
                    {"localName": home, "providerName": fixture["home_team"]},
                    {"localName": away, "providerName": fixture["away_team"]},
                ],
            }
        )
    return queue


def merge_review_queue(
    current: list[dict[str, Any]],
    previous: list[dict[str, Any]],
    team_aliases: dict[str, list[str]],
    active_match_ids: set[str],
) -> list[dict[str, Any]]:
    """Keep unresolved review candidates across rotations without duplicates."""
    merged: dict[str, dict[str, Any]] = {}
    for item in previous + current:
        if not isinstance(item, dict):
            continue
        match_id = str(item.get("matchId") or "")
        candidates = item.get("candidates")
        if not match_id or match_id not in active_match_ids or not isinstance(candidates, list):
            continue
        unresolved = any(
            isinstance(candidate, dict)
            and str(candidate.get("providerName") or "")
            not in team_aliases.get(str(candidate.get("localName") or ""), [])
            for candidate in candidates
        )
        if unresolved:
            merged[match_id] = item
    return sorted(merged.values(), key=lambda item: (str(item.get("kickoff") or ""), str(item.get("matchId") or "")))


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coverage", type=Path, required=True)
    parser.add_argument("--provider-fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--maximum-delta-minutes", type=int, default=2)
    args = parser.parse_args()

    coverage = _read_json(args.coverage)
    fixtures = _read_json(args.provider_fixtures)
    if not isinstance(coverage, dict) or not isinstance(fixtures, dict):
        raise ValueError("coverage and provider fixtures must both be JSON objects")
    queue = build_review_queue(coverage, fixtures, args.maximum_delta_minutes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps({"items": queue}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"reviewCount": len(queue), "output": str(args.output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
