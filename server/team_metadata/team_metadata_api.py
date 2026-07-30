"""Read-only API for strictly mapped team metadata and cached badges."""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse


class TeamMetadataStore:
    def __init__(self, cache_dir: Path) -> None:
        self.cache_dir = cache_dir.resolve()
        self.manifest_path = self.cache_dir / "manifest.json"
        self._lock = threading.Lock()
        self._mtime_ns = -1
        self._teams: dict[str, dict[str, Any]] = {}
        self._badges: dict[str, Path] = {}

    def _reload_if_needed(self) -> None:
        try:
            mtime_ns = self.manifest_path.stat().st_mtime_ns
        except FileNotFoundError:
            mtime_ns = -1
        if mtime_ns == self._mtime_ns:
            return
        with self._lock:
            if mtime_ns == self._mtime_ns:
                return
            teams: dict[str, dict[str, Any]] = {}
            badges: dict[str, Path] = {}
            if mtime_ns >= 0:
                payload = json.loads(self.manifest_path.read_text(encoding="utf-8"))
                raw_teams = payload.get("teams")
                if isinstance(raw_teams, dict):
                    for name, value in raw_teams.items():
                        if not isinstance(name, str) or not isinstance(value, dict):
                            continue
                        badge_file = str(value.get("badgeFile") or "")
                        badge_path = (self.cache_dir / badge_file).resolve()
                        if (
                            badge_file.startswith("badges/")
                            and badge_path.parent == self.cache_dir / "badges"
                            and badge_path.is_file()
                        ):
                            teams[name] = value
                            badges[badge_path.name] = badge_path
            self._teams = teams
            self._badges = badges
            self._mtime_ns = mtime_ns

    def find(self, names: list[str], public_base_url: str) -> list[dict[str, Any]]:
        self._reload_if_needed()
        items = []
        for name in names:
            value = self._teams.get(name)
            if value is None:
                continue
            badge_path = self._badges.get(Path(str(value["badgeFile"])).name)
            if badge_path is None:
                continue
            digest = str(value.get("badgeSha256") or "")[:12]
            items.append(
                {
                    "name": name,
                    "sourceTeamId": str(value.get("sourceTeamId") or ""),
                    "sourceName": str(value.get("sourceName") or ""),
                    "league": str(value.get("league") or ""),
                    "country": str(value.get("country") or ""),
                    "badgeUrl": (
                        f"{public_base_url}/media/teams/{badge_path.name}?v={digest}"
                    ),
                }
            )
        return items

    def badge(self, filename: str) -> Path:
        self._reload_if_needed()
        path = self._badges.get(filename)
        if path is None:
            raise HTTPException(status_code=404, detail="Team badge not found")
        return path

    def mapped_team(self, name: str) -> dict[str, Any] | None:
        self._reload_if_needed()
        return self._teams.get(name)


class TeamStandingsService:
    def __init__(self, store: TeamMetadataStore, api_key: str) -> None:
        self.store = store
        self.api_key = api_key
        self._lock = threading.Lock()
        self._cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}

    def _league_table(self, league_id: str) -> list[dict[str, Any]]:
        cached = self._cache.get(league_id)
        now = time.time()
        if cached and now - cached[0] <= 21600:
            return cached[1]
        with self._lock:
            cached = self._cache.get(league_id)
            if cached and now - cached[0] <= 21600:
                return cached[1]
            query = urllib.parse.urlencode({"l": league_id})
            url = (
                f"https://www.thesportsdb.com/api/v1/json/{self.api_key}/"
                f"lookuptable.php?{query}"
            )
            request = urllib.request.Request(
                url,
                headers={"Accept": "application/json", "User-Agent": "caimaster-api/1"},
            )
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.load(response)
            rows = [
                item
                for item in (payload.get("table") or [])
                if isinstance(item, dict)
            ]
            self._cache[league_id] = (now, rows)
            return rows

    @staticmethod
    def _row(source: dict[str, Any], local_name: str) -> dict[str, Any]:
        def number(key: str) -> int:
            try:
                return int(source.get(key) or 0)
            except (TypeError, ValueError):
                return 0

        return {
            "team": local_name,
            "played": number("intPlayed"),
            "wins": number("intWin"),
            "draws": number("intDraw"),
            "losses": number("intLoss"),
            "goalsFor": number("intGoalsFor"),
            "goalsAgainst": number("intGoalsAgainst"),
            "points": number("intPoints"),
            "ranking": number("intRank"),
        }

    def get(self, home: str, away: str) -> dict[str, Any]:
        values: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
        for name in (home, away):
            mapping = self.store.mapped_team(name)
            if not mapping:
                continue
            league_id = str(mapping.get("sourceLeagueId") or "")
            team_id = str(mapping.get("sourceTeamId") or "")
            if not league_id or not team_id:
                continue
            row = next(
                (
                    item
                    for item in self._league_table(league_id)
                    if str(item.get("idTeam") or "") == team_id
                ),
                None,
            )
            if row:
                values[name] = (mapping, row)

        mappings = [value[0] for value in values.values()]
        leagues = {str(value.get("league") or "") for value in mappings}
        seasons = {
            str(row.get("strSeason") or "")
            for _, row in values.values()
            if row.get("strSeason")
        }

        def standing(name: str) -> dict[str, Any]:
            value = values.get(name)
            if not value:
                return {"total": {}, "home": {}, "away": {}}
            return {
                "total": self._row(value[1], name),
                "home": {},
                "away": {},
            }

        return {
            "league": next(iter(leagues)) if len(leagues) == 1 else "国内联赛",
            "season": next(iter(seasons)) if len(seasons) == 1 else "",
            "home": standing(home),
            "away": standing(away),
            "source": "TheSportsDB",
            "cacheSeconds": 21600,
        }


def install_team_metadata_routes(
    app: FastAPI,
    *,
    cache_dir: Path | None = None,
    public_base_url: str | None = None,
) -> None:
    store = TeamMetadataStore(
        cache_dir
        or Path(
            os.environ.get(
                "CAIMASTER_TEAM_METADATA_CACHE",
                "/opt/caimaster-api/team_metadata/cache",
            )
        )
    )
    base_url = (
        public_base_url
        or os.environ.get("CAIMASTER_PUBLIC_BASE_URL", "https://api.cclloo.com")
    ).rstrip("/")
    standings_service = TeamStandingsService(
        store,
        os.environ.get("THESPORTSDB_API_KEY", "123"),
    )

    @app.get("/v1/teams/metadata")
    def team_metadata(names: str = Query("", max_length=500)) -> dict[str, Any]:
        unique_names = list(
            dict.fromkeys(name.strip() for name in names.split(",") if name.strip())
        )[:10]
        return {"items": store.find(unique_names, base_url)}

    @app.get("/v1/teams/standings")
    def team_standings(
        home: str = Query("", max_length=80),
        away: str = Query("", max_length=80),
    ) -> dict[str, Any]:
        if not home.strip() or not away.strip():
            raise HTTPException(status_code=400, detail="home and away are required")
        try:
            return standings_service.get(home.strip(), away.strip())
        except (OSError, ValueError, json.JSONDecodeError):
            raise HTTPException(
                status_code=503,
                detail="team standings are temporarily unavailable",
            )

    @app.get("/media/teams/{filename}")
    def team_badge(filename: str) -> FileResponse:
        if Path(filename).name != filename:
            raise HTTPException(status_code=404, detail="Team badge not found")
        return FileResponse(
            store.badge(filename),
            headers={"Cache-Control": "public, max-age=2592000, immutable"},
        )
