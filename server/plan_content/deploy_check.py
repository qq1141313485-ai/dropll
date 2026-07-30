from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from plan_source_common import PlanNameRules, SourceError


PLAN_DB_PATH = Path(os.environ.get("CAIMASTER_PLAN_DB", "/opt/caimaster-api/plans.db"))
PLAN_MEDIA_DIR = Path(
    os.environ.get("CAIMASTER_PLAN_MEDIA", "/opt/caimaster-api/plan-media")
)
PLAN_ADMIN_HTML = Path(
    os.environ.get(
        "CAIMASTER_PLAN_ADMIN_HTML",
        "/opt/caimaster-api/plan_admin.html",
    )
)
API_APP_PATH = Path(os.environ.get("CAIMASTER_API_APP", "/opt/caimaster-api/app.py"))
PLAN_SOURCE_MAP = Path(
    os.environ.get(
        "CAIMASTER_PLAN_SOURCE_MAP",
        "/opt/caimaster-api/plan_source_map.json",
    )
)
SERVICE_PATH = Path("/etc/systemd/system/caimaster-plan-source-sync.service")
TIMER_PATH = Path("/etc/systemd/system/caimaster-plan-source-sync.timer")


@dataclass
class Check:
    level: str
    name: str
    detail: str


def _module_available(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def _check_dependencies(checks: list[Check]) -> None:
    for module_name in ("fastapi", "PIL", "multipart"):
        if _module_available(module_name):
            checks.append(Check("ok", f"python module {module_name}", "available"))
        else:
            checks.append(Check("error", f"python module {module_name}", "missing"))


def _check_environment(checks: list[Check]) -> None:
    required = ("CAIMASTER_PLAN_ADMIN_TOKEN",)
    for key in required:
        value = os.environ.get(key, "").strip()
        if value.startswith("replace-with-"):
            checks.append(Check("error", key, "still set to example placeholder"))
        elif value:
            checks.append(Check("ok", key, "configured"))
        else:
            checks.append(Check("error", key, "missing"))
    if os.environ.get("CAIMASTER_PLAN_SOURCE_ENABLED") == "1":
        checks.append(Check("ok", "CAIMASTER_PLAN_SOURCE_ENABLED", "enabled"))
    else:
        checks.append(Check("warn", "CAIMASTER_PLAN_SOURCE_ENABLED", "not enabled"))


def _check_source_rules(checks: list[Check]) -> None:
    if not PLAN_SOURCE_MAP.exists():
        checks.append(Check("warn", "plan source map", f"missing: {PLAN_SOURCE_MAP}"))
        return
    try:
        raw = json.loads(PLAN_SOURCE_MAP.read_text(encoding="utf-8"))
        rules = PlanNameRules.from_mapping(raw)
    except (OSError, json.JSONDecodeError, SourceError) as exc:
        checks.append(Check("error", "plan source map", f"invalid: {exc}"))
        return
    checks.append(
        Check(
            "ok",
            "plan source map",
            (
                f"aliases={len(rules.aliases)} "
                f"allowed={len(rules.allowed_names)} "
                f"ignored={len(rules.ignored_names)} "
                f"auto_create={rules.allow_auto_create}"
            ),
        )
    )


def _check_paths(checks: list[Check]) -> None:
    if not API_APP_PATH.is_file():
        checks.append(Check("error", "api app.py", f"missing: {API_APP_PATH}"))
    else:
        try:
            app_source = API_APP_PATH.read_text(encoding="utf-8")
        except OSError as exc:
            checks.append(Check("error", "api app.py", f"cannot read: {exc}"))
        else:
            if "install_plan_routes" in app_source:
                checks.append(Check("ok", "api app.py", "plan routes installed"))
            else:
                checks.append(
                    Check(
                        "error",
                        "api app.py",
                        "missing install_plan_routes(app)",
                    )
                )

    if PLAN_ADMIN_HTML.is_file():
        checks.append(Check("ok", "admin html", str(PLAN_ADMIN_HTML)))
    else:
        checks.append(Check("error", "admin html", f"missing: {PLAN_ADMIN_HTML}"))

    if PLAN_MEDIA_DIR.is_dir():
        writable = os.access(PLAN_MEDIA_DIR, os.W_OK)
        level = "ok" if writable else "error"
        detail = f"{PLAN_MEDIA_DIR} writable={writable}"
        checks.append(Check(level, "media directory", detail))
    else:
        parent_writable = os.access(PLAN_MEDIA_DIR.parent, os.W_OK)
        level = "warn" if parent_writable else "error"
        checks.append(
            Check(
                level,
                "media directory",
                f"missing: {PLAN_MEDIA_DIR}; parent_writable={parent_writable}",
            )
        )

    for path, name in ((SERVICE_PATH, "sync service"), (TIMER_PATH, "sync timer")):
        if path.is_file():
            checks.append(Check("ok", name, str(path)))
        else:
            checks.append(Check("warn", name, f"missing: {path}"))


def _db_tables(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table'"
    ).fetchall()
    return {str(row[0]) for row in rows}


def _latest_sync_run(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        """
        SELECT started_at, finished_at, status, candidates, counts_json, error
        FROM plan_sync_runs
        ORDER BY started_at DESC, id DESC
        LIMIT 1
        """
    ).fetchone()
    if row is None:
        return "none"
    started_at, finished_at, status, candidates, counts_json, error = row
    try:
        counts = json.loads(counts_json or "{}")
    except json.JSONDecodeError:
        counts = {}
    failed = counts.get("failed", 0) if isinstance(counts, dict) else 0
    pending = counts.get("pending_name", 0) if isinstance(counts, dict) else 0
    return (
        f"status={status} started_at={started_at} finished_at={finished_at} "
        f"candidates={candidates} failed={failed} pending={pending} "
        f"error={error or ''}"
    )


def _status_count(conn: sqlite3.Connection, statuses: tuple[str, ...]) -> int:
    placeholders = ",".join("?" for _ in statuses)
    return int(
        conn.execute(
            f"""
            SELECT COUNT(*) FROM plan_sync_articles
            WHERE status IN ({placeholders})
            """,
            statuses,
        ).fetchone()[0]
    )


def _check_sync_backlog(checks: list[Check], conn: sqlite3.Connection) -> None:
    pending = _status_count(conn, ("pending_name", "name_configured"))
    failed = _status_count(conn, ("failed",))
    retry_queued = _status_count(conn, ("retry_queued",))
    checks.append(
        Check(
            "warn" if pending else "ok",
            "pending names",
            str(pending),
        )
    )
    checks.append(
        Check(
            "warn" if failed else "ok",
            "failed articles",
            str(failed),
        )
    )
    checks.append(Check("ok", "retry queued", str(retry_queued)))
    latest = _latest_sync_run(conn)
    checks.append(
        Check(
            "error" if latest.startswith("status=failed") else "ok",
            "latest sync run",
            latest,
        )
    )


def _check_database(checks: list[Check]) -> None:
    if not PLAN_DB_PATH.exists():
        parent_writable = os.access(PLAN_DB_PATH.parent, os.W_OK)
        checks.append(
            Check(
                "warn" if parent_writable else "error",
                "plan database",
                f"missing: {PLAN_DB_PATH}; parent_writable={parent_writable}",
            )
        )
        return
    try:
        with sqlite3.connect(PLAN_DB_PATH) as conn:
            tables = _db_tables(conn)
            required = {"plans", "plan_updates", "plan_images"}
            sync_tables = {"plan_sync_articles", "plan_sync_images", "plan_sync_runs"}
            missing_required = sorted(required - tables)
            missing_sync = sorted(sync_tables - tables)
            if missing_required:
                checks.append(
                    Check("error", "plan database", f"missing tables: {missing_required}")
                )
            else:
                checks.append(
                    Check("ok", "plan database", f"core tables present: {PLAN_DB_PATH}")
                )
            if missing_sync:
                checks.append(Check("warn", "sync database", f"missing tables: {missing_sync}"))
                return
            checks.append(Check("ok", "sync database", "sync tables present"))
            _check_sync_backlog(checks, conn)
    except sqlite3.Error as exc:
        checks.append(Check("error", "plan database", f"cannot read: {exc}"))


def collect_checks() -> list[Check]:
    checks: list[Check] = []
    _check_dependencies(checks)
    _check_environment(checks)
    _check_source_rules(checks)
    _check_paths(checks)
    _check_database(checks)
    return checks


def _as_json(checks: list[Check]) -> str:
    payload: dict[str, Any] = {
        "ok": not any(check.level == "error" for check in checks),
        "checks": [check.__dict__ for check in checks],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2)


def main() -> int:
    checks = collect_checks()

    if "--json" in sys.argv:
        print(_as_json(checks))
    else:
        for check in checks:
            print(f"[{check.level.upper()}] {check.name}: {check.detail}")

    return 1 if any(check.level == "error" for check in checks) else 0


if __name__ == "__main__":
    sys.exit(main())
