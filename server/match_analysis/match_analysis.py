from __future__ import annotations

import json
import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

try:  # Supports both package imports and the existing direct-module tests.
    from .goal_model import build_goal_proxy
except ImportError:  # pragma: no cover - exercised by direct deployment imports.
    from goal_model import build_goal_proxy


WEB_API = "https://webapi.sporttery.cn/gateway/uniform/football"
MATCH_ID_RE = re.compile(r"^[0-9]{1,20}$")
REQUEST_TIMEOUT = 10
CACHE_TTL_SECONDS = 6 * 60 * 60
STALE_TTL_SECONDS = 7 * 24 * 60 * 60

JsonMap = dict[str, Any]
FetchJson = Callable[[str, dict[str, Any]], JsonMap]


class AnalysisSourceError(RuntimeError):
    pass


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _as_map(value: Any) -> JsonMap:
    return dict(value) if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return list(value) if isinstance(value, list) else []


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _first_text(source: JsonMap, keys: tuple[str, ...]) -> str:
    for key in keys:
        value = _text(source.get(key))
        if value:
            return value
    return ""


def _first_value(source: JsonMap, keys: tuple[str, ...]) -> Any:
    for key in keys:
        if key in source and source[key] not in (None, ""):
            return source[key]
    return None


def _int_or_value(value: Any) -> Any:
    if isinstance(value, bool) or value is None:
        return value
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return value


def _response_value(payload: JsonMap) -> JsonMap:
    if payload.get("success") is False:
        return {}
    return _as_map(payload.get("value"))


def _request_json(path: str, params: dict[str, Any]) -> JsonMap:
    query = urllib.parse.urlencode(params)
    url = f"{WEB_API}/{path}?{query}"
    match_id = _text(params.get("sportteryMatchId") or params.get("gmMatchId"))
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json, text/plain, */*",
            "Referer": (
                "https://www.sporttery.cn/jc/zqdz/index.html"
                f"?showType=2&mid={urllib.parse.quote(match_id)}"
            ),
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0 Safari/537.36"
            ),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            if response.status != 200:
                raise AnalysisSourceError(f"source returned HTTP {response.status}")
            decoded = json.loads(response.read().decode("utf-8"))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        json.JSONDecodeError,
    ) as exc:
        raise AnalysisSourceError("source request failed") from exc
    if not isinstance(decoded, dict):
        raise AnalysisSourceError("source returned an invalid payload")
    return decoded


def _deep_find_map(source: Any, required_key: str) -> JsonMap:
    if isinstance(source, dict):
        if required_key in source:
            return dict(source)
        for value in source.values():
            found = _deep_find_map(value, required_key)
            if found:
                return found
    elif isinstance(source, list):
        for value in source:
            found = _deep_find_map(value, required_key)
            if found:
                return found
    return {}


def _team_names(head_payload: JsonMap, *fallback_payloads: JsonMap) -> tuple[str, str]:
    base_candidates = [_response_value(head_payload)]
    base_candidates.extend(_response_value(payload) for payload in fallback_payloads)
    candidates = list(base_candidates)
    candidates.extend(
        _deep_find_map(candidate, "homeTeamShortName")
        for candidate in base_candidates
    )
    for candidate in candidates:
        home = _first_text(
            candidate,
            ("homeTeamShortName", "homeTeamName", "homeShortName", "homeName"),
        )
        away = _first_text(
            candidate,
            ("awayTeamShortName", "awayTeamName", "awayShortName", "awayName"),
        )
        if home or away:
            return home, away
    return "", ""


def _score_parts(score: str) -> tuple[int, int] | None:
    match = re.search(r"(\d+)\s*[:\-]\s*(\d+)", score)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def _normalize_match(row: Any, perspective_team: str = "") -> JsonMap:
    item = _as_map(row)
    home = _first_text(
        item, ("homeTeamShortName", "homeTeamName", "homeShortName", "homeName")
    )
    away = _first_text(
        item, ("awayTeamShortName", "awayTeamName", "awayShortName", "awayName")
    )
    full_score = _first_text(
        item, ("fullCourtGoal", "fullScore", "sectionsNo999", "score")
    )
    half_score = _first_text(
        item, ("halfCourtGoal", "halfScore", "sectionsNo1", "halfTimeScore")
    )
    result = ""
    score = _score_parts(full_score)
    if perspective_team and score and (perspective_team == home or perspective_team == away):
        perspective_home = perspective_team == home
        own, opponent = score if perspective_home else (score[1], score[0])
        result = "胜" if own > opponent else ("负" if own < opponent else "平")
    if not result:
        winning_team = _first_text(item, ("winningTeam", "winner")).lower()
        if winning_team in ("home", "h"):
            result = "胜" if not perspective_team or perspective_team == home else "负"
        elif winning_team in ("away", "a"):
            result = "负" if not perspective_team or perspective_team == home else "胜"
        elif winning_team in ("draw", "d"):
            result = "平"
    return {
        "id": _first_text(item, ("sportteryMatchId", "matchId", "gmMatchId", "id")),
        "date": _first_text(item, ("matchDate", "matchTime", "startTime")),
        "league": _first_text(
            item, ("leagueShortName", "tournamentShortName", "leagueName")
        ),
        "home": home,
        "away": away,
        "fullScore": full_score,
        "halfScore": half_score,
        "result": result,
    }


def _valid_matches(values: Any, team: str = "", limit: int = 10) -> list[JsonMap]:
    result = []
    for value in _as_list(values):
        normalized = _normalize_match(value, team)
        if normalized["home"] or normalized["away"]:
            result.append(normalized)
    result.sort(key=lambda item: _match_date_key(_text(item.get("date"))), reverse=True)
    return result[:limit]


def _match_date_key(value: str) -> tuple[int, int, int, int, int, int]:
    parts = [int(part) for part in re.findall(r"\d+", value)[:6]]
    if len(parts) < 3:
        return (0, 0, 0, 0, 0, 0)
    parts.extend([0] * (6 - len(parts)))
    return tuple(parts)  # type: ignore[return-value]


def _summary(matches: list[JsonMap]) -> JsonMap:
    wins = sum(1 for item in matches if item.get("result") == "胜")
    draws = sum(1 for item in matches if item.get("result") == "平")
    losses = sum(1 for item in matches if item.get("result") == "负")
    goals_for = 0
    goals_against = 0
    for item in matches:
        score = _score_parts(_text(item.get("fullScore")))
        if not score:
            continue
        if item.get("result") == "":
            continue
        home_team = _text(item.get("home"))
        perspective_is_home = _text(item.get("_perspective")) == home_team
        own, opponent = score if perspective_is_home else (score[1], score[0])
        goals_for += own
        goals_against += opponent
    return {
        "matches": len(matches),
        "wins": wins,
        "draws": draws,
        "losses": losses,
        "goalsFor": goals_for,
        "goalsAgainst": goals_against,
    }


def _head_to_head(payload: JsonMap, home_team: str) -> JsonMap:
    value = _response_value(payload)
    rows = _valid_matches(value.get("matchList"), home_team)
    for row in rows:
        row["_perspective"] = home_team
    summary = _summary(rows)
    for row in rows:
        row.pop("_perspective", None)
    return {"summary": summary, "matches": rows}


def _standing_row(source: Any) -> JsonMap:
    row = _as_map(source)
    return {
        "team": _first_text(row, ("teamShortName", "teamName")),
        "played": _int_or_value(
            _first_value(row, ("totalLegCnt", "matchCnt", "played"))
        ),
        "wins": _int_or_value(
            _first_value(row, ("winGoalMatchCnt", "winMatchCnt", "wins"))
        ),
        "draws": _int_or_value(
            _first_value(row, ("drawMatchCnt", "draws"))
        ),
        "losses": _int_or_value(
            _first_value(row, ("lossGoalMatchCnt", "lossMatchCnt", "losses"))
        ),
        "goalsFor": _int_or_value(
            _first_value(row, ("goalCnt", "goalsFor", "scoreGoalCnt"))
        ),
        "goalsAgainst": _int_or_value(
            _first_value(row, ("lossGoalCnt", "goalsAgainst", "lostGoalCnt"))
        ),
        "goalDifference": _int_or_value(
            _first_value(row, ("goalDifference", "goalDiff", "netGoalCnt"))
        ),
        "points": _int_or_value(_first_value(row, ("points", "score"))),
        "ranking": _int_or_value(_first_value(row, ("ranking", "rank"))),
        "winRate": _first_text(row, ("winRate", "winningRate")),
    }


def _standings(payload: JsonMap) -> JsonMap:
    value = _response_value(payload)

    def team_rows(key: str) -> JsonMap:
        table = _as_map(value.get(key))
        return {
            "total": _standing_row(table.get("total")),
            "home": _standing_row(table.get("home")),
            "away": _standing_row(table.get("away")),
        }

    return {
        "league": _first_text(value, ("leagueShortName", "leagueName")),
        "season": _first_text(value, ("seasonName", "season")),
        "home": team_rows("homeTables"),
        "away": team_rows("awayTables"),
    }


def _player(source: Any) -> JsonMap:
    row = _as_map(source)
    return {
        "id": _first_text(row, ("personId", "playerId")),
        "name": _first_text(row, ("personName", "playerName")),
        "number": _first_text(row, ("uniformNo", "shirtNumber")),
        "position": _first_text(
            row, ("playerPositionDesc", "positionDesc", "position")
        ),
        "appearances": _int_or_value(row.get("appearanceCnt")),
        "starts": _int_or_value(row.get("startedMatchCnt")),
        "substitutes": _int_or_value(row.get("substituteMatchCnt")),
        "goals": _int_or_value(row.get("goalCnt")),
        "assists": _int_or_value(row.get("assistCnt")),
        "injured": _int_or_value(row.get("injuryFlag")) == 1,
        "suspended": _int_or_value(row.get("suspensionFlag")) == 1,
    }


def _team_player_groups(payload: JsonMap, list_key: str) -> JsonMap:
    value = _response_value(payload)

    def side(key: str) -> JsonMap:
        team = _as_map(value.get(key))
        players = [
            _player(item)
            for item in _as_list(team.get(list_key))
            if _first_text(_as_map(item), ("personName", "playerName"))
        ]
        return {
            "team": _first_text(team, ("teamShortName", "teamName")),
            "players": players,
        }

    return {"home": side("home"), "away": side("away")}


def _future_matches(payload: JsonMap) -> JsonMap:
    value = _response_value(payload)

    def side(key: str) -> JsonMap:
        team = _as_map(value.get(key))
        matches = []
        for item in _as_list(team.get("matchList")):
            row = _as_map(item)
            matches.append(
                {
                    "id": _first_text(row, ("matchId", "sportteryMatchId")),
                    "date": _first_text(row, ("matchDateTime", "matchDate")),
                    "league": _first_text(
                        row, ("tournamentShortName", "leagueShortName")
                    ),
                    "home": _first_text(
                        row, ("homeTeamShortName", "homeTeamName")
                    ),
                    "away": _first_text(
                        row, ("awayTeamShortName", "awayTeamName")
                    ),
                }
            )
        return {
            "team": _first_text(team, ("teamShortName", "teamName")),
            "matches": matches[:4],
        }

    return {"home": side("home"), "away": side("away")}


def _find_match_lists(source: Any) -> list[list[Any]]:
    results: list[list[Any]] = []
    if isinstance(source, list):
        if any(
            isinstance(item, dict)
            and ("homeTeamShortName" in item or "fullCourtGoal" in item)
            for item in source
        ):
            results.append(source)
        for item in source:
            results.extend(_find_match_lists(item))
    elif isinstance(source, dict):
        for key in ("matchList", "matches", "resultList"):
            found = _as_list(source.get(key))
            if found:
                results.append(found)
        for value in source.values():
            results.extend(_find_match_lists(value))
    return results


def _recent_side(value: JsonMap, side: str, team: str) -> JsonMap:
    direct = {}
    for key in (
        side,
        f"{side}Team",
        f"{side}Result",
        f"{side}Match",
        f"{side}TeamResult",
    ):
        direct = _as_map(value.get(key))
        if direct:
            break
    candidate_lists = (
        value.get(f"{side}MatchList"),
        direct.get("matchList"),
        direct.get("matches"),
    )
    rows: list[JsonMap] = []
    for candidate in candidate_lists:
        rows = _valid_matches(candidate, team)
        if rows:
            break
    if not rows:
        candidates = _find_match_lists(direct or value)
        if team:
            candidates.sort(
                key=lambda items: sum(
                    1
                    for item in items
                    if team
                    in (
                        _first_text(
                            _as_map(item),
                            ("homeTeamShortName", "homeTeamName", "homeName"),
                        ),
                        _first_text(
                            _as_map(item),
                            ("awayTeamShortName", "awayTeamName", "awayName"),
                        ),
                    )
                ),
                reverse=True,
            )
        if candidates:
            rows = _valid_matches(candidates[0], team)
    for row in rows:
        row["_perspective"] = team
    summary = _summary(rows)
    for row in rows:
        row.pop("_perspective", None)
    return {"team": team, "summary": summary, "matches": rows}


def _recent(payload: JsonMap, home_team: str, away_team: str) -> JsonMap:
    value = _response_value(payload)
    return {
        "home": _recent_side(value, "home", home_team),
        "away": _recent_side(value, "away", away_team),
    }


def normalize_analysis(match_id: str, payloads: dict[str, JsonMap]) -> JsonMap:
    head = payloads.get("head", {})
    history = payloads.get("history", {})
    recent = payloads.get("recent", {})
    home_team, away_team = _team_names(head, history, recent)
    data = {
        "matchId": match_id,
        "source": "sporttery",
        "teams": {"home": home_team, "away": away_team},
        "headToHead": _head_to_head(history, home_team),
        "standings": _standings(payloads.get("standings", {})),
        "recent": _recent(recent, home_team, away_team),
        "keyPlayers": _team_player_groups(payloads.get("players", {}), "playerList"),
        "injuries": _team_player_groups(
            payloads.get("injuries", {}), "injuriesAndSuspensionsList"
        ),
        "future": _future_matches(payloads.get("future", {})),
    }
    data["goalModel"] = build_goal_proxy(data["recent"], data["headToHead"])
    data["availability"] = {
        "headToHead": bool(data["headToHead"]["matches"]),
        "standings": bool(
            data["standings"]["home"]["total"].get("team")
            or data["standings"]["away"]["total"].get("team")
        ),
        "recentHome": bool(data["recent"]["home"]["matches"]),
        "recentAway": bool(data["recent"]["away"]["matches"]),
        "keyPlayers": bool(
            data["keyPlayers"]["home"]["players"]
            or data["keyPlayers"]["away"]["players"]
        ),
        "injuries": bool(
            data["injuries"]["home"]["players"]
            or data["injuries"]["away"]["players"]
        ),
        "futureHome": bool(data["future"]["home"]["matches"]),
        "futureAway": bool(data["future"]["away"]["matches"]),
    }
    return data


def collect_analysis(match_id: str, fetch_json: FetchJson = _request_json) -> JsonMap:
    if not MATCH_ID_RE.fullmatch(match_id):
        raise ValueError("invalid match id")
    requests = {
        "head": (
            "getMatchHeadV1.qry",
            {"source": "web", "sportteryMatchId": match_id},
        ),
        "history": (
            "getResultHistoryV1.qry",
            {
                "sportteryMatchId": match_id,
                "termLimits": 10,
                "tournamentFlag": 0,
                "homeAwayFlag": 0,
            },
        ),
        "standings": ("getMatchTablesV2.qry", {"gmMatchId": match_id}),
        "recent": (
            "getMatchResultV1.qry",
            {
                "sportteryMatchId": match_id,
                "termLimits": 10,
                "tournamentFlag": 0,
                "homeAwayFlag": 0,
            },
        ),
        "players": (
            "getMatchPlayerV1.qry",
            {"sportteryMatchId": match_id, "termLimits": 3},
        ),
        "injuries": (
            "getInjurySuspensionV1.qry",
            {"sportteryMatchId": match_id},
        ),
        "future": (
            "getFutureMatchesV1.qry",
            {"sportteryMatchId": match_id, "termLimits": 4},
        ),
    }
    payloads: dict[str, JsonMap] = {}
    with ThreadPoolExecutor(max_workers=len(requests)) as executor:
        futures = {
            executor.submit(fetch_json, path, params): name
            for name, (path, params) in requests.items()
        }
        for future in as_completed(futures):
            name = futures[future]
            try:
                payloads[name] = future.result()
            except AnalysisSourceError:
                payloads[name] = {}
    if not any(_response_value(payload) for payload in payloads.values()):
        raise AnalysisSourceError("all match analysis sources failed")
    result = normalize_analysis(match_id, payloads)
    result["fetchedAt"] = _iso(_utc_now())
    result["stale"] = False
    return result


class MatchAnalysisService:
    def __init__(
        self,
        cache_dir: str | Path | None = None,
        fetch_json: FetchJson = _request_json,
    ) -> None:
        default_cache = os.environ.get(
            "CAIMASTER_MATCH_ANALYSIS_CACHE_DIR",
            "/opt/caimaster-api/cache/match-analysis",
        )
        self.cache_dir = Path(cache_dir or default_cache)
        self.fetch_json = fetch_json
        self._lock = threading.Lock()

    def _cache_path(self, match_id: str) -> Path:
        return self.cache_dir / f"{match_id}.json"

    def _read_cache(self, match_id: str) -> tuple[JsonMap, float] | None:
        path = self._cache_path(match_id)
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            age = max(0.0, _utc_now().timestamp() - path.stat().st_mtime)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return None
        return (payload, age) if isinstance(payload, dict) else None

    def _write_cache(self, match_id: str, payload: JsonMap) -> None:
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        path = self._cache_path(match_id)
        temp = path.with_suffix(".tmp")
        temp.write_text(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        temp.replace(path)

    def get(self, match_id: str) -> JsonMap:
        if not MATCH_ID_RE.fullmatch(match_id):
            raise ValueError("invalid match id")
        cached = self._read_cache(match_id)
        if cached and cached[1] <= CACHE_TTL_SECONDS:
            return cached[0]
        with self._lock:
            cached = self._read_cache(match_id)
            if cached and cached[1] <= CACHE_TTL_SECONDS:
                return cached[0]
            try:
                payload = collect_analysis(match_id, self.fetch_json)
                self._write_cache(match_id, payload)
                return payload
            except (AnalysisSourceError, OSError):
                if cached and cached[1] <= STALE_TTL_SECONDS:
                    stale = dict(cached[0])
                    stale["stale"] = True
                    return stale
                raise


def install_match_analysis_routes(app: Any, service: MatchAnalysisService | None = None) -> None:
    from fastapi import HTTPException

    match_service = service or MatchAnalysisService()

    @app.get("/v1/matches/{match_id}/analysis")
    def match_analysis(match_id: str) -> JsonMap:
        try:
            return match_service.get(match_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="invalid match id") from exc
        except AnalysisSourceError as exc:
            raise HTTPException(
                status_code=503, detail="match analysis is temporarily unavailable"
            ) from exc
