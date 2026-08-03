#!/usr/bin/env python3
"""Audit bookmaker market coverage against official lottery matches."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, Iterable


SHANGHAI = timezone(timedelta(hours=8))
MARKETS = ("h2h", "spreads", "totals")

try:
    from rapidfuzz.fuzz import ratio as _rapid_ratio
except ImportError:  # pragma: no cover - exercised on minimal server installs
    _rapid_ratio = None


@dataclass(frozen=True)
class MatchDecision:
    status: str
    event: dict[str, Any] | None
    score: float
    kickoff_delta_minutes: int | None
    reason: str


def _json_get(url: str, *, headers: dict[str, str] | None = None) -> tuple[Any, dict[str, str]]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "caimaster-market-odds-audit/1",
            **(headers or {}),
        },
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.load(response), {key.lower(): value for key, value in response.headers.items()}


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


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


def normalize_name(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or "")).casefold()
    text = "".join(character for character in text if not unicodedata.combining(character))
    return re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "", text)


def name_ratio(left: Any, right: Any) -> float:
    first = normalize_name(left)
    second = normalize_name(right)
    if not first or not second:
        return 0.0
    if _rapid_ratio is not None:
        return float(_rapid_ratio(first, second))
    return SequenceMatcher(None, first, second).ratio() * 100


def _names_for(official_name: str, aliases: dict[str, list[str]]) -> list[str]:
    values = [official_name, *aliases.get(official_name, [])]
    return list(dict.fromkeys(str(value).strip() for value in values if str(value).strip()))


def _best_name_ratio(official_name: str, provider_name: Any, aliases: dict[str, list[str]]) -> float:
    return max(name_ratio(candidate, provider_name) for candidate in _names_for(official_name, aliases))


def _event_score(
    match: dict[str, Any],
    event: dict[str, Any],
    aliases: dict[str, list[str]],
) -> tuple[float, int | None]:
    home_score = _best_name_ratio(str(match.get("home") or ""), event.get("home_team"), aliases)
    away_score = _best_name_ratio(str(match.get("away") or ""), event.get("away_team"), aliases)
    kickoff = _parse_time(match.get("kickoff"))
    commence = _parse_time(event.get("commence_time"))
    delta = None
    if kickoff is not None and commence is not None:
        delta = round(abs((kickoff - commence).total_seconds()) / 60)
    return (home_score + away_score) / 2, delta


def decide_event(
    match: dict[str, Any],
    events: Iterable[dict[str, Any]],
    aliases: dict[str, list[str]],
) -> MatchDecision:
    candidates: list[tuple[float, int | None, dict[str, Any]]] = []
    for event in events:
        score, delta = _event_score(match, event, aliases)
        if delta is None or delta <= 180:
            candidates.append((score, delta, event))
    if not candidates:
        return MatchDecision("unmatched", None, 0, None, "no event within 180 minutes")

    candidates.sort(key=lambda item: (-item[0], item[1] if item[1] is not None else 10_000))
    best_score, best_delta, best_event = candidates[0]
    runner_up = candidates[1][0] if len(candidates) > 1 else 0
    margin = best_score - runner_up

    if best_score >= 90 and best_delta is not None and best_delta <= 90 and margin >= 8:
        return MatchDecision("matched", best_event, round(best_score, 1), best_delta, "strict match")
    if best_score >= 75 and best_delta is not None and best_delta <= 180 and margin >= 5:
        return MatchDecision("review", best_event, round(best_score, 1), best_delta, "manual review required")
    return MatchDecision(
        "unmatched",
        None,
        round(best_score, 1),
        best_delta,
        "team similarity, kickoff, or candidate margin below threshold",
    )


def market_coverage(event: dict[str, Any] | None) -> dict[str, Any]:
    counts = {market: 0 for market in MARKETS}
    bookmakers = event.get("bookmakers", []) if event else []
    for bookmaker in bookmakers if isinstance(bookmakers, list) else []:
        available = {
            str(market.get("key") or "")
            for market in bookmaker.get("markets", [])
            if isinstance(market, dict)
        }
        for market in MARKETS:
            counts[market] += int(market in available)
    return {
        "bookmakerCount": len(bookmakers) if isinstance(bookmakers, list) else 0,
        "markets": counts,
        "complete": all(counts[market] > 0 for market in MARKETS),
    }


def _public_event(event: dict[str, Any]) -> dict[str, Any]:
    bookmakers: list[dict[str, Any]] = []
    for bookmaker in event.get("bookmakers", []):
        if not isinstance(bookmaker, dict):
            continue
        markets: dict[str, list[dict[str, Any]]] = {}
        for market in bookmaker.get("markets", []):
            if not isinstance(market, dict) or market.get("key") not in MARKETS:
                continue
            outcomes = []
            for outcome in market.get("outcomes", []):
                if not isinstance(outcome, dict):
                    continue
                item = {
                    "name": str(outcome.get("name") or ""),
                    "price": outcome.get("price"),
                }
                if outcome.get("point") is not None:
                    item["point"] = outcome["point"]
                outcomes.append(item)
            markets[str(market["key"])] = outcomes
        if markets:
            bookmakers.append(
                {
                    "key": str(bookmaker.get("key") or ""),
                    "title": str(bookmaker.get("title") or bookmaker.get("key") or ""),
                    "lastUpdate": bookmaker.get("last_update"),
                    "markets": markets,
                }
            )
    return {
        "providerEventId": str(event.get("id") or ""),
        "commenceTime": event.get("commence_time"),
        "home": str(event.get("home_team") or ""),
        "away": str(event.get("away_team") or ""),
        "bookmakers": bookmakers,
    }


def build_public_snapshot(
    report: dict[str, Any],
    events_by_sport: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    events = {
        str(event.get("id") or ""): event
        for values in events_by_sport.values()
        for event in values
        if isinstance(event, dict) and event.get("id")
    }
    items: dict[str, dict[str, Any]] = {}
    for row in report.get("items", []):
        if not isinstance(row, dict) or row.get("status") != "matched":
            continue
        match_id = str(row.get("matchId") or "")
        event = events.get(str(row.get("providerEventId") or ""))
        if not match_id or event is None:
            continue
        items[match_id] = {
            "matchId": match_id,
            "number": row.get("number"),
            "league": row.get("league"),
            "home": row.get("home"),
            "away": row.get("away"),
            "kickoff": row.get("kickoff"),
            "matchScore": row.get("score"),
            "kickoffDeltaMinutes": row.get("kickoffDeltaMinutes"),
            **_public_event(event),
        }
    return {
        "version": 1,
        "provider": "the-odds-api",
        "generatedAt": report.get("checkedAt"),
        "items": items,
    }


def merge_opening_prices(
    current: dict[str, Any],
    previous: dict[str, Any] | None,
) -> dict[str, Any]:
    previous_items = previous.get("items", {}) if isinstance(previous, dict) else {}
    for match_id, item in current.get("items", {}).items():
        old_item = previous_items.get(match_id, {}) if isinstance(previous_items, dict) else {}
        old_prices: dict[tuple[str, str, str, str], Any] = {}
        for bookmaker in old_item.get("bookmakers", []):
            bookmaker_key = str(bookmaker.get("key") or "")
            for market_key, outcomes in bookmaker.get("markets", {}).items():
                for outcome in outcomes if isinstance(outcomes, list) else []:
                    key = (
                        bookmaker_key,
                        str(market_key),
                        str(outcome.get("name") or ""),
                        str(outcome.get("point") or ""),
                    )
                    old_prices[key] = outcome.get("openingPrice", outcome.get("price"))
        for bookmaker in item.get("bookmakers", []):
            bookmaker_key = str(bookmaker.get("key") or "")
            for market_key, outcomes in bookmaker.get("markets", {}).items():
                for outcome in outcomes if isinstance(outcomes, list) else []:
                    key = (
                        bookmaker_key,
                        str(market_key),
                        str(outcome.get("name") or ""),
                        str(outcome.get("point") or ""),
                    )
                    outcome["openingPrice"] = old_prices.get(key, outcome.get("price"))
    return current


def _write_json_atomic(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _load_matches(base_url: str, matches_file: Path | None) -> list[dict[str, Any]]:
    if matches_file is not None:
        payload = _read_json(matches_file)
    else:
        payload, _ = _json_get(f"{base_url.rstrip('/')}/v1/matches/bettable?limit=300")
    values = payload.get("items", payload) if isinstance(payload, dict) else payload
    return [item for item in values if isinstance(item, dict)] if isinstance(values, list) else []


def _load_provider_events(
    sport_keys: Iterable[str],
    api_key: str,
    region: str,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, int | None]]:
    events: dict[str, list[dict[str, Any]]] = {}
    usage = {"last": 0, "used": None, "remaining": None}
    for sport_key in sorted(set(sport_keys)):
        query = urllib.parse.urlencode(
            {
                "apiKey": api_key,
                "regions": region,
                "markets": ",".join(MARKETS),
                "oddsFormat": "decimal",
                "dateFormat": "iso",
            }
        )
        payload, headers = _json_get(
            f"https://api.the-odds-api.com/v4/sports/{sport_key}/odds?{query}"
        )
        events[sport_key] = [item for item in payload if isinstance(item, dict)] if isinstance(payload, list) else []
        for source, target in (
            ("x-requests-last", "last"),
            ("x-requests-used", "used"),
            ("x-requests-remaining", "remaining"),
        ):
            try:
                value = int(headers[source])
            except (KeyError, TypeError, ValueError):
                continue
            if target == "last":
                usage[target] = int(usage[target] or 0) + value
            else:
                usage[target] = value
    return events, usage


def estimated_request_credits(sport_keys: Iterable[str]) -> int:
    return len(set(sport_keys)) * len(MARKETS)


def budget_block_reason(
    sport_keys: Iterable[str],
    previous_remaining: int | None,
    minimum_remaining: int,
    maximum_run_credits: int,
) -> str | None:
    estimated = estimated_request_credits(sport_keys)
    if estimated > maximum_run_credits:
        return f"estimated run cost {estimated} exceeds limit {maximum_run_credits}"
    if previous_remaining is not None and previous_remaining - estimated < minimum_remaining:
        return (
            f"estimated remaining credits {previous_remaining - estimated} "
            f"would fall below reserve {minimum_remaining}"
        )
    return None


def _previous_remaining(output: Path | None) -> int | None:
    if output is None or not output.exists():
        return None
    try:
        payload = _read_json(output)
        value = payload.get("usage", {}).get("remaining")
        return int(value) if value is not None else None
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return None


def audit(
    matches: list[dict[str, Any]],
    events_by_sport: dict[str, list[dict[str, Any]]],
    league_map: dict[str, str],
    team_aliases: dict[str, list[str]],
    usage: dict[str, int | None] | None = None,
) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for match in matches:
        league = str(match.get("league") or "")
        sport_key = league_map.get(league)
        if not sport_key:
            decision = MatchDecision("unmapped_league", None, 0, None, "league has no provider sport key")
        else:
            decision = decide_event(match, events_by_sport.get(sport_key, []), team_aliases)
        coverage = market_coverage(decision.event)
        rows.append(
            {
                "matchId": str(match.get("id") or match.get("matchId") or ""),
                "number": str(match.get("number") or ""),
                "league": league,
                "home": str(match.get("home") or ""),
                "away": str(match.get("away") or ""),
                "kickoff": match.get("kickoff"),
                "sportKey": sport_key,
                "status": decision.status,
                "score": decision.score,
                "kickoffDeltaMinutes": decision.kickoff_delta_minutes,
                "providerEventId": decision.event.get("id") if decision.event else None,
                "providerHome": decision.event.get("home_team") if decision.event else None,
                "providerAway": decision.event.get("away_team") if decision.event else None,
                "coverage": coverage,
                "reason": decision.reason,
            }
        )

    matched = [row for row in rows if row["status"] == "matched"]
    complete = [row for row in matched if row["coverage"]["complete"]]
    return {
        "checkedAt": datetime.now(SHANGHAI).isoformat(),
        "matchingEngine": "rapidfuzz" if _rapid_ratio is not None else "difflib-fallback",
        "summary": {
            "officialMatches": len(rows),
            "matched": len(matched),
            "review": sum(row["status"] == "review" for row in rows),
            "unmatched": sum(row["status"] == "unmatched" for row in rows),
            "unmappedLeagues": sum(row["status"] == "unmapped_league" for row in rows),
            "allMarketsComplete": len(complete),
            "strictMatchRate": round(len(matched) / len(rows), 4) if rows else 0,
            "completeCoverageRate": round(len(complete) / len(rows), 4) if rows else 0,
        },
        "usage": usage or {"last": 0, "used": None, "remaining": None},
        "items": rows,
    }


def _parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://api.cclloo.com")
    parser.add_argument("--provider-map", type=Path, default=root / "provider_map.json")
    parser.add_argument("--matches-file", type=Path)
    parser.add_argument("--provider-fixtures", type=Path)
    parser.add_argument("--api-key-file", type=Path)
    parser.add_argument("--region", default="eu")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--minimum-remaining", type=int, default=100)
    parser.add_argument("--maximum-run-credits", type=int, default=12)
    return parser


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")
    args = _parser().parse_args()
    mapping = _read_json(args.provider_map)
    league_map = {str(key): str(value) for key, value in mapping.get("leagues", {}).items()}
    team_aliases = {
        str(key): [str(value) for value in values]
        for key, values in mapping.get("teams", {}).items()
        if isinstance(values, list)
    }
    matches = _load_matches(args.base_url, args.matches_file)
    active_sports = {
        league_map[str(match.get("league") or "")]
        for match in matches
        if str(match.get("league") or "") in league_map
    }

    if args.provider_fixtures:
        payload = _read_json(args.provider_fixtures)
        events_by_sport = {
            str(key): [item for item in values if isinstance(item, dict)]
            for key, values in payload.items()
            if isinstance(values, list)
        }
        usage = {"last": 0, "used": None, "remaining": None}
    else:
        blocked = budget_block_reason(
            active_sports,
            _previous_remaining(args.output),
            args.minimum_remaining,
            args.maximum_run_credits,
        )
        if blocked:
            print(f"Odds sync skipped: {blocked}", file=sys.stderr)
            return 3
        api_key = os.environ.get("THE_ODDS_API_KEY", "").strip()
        if args.api_key_file:
            api_key = args.api_key_file.read_text(encoding="utf-8").strip()
        if not api_key:
            print(
                "Missing THE_ODDS_API_KEY. Set it in the process environment or use --api-key-file.",
                file=sys.stderr,
            )
            return 2
        events_by_sport, usage = _load_provider_events(active_sports, api_key, args.region)

    result = audit(matches, events_by_sport, league_map, team_aliases, usage)
    rendered = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        _write_json_atomic(args.output, result)
    if args.snapshot:
        previous = None
        if args.snapshot.exists():
            try:
                previous = _read_json(args.snapshot)
            except (OSError, json.JSONDecodeError):
                previous = None
        snapshot = build_public_snapshot(result, events_by_sport)
        _write_json_atomic(args.snapshot, merge_opening_prices(snapshot, previous))
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
