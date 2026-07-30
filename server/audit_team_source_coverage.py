#!/usr/bin/env python3
"""Audit public team metadata coverage for current bettable matches."""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from typing import Any


def _json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "caimaster-audit/1"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def _normalized(value: Any) -> str:
    return "".join(str(value or "").lower().split())


def _candidate_names(team: dict[str, Any]) -> list[str]:
    values = [
        team.get("strTeam"),
        team.get("strTeamShort"),
        team.get("strAlternate"),
        team.get("strTeamAlternate"),
    ]
    names: list[str] = []
    for value in values:
        if not value:
            continue
        for item in str(value).replace(";", ",").split(","):
            normalized = _normalized(item)
            if normalized and normalized not in names:
                names.append(normalized)
    return names


def _search_team(name: str, key: str) -> dict[str, Any]:
    query = urllib.parse.urlencode({"t": name})
    url = f"https://www.thesportsdb.com/api/v1/json/{key}/searchteams.php?{query}"
    payload = _json(url)
    candidates = [
        item for item in (payload.get("teams") or []) if isinstance(item, dict)
    ]
    wanted = _normalized(name)
    exact = [item for item in candidates if wanted in _candidate_names(item)]
    if len(exact) == 1:
        selected = exact[0]
        return {
            "status": "exact",
            "sourceTeamId": str(selected.get("idTeam") or ""),
            "sourceName": str(selected.get("strTeam") or ""),
            "league": str(selected.get("strLeague") or ""),
            "badge": str(selected.get("strBadge") or ""),
        }
    return {
        "status": "ambiguous" if candidates else "missing",
        "candidateCount": len(candidates),
        "candidates": [
            {
                "id": str(item.get("idTeam") or ""),
                "name": str(item.get("strTeam") or ""),
                "league": str(item.get("strLeague") or ""),
            }
            for item in candidates[:5]
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://api.cclloo.com")
    parser.add_argument("--api-key", default="123")
    parser.add_argument("--delay", type=float, default=2.1)
    args = parser.parse_args()

    payload = _json(f"{args.base_url.rstrip('/')}/v1/matches/bettable?limit=150")
    matches = [
        item for item in (payload.get("items") or []) if isinstance(item, dict)
    ]
    teams: dict[str, list[str]] = {}
    for match in matches:
        label = f"{match.get('number', '')} {match.get('league', '')}".strip()
        for key in ("home", "away"):
            name = str(match.get(key) or "").strip()
            if name:
                teams.setdefault(name, []).append(label)

    results = []
    for index, (name, appearances) in enumerate(sorted(teams.items())):
        if index:
            time.sleep(max(0, args.delay))
        try:
            result = _search_team(name, args.api_key)
        except Exception as error:
            result = {"status": "error", "error": str(error)}
        results.append({"team": name, "matches": appearances, **result})

    counts: dict[str, int] = {}
    for item in results:
        status = str(item["status"])
        counts[status] = counts.get(status, 0) + 1
    exact = counts.get("exact", 0)
    total = len(results)
    output = {
        "source": "TheSportsDB",
        "matchCount": len(matches),
        "teamCount": total,
        "counts": counts,
        "exactCoverage": 0 if total == 0 else round(exact / total, 4),
        "results": results,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
