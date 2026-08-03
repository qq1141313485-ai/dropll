from __future__ import annotations

import json
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


MATCH_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
SHANGHAI = timezone(timedelta(hours=8))
DEFAULT_SNAPSHOT_PATH = Path(
    os.environ.get(
        "CAIMASTER_MARKET_ODDS_SNAPSHOT",
        "/opt/caimaster-api/market_odds/work/latest.json",
    )
)


class MarketOddsService:
    def __init__(self, snapshot_path: Path = DEFAULT_SNAPSHOT_PATH) -> None:
        self.snapshot_path = snapshot_path

    def get(self, match_id: str) -> dict[str, Any]:
        if not MATCH_ID_RE.fullmatch(match_id):
            raise ValueError("invalid match id")
        try:
            payload = json.loads(self.snapshot_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return {"matchId": match_id, "available": False, "bookmakers": []}
        items = payload.get("items", {}) if isinstance(payload, dict) else {}
        item = items.get(match_id) if isinstance(items, dict) else None
        if not isinstance(item, dict):
            return {
                "matchId": match_id,
                "available": False,
                "provider": payload.get("provider") if isinstance(payload, dict) else None,
                "generatedAt": payload.get("generatedAt") if isinstance(payload, dict) else None,
                "bookmakers": [],
            }
        generated_at = payload.get("generatedAt")
        stale = False
        if isinstance(generated_at, str):
            try:
                parsed = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=SHANGHAI)
                stale = datetime.now(SHANGHAI) - parsed.astimezone(SHANGHAI) > timedelta(hours=12)
            except ValueError:
                stale = True
        return {
            **item,
            "available": bool(item.get("bookmakers")),
            "provider": payload.get("provider"),
            "generatedAt": generated_at,
            "stale": stale,
        }


def install_market_odds_routes(app: Any, service: MarketOddsService | None = None) -> None:
    from fastapi import HTTPException

    odds_service = service or MarketOddsService()

    @app.get("/v1/matches/{match_id}/market-odds")
    def market_odds(match_id: str) -> dict[str, Any]:
        try:
            return odds_service.get(match_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="invalid match id") from exc
