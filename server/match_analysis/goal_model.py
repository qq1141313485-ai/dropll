"""Transparent goal-proxy model used when event-level xG is unavailable.

This is deliberately named a proxy: recent goals are not xG.  The output is
useful as a reproducible baseline, not as a calibrated production forecast.
"""

from __future__ import annotations

import math
from typing import Any


def _summary(side: dict[str, Any]) -> dict[str, float]:
    value = side.get("summary") if isinstance(side, dict) else {}
    value = value if isinstance(value, dict) else {}
    matches = float(value.get("matches") or 0)
    gf = float(value.get("goalsFor") or 0)
    ga = float(value.get("goalsAgainst") or 0)
    return {"matches": matches, "gf": gf, "ga": ga}


def _poisson(k: int, lam: float) -> float:
    return math.exp(-lam) * lam**k / math.factorial(k)


def build_goal_proxy(recent: dict[str, Any], head_to_head: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return lambdas and P(total goals in {3, 4}) from recent goal rates."""
    home = _summary(recent.get("home", {}))
    away = _summary(recent.get("away", {}))
    if not home["matches"] or not away["matches"]:
        return {
            "available": False,
            "source": "internal",
            "type": "goals_proxy",
            "reason": "recent summaries unavailable",
        }

    # Attack is paired with the opponent's recent defensive concession rate.
    home_lambda = 0.55 * home["gf"] / home["matches"] + 0.45 * away["ga"] / away["matches"]
    away_lambda = 0.55 * away["gf"] / away["matches"] + 0.45 * home["ga"] / home["matches"]
    home_lambda = max(0.05, min(5.0, home_lambda * 1.05))
    away_lambda = max(0.05, min(5.0, away_lambda))
    total_lambda = home_lambda + away_lambda
    p34 = sum(_poisson(k, total_lambda) for k in (3, 4))
    h2h = (head_to_head or {}).get("summary", {})
    return {
        "available": True,
        "source": "internal",
        "type": "goals_proxy",
        "isOfficialXg": False,
        "homeLambda": round(home_lambda, 4),
        "awayLambda": round(away_lambda, 4),
        "totalLambda": round(total_lambda, 4),
        "pTotal3Or4": round(p34, 6),
        "inputs": {
            "homeRecentGoalsFor": home["gf"],
            "homeRecentGoalsAgainst": home["ga"],
            "awayRecentGoalsFor": away["gf"],
            "awayRecentGoalsAgainst": away["ga"],
            "recentMatchesPerSide": min(home["matches"], away["matches"]),
            "headToHeadMatches": h2h.get("matches", 0),
        },
        "limitations": [
            "recent goals are a proxy, not event-level xG",
            "no player-level availability weighting",
            "parameters are not yet backtest-calibrated",
        ],
    }
