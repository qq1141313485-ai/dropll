from __future__ import annotations

import importlib.util
import io
import json
import os
import secrets
import sqlite3
import time
import urllib.error
import urllib.request
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi import (
    APIRouter,
    Body,
    Depends,
    FastAPI,
    File,
    Header,
    HTTPException,
    Query,
    Request,
    UploadFile,
)
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageOps, UnidentifiedImageError

from plan_source_common import extract_image_urls


CHINA_TZ = timezone(timedelta(hours=8))
PLAN_DB_PATH = Path(
    os.environ.get("CAIMASTER_PLAN_DB", "/opt/caimaster-api/plans.db")
)
PLAN_MEDIA_DIR = Path(
    os.environ.get("CAIMASTER_PLAN_MEDIA", "/opt/caimaster-api/plan-media")
)
PLAN_ADMIN_HTML = Path(
    os.environ.get(
        "CAIMASTER_PLAN_ADMIN_HTML",
        "/opt/caimaster-api/plan_admin.html",
    )
)
PRIVACY_HTML = Path(
    os.environ.get(
        "CAIMASTER_PRIVACY_HTML",
        "/opt/caimaster-api/privacy.html",
    )
)
SUPPORT_HTML = Path(
    os.environ.get(
        "CAIMASTER_SUPPORT_HTML",
        "/opt/caimaster-api/support.html",
    )
)
API_APP_PATH = Path(os.environ.get("CAIMASTER_API_APP", "/opt/caimaster-api/app.py"))
PLAN_SOURCE_MAP_PATH = Path(
    os.environ.get(
        "CAIMASTER_PLAN_SOURCE_MAP",
        "/opt/caimaster-api/plan_source_map.json",
    )
)
PLAN_ADMIN_TOKEN = os.environ.get("CAIMASTER_PLAN_ADMIN_TOKEN", "").strip()
MAX_UPLOAD_BYTES = 15 * 1024 * 1024
IGNORE_IMAGE_ASSIGNMENT = "__IGNORE__"
PLAN_SOURCE_API_URL = os.environ.get(
    "CAIMASTER_PLAN_SOURCE_API",
    "https://api.tchongxi.com",
).rstrip("/")
PLAN_SOURCE_REQUEST_TIMEOUT = float(
    os.environ.get("CAIMASTER_PLAN_SOURCE_TIMEOUT_SECONDS", "20")
)
PLAN_ARTICLES_PUBLIC_ENABLED = (
    os.environ.get("CAIMASTER_PLAN_ARTICLES_PUBLIC_ENABLED", "0") == "1"
)
PLAN_ARTICLE_MIRROR_SINCE = max(
    0,
    int(os.environ.get("CAIMASTER_PLAN_SOURCE_MIRROR_SINCE", "0")),
)
Image.MAX_IMAGE_PIXELS = 60_000_000
PLAN_SYNC_SERVICE_PATH = Path("/etc/systemd/system/caimaster-plan-source-sync.service")
PLAN_SYNC_TIMER_PATH = Path("/etc/systemd/system/caimaster-plan-source-sync.timer")

public_router = APIRouter(prefix="/v1")
admin_router = APIRouter(prefix="/v1/admin")


def _connect() -> sqlite3.Connection:
    PLAN_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(PLAN_DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    # WAL keeps public reads available while the scheduled source sync writes.
    conn.execute("PRAGMA busy_timeout = 15000")
    return conn


def _now_ts() -> int:
    return int(time.time())


def _iso_time(value: int) -> str:
    return datetime.fromtimestamp(value, CHINA_TZ).isoformat(timespec="minutes")


def _parse_publish_time(value: Any) -> int:
    text = str(value or "").strip()
    if not text:
        return _now_ts()
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="发布时间格式不正确") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=CHINA_TZ)
    return int(parsed.timestamp())


def _clean_name(value: Any, *, maximum: int = 60) -> str:
    return " ".join(str(value or "").strip().split())[:maximum]


def _module_available(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def _health_item(level: str, name: str, detail: str) -> dict[str, str]:
    return {"level": level, "name": name, "detail": detail}


def _clean_rule_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        raise HTTPException(status_code=400, detail="名称规则列表格式不正确")
    return sorted(
        {
            _clean_name(item)
            for item in value
            if _clean_name(item)
        }
    )


def _clean_rule_mapping(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        raise HTTPException(status_code=400, detail="名称映射格式不正确")
    cleaned: dict[str, str] = {}
    for raw_name, standard_name in value.items():
        raw = _clean_name(raw_name)
        standard = _clean_name(standard_name)
        if raw and standard:
            cleaned[raw] = standard
    return dict(sorted(cleaned.items()))


def _clean_image_assignments(value: Any) -> dict[str, list[str]]:
    if not isinstance(value, dict):
        raise HTTPException(status_code=400, detail="图片归属规则格式不正确")
    cleaned: dict[str, list[str]] = {}
    for raw_name, raw_targets in value.items():
        name = _clean_name(raw_name)
        if not name:
            continue
        if not isinstance(raw_targets, list):
            raise HTTPException(
                status_code=400,
                detail=f"“{name}”的图片归属必须是名称列表",
            )
        targets = [
            target
            for item in raw_targets
            if (target := _clean_name(item))
        ]
        if not targets:
            raise HTTPException(
                status_code=400,
                detail=f"“{name}”没有有效的图片归属",
            )
        cleaned[name] = targets
    return dict(sorted(cleaned.items()))


def _empty_source_name_rules() -> dict[str, Any]:
    return {
        "allowAutoCreate": False,
        "allowedNames": [],
        "aliases": {},
        "imageAssignments": {},
        "ignoredNames": [],
        "excludedTitleWords": [],
    }


def _normalize_source_name_rules(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HTTPException(status_code=400, detail="名称规则必须是 JSON 对象")
    structured_keys = {
        "allowAutoCreate",
        "allowedNames",
        "aliases",
        "imageAssignments",
        "ignoredNames",
        "excludedTitleWords",
    }
    if not any(key in value for key in structured_keys):
        aliases = _clean_rule_mapping(value)
        return {
            "allowAutoCreate": True,
            "allowedNames": sorted(set(aliases.values())),
            "aliases": aliases,
            "imageAssignments": {},
            "ignoredNames": [],
            "excludedTitleWords": [],
        }
    words = value.get("excludedTitleWords") or []
    if not isinstance(words, list):
        raise HTTPException(status_code=400, detail="排除词列表格式不正确")
    image_assignments = _clean_image_assignments(
        value.get("imageAssignments") or {}
    )
    allowed_names = set(_clean_rule_list(value.get("allowedNames") or []))
    allowed_names.update(
        name
        for targets in image_assignments.values()
        for name in targets
        if name != IGNORE_IMAGE_ASSIGNMENT
    )
    return {
        "allowAutoCreate": bool(value.get("allowAutoCreate", False)),
        "allowedNames": sorted(allowed_names),
        "aliases": _clean_rule_mapping(value.get("aliases") or {}),
        "imageAssignments": image_assignments,
        "ignoredNames": _clean_rule_list(value.get("ignoredNames") or []),
        "excludedTitleWords": sorted(
            {
                str(word).strip()[:40]
                for word in words
                if str(word).strip()
            }
        ),
    }


def _load_source_name_rules() -> dict[str, Any]:
    if not PLAN_SOURCE_MAP_PATH.exists():
        return _empty_source_name_rules()
    try:
        raw = json.loads(PLAN_SOURCE_MAP_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail="名称规则文件读取失败") from exc
    return _normalize_source_name_rules(raw)


def _save_source_name_rules(rules: dict[str, Any]) -> None:
    PLAN_SOURCE_MAP_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        _normalize_source_name_rules(rules),
        ensure_ascii=False,
        indent=2,
    )
    temporary = PLAN_SOURCE_MAP_PATH.with_name(
        f".{PLAN_SOURCE_MAP_PATH.name}.{uuid4().hex}.tmp"
    )
    try:
        temporary.write_text(f"{payload}\n", encoding="utf-8")
        os.replace(temporary, PLAN_SOURCE_MAP_PATH)
        try:
            os.chmod(PLAN_SOURCE_MAP_PATH, 0o600)
        except OSError:
            pass
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail="名称规则文件写入失败") from exc


def _ensure_plan_sync_article_columns(conn: sqlite3.Connection) -> bool:
    table = conn.execute(
        """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name = 'plan_sync_articles'
        """
    ).fetchone()
    if table is None:
        return False
    existing_columns = {
        row["name"]
        for row in conn.execute("PRAGMA table_info(plan_sync_articles)")
    }
    if "raw_plan_name" not in existing_columns:
        conn.execute(
            "ALTER TABLE plan_sync_articles "
            "ADD COLUMN raw_plan_name TEXT NOT NULL DEFAULT ''"
        )
    if "resolved_plan_name" not in existing_columns:
        conn.execute(
            "ALTER TABLE plan_sync_articles "
            "ADD COLUMN resolved_plan_name TEXT NOT NULL DEFAULT ''"
        )
    if "needs_review" not in existing_columns:
        conn.execute(
            "ALTER TABLE plan_sync_articles "
            "ADD COLUMN needs_review INTEGER NOT NULL DEFAULT 0"
        )
    conn.commit()
    return True


def _ensure_plan_sync_run_table(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS plan_sync_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_name TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            finished_at INTEGER,
            status TEXT NOT NULL,
            candidates INTEGER NOT NULL DEFAULT 0,
            counts_json TEXT NOT NULL DEFAULT '{}',
            error TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_plan_sync_runs_source_time
            ON plan_sync_runs(source_name, started_at DESC);
        """
    )
    conn.commit()


def _slug(value: str) -> str:
    cleaned = "".join(
        character.lower()
        for character in value
        if character.isascii() and (character.isalnum() or character in "-_")
    ).strip("-_")
    return cleaned or uuid4().hex[:12]


def _init_store() -> None:
    PLAN_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    with closing(_connect()) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS plans (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slug TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                uploader_name TEXT NOT NULL DEFAULT '球镜助手',
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS plan_updates (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                plan_id INTEGER NOT NULL,
                title TEXT NOT NULL,
                published_at INTEGER NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(plan_id) REFERENCES plans(id)
            );
            CREATE TABLE IF NOT EXISTS plan_images (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                update_id INTEGER NOT NULL,
                filename TEXT NOT NULL UNIQUE,
                thumbnail_filename TEXT NOT NULL UNIQUE,
                position INTEGER NOT NULL DEFAULT 0,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(update_id) REFERENCES plan_updates(id)
            );
            CREATE TABLE IF NOT EXISTS plan_aliases (
                alias_plan_id INTEGER PRIMARY KEY,
                canonical_plan_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                CHECK(alias_plan_id <> canonical_plan_id),
                FOREIGN KEY(alias_plan_id) REFERENCES plans(id),
                FOREIGN KEY(canonical_plan_id) REFERENCES plans(id)
            );
            CREATE INDEX IF NOT EXISTS idx_plan_updates_plan_time
                ON plan_updates(plan_id, is_active, published_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS idx_plan_images_update_position
                ON plan_images(update_id, is_active, position, id);
            CREATE INDEX IF NOT EXISTS idx_plan_aliases_canonical
                ON plan_aliases(canonical_plan_id, alias_plan_id);
            CREATE TABLE IF NOT EXISTS plan_articles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL,
                title TEXT NOT NULL,
                published_at INTEGER NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id)
            );
            CREATE TABLE IF NOT EXISTS plan_article_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                article_id INTEGER NOT NULL,
                content_sha256 TEXT NOT NULL,
                title TEXT NOT NULL,
                published_at INTEGER NOT NULL,
                captured_at INTEGER NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1,
                FOREIGN KEY(article_id) REFERENCES plan_articles(id),
                UNIQUE(article_id, content_sha256)
            );
            CREATE TABLE IF NOT EXISTS plan_article_images (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                version_id INTEGER NOT NULL,
                filename TEXT NOT NULL UNIQUE,
                thumbnail_filename TEXT NOT NULL UNIQUE,
                source_url TEXT NOT NULL,
                content_sha256 TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(version_id) REFERENCES plan_article_versions(id)
            );
            CREATE INDEX IF NOT EXISTS idx_plan_articles_published
                ON plan_articles(is_active, published_at DESC, id DESC);
            CREATE INDEX IF NOT EXISTS idx_plan_article_versions_latest
                ON plan_article_versions(
                    article_id, is_active, captured_at DESC, id DESC
                );
            CREATE INDEX IF NOT EXISTS idx_plan_article_images_position
                ON plan_article_images(version_id, is_active, position, id);
            """
        )
        conn.commit()
    try:
        os.chmod(PLAN_DB_PATH, 0o600)
    except OSError:
        pass


def _require_admin(
    authorization: str | None = Header(default=None),
) -> None:
    if not PLAN_ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="管理功能尚未配置")
    prefix = "Bearer "
    if not authorization or not authorization.startswith(prefix):
        raise HTTPException(status_code=401, detail="需要管理员密钥")
    token = authorization[len(prefix) :].strip()
    if not secrets.compare_digest(token, PLAN_ADMIN_TOKEN):
        raise HTTPException(status_code=403, detail="管理员密钥无效")


def _canonical_plan_id(conn: sqlite3.Connection, plan_id: int) -> int:
    current = plan_id
    visited: set[int] = set()
    while current not in visited:
        visited.add(current)
        row = conn.execute(
            "SELECT canonical_plan_id FROM plan_aliases WHERE alias_plan_id = ?",
            (current,),
        ).fetchone()
        if row is None:
            return current
        current = int(row["canonical_plan_id"])
    raise RuntimeError("plan alias cycle detected")


def _plan_alias_ids(conn: sqlite3.Connection, canonical_plan_id: int) -> list[str]:
    rows = conn.execute(
        """
        SELECT alias_plan_id FROM plan_aliases
        WHERE canonical_plan_id = ?
        ORDER BY alias_plan_id
        """,
        (canonical_plan_id,),
    ).fetchall()
    return [str(row["alias_plan_id"]) for row in rows]


def _media_url(request: Request, filename: str) -> str:
    return f"{str(request.base_url).rstrip('/')}/media/plans/{filename}"


def _serialize_image(request: Request, row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "imageUrl": _media_url(request, row["filename"]),
        "thumbnailUrl": _media_url(request, row["thumbnail_filename"]),
        "width": row["width"],
        "height": row["height"],
        "position": row["position"],
    }


def _latest_image(
    conn: sqlite3.Connection,
    update_id: int,
) -> sqlite3.Row | None:
    return conn.execute(
        """
        SELECT * FROM plan_images
        WHERE update_id = ? AND is_active = 1
        ORDER BY position, id
        LIMIT 1
        """,
        (update_id,),
    ).fetchone()


def _serialize_plan_summary(
    request: Request,
    conn: sqlite3.Connection,
    row: sqlite3.Row,
) -> dict[str, Any]:
    published_at = int(row["published_at"])
    latest_image = _latest_image(conn, int(row["latest_update_id"]))
    now = datetime.now(CHINA_TZ)
    published = datetime.fromtimestamp(published_at, CHINA_TZ)
    return {
        "id": str(row["id"]),
        "aliasIds": _plan_alias_ids(conn, int(row["id"])),
        "slug": row["slug"],
        "name": row["name"],
        "uploaderName": row["uploader_name"],
        "latestUpdatedAt": _iso_time(published_at),
        "updatedToday": (
            now.year == published.year
            and now.month == published.month
            and now.day == published.day
        ),
        "latestImageCount": int(row["image_count"]),
        "latestThumbnailUrl": (
            _media_url(request, latest_image["thumbnail_filename"])
            if latest_image is not None
            else None
        ),
    }


def _plan_summary_query(*, include_inactive: bool = False) -> str:
    active_clause = "" if include_inactive else "WHERE p.is_active = 1"
    update_active_clause = "" if include_inactive else "WHERE u.is_active = 1"
    image_active_clause = "" if include_inactive else "AND i.is_active = 1"
    image_exists_active_clause = (
        "" if include_inactive else "AND i2.is_active = 1"
    )
    return f"""
        WITH eligible_updates AS (
            SELECT u.id,
                   u.plan_id,
                   u.published_at,
                   ROW_NUMBER() OVER (
                       PARTITION BY u.plan_id
                       ORDER BY u.published_at DESC, u.id DESC
                   ) AS row_number
            FROM plan_updates u
            {update_active_clause}
              AND EXISTS (
                  SELECT 1 FROM plan_images i2
                  WHERE i2.update_id = u.id {image_exists_active_clause}
              )
        ), latest_updates AS (
            SELECT id, plan_id, published_at
            FROM eligible_updates
            WHERE row_number = 1
        )
        SELECT p.*,
               u.id AS latest_update_id,
               u.published_at,
               COUNT(i.id) AS image_count
        FROM plans p
        JOIN latest_updates u ON u.plan_id = p.id
        LEFT JOIN plan_images i
          ON i.update_id = u.id {image_active_clause}
        {active_clause}
    """


@public_router.get("/plans")
def list_plans(
    request: Request,
    q: str = Query(default="", max_length=60),
    ids: str = Query(default="", max_length=240),
    activity: str = Query(default="all", max_length=12),
    limit: int = Query(default=20, ge=1, le=50),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    keyword = _clean_name(q)
    activity = activity.strip().lower()
    if activity not in {"all", "recent", "history"}:
        raise HTTPException(status_code=400, detail="计划活跃范围不正确")
    query = _plan_summary_query()
    params: list[Any] = []
    plan_ids = []
    for value in ids.split(","):
        value = value.strip()
        if value.isdigit():
            plan_ids.append(int(value))
    plan_ids = list(dict.fromkeys(plan_ids))[:50]
    with closing(_connect()) as conn:
        if plan_ids:
            plan_ids = list(
                dict.fromkeys(_canonical_plan_id(conn, value) for value in plan_ids)
            )
            placeholders = ",".join("?" for _ in plan_ids)
            query += f" AND p.id IN ({placeholders})"
            params.extend(plan_ids)
        if keyword:
            query += " AND p.name LIKE ?"
            params.append(f"%{keyword}%")
        if not plan_ids and activity != "all":
            cutoff = datetime.now(CHINA_TZ) - timedelta(days=6)
            cutoff_ts = int(
                cutoff.replace(
                    hour=0,
                    minute=0,
                    second=0,
                    microsecond=0,
                ).timestamp()
            )
            query += (
                " AND u.published_at >= ?"
                if activity == "recent"
                else " AND u.published_at < ?"
            )
            params.append(cutoff_ts)
        query += (
            " GROUP BY p.id, u.id"
            " ORDER BY u.published_at DESC, p.id DESC LIMIT ? OFFSET ?"
        )
        params.extend([limit + 1, offset])
        rows = conn.execute(query, params).fetchall()
        has_more = len(rows) > limit
        visible = rows[:limit]
        items = [
            _serialize_plan_summary(request, conn, row) for row in visible
        ]
    return {
        "items": items,
        "count": len(items),
        "offset": offset,
        "nextOffset": offset + len(items) if has_more else None,
        "hasMore": has_more,
    }


@public_router.get("/plans/recent")
def recent_plans(
    request: Request,
    limit: int = Query(default=6, ge=1, le=20),
) -> dict[str, Any]:
    query = _plan_summary_query()
    query += (
        " GROUP BY p.id, u.id"
        " ORDER BY u.published_at DESC, p.id DESC LIMIT ?"
    )
    with closing(_connect()) as conn:
        rows = conn.execute(query, (limit,)).fetchall()
        items = [_serialize_plan_summary(request, conn, row) for row in rows]
    return {"items": items, "count": len(items)}


@public_router.get("/plans/{plan_id}/updates")
def plan_updates(
    request: Request,
    plan_id: int,
    days: int | None = Query(default=None, ge=1, le=3650),
    limit: int = Query(default=10, ge=1, le=30),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    cutoff_clause = ""
    with closing(_connect()) as conn:
        canonical_plan_id = _canonical_plan_id(conn, plan_id)
        params: list[Any] = [canonical_plan_id]
        if days is not None:
            cutoff = datetime.now(CHINA_TZ) - timedelta(days=days - 1)
            start = cutoff.replace(hour=0, minute=0, second=0, microsecond=0)
            cutoff_clause = "AND u.published_at >= ?"
            params.append(int(start.timestamp()))
        params.extend([limit + 1, offset])
        plan = conn.execute(
            """
            SELECT id, slug, name, uploader_name
            FROM plans WHERE id = ? AND is_active = 1
            """,
            (canonical_plan_id,),
        ).fetchone()
        if plan is None:
            raise HTTPException(status_code=404, detail="计划不存在或已下架")
        alias_ids = _plan_alias_ids(conn, int(plan["id"]))
        rows = conn.execute(
            f"""
            SELECT u.* FROM plan_updates u
            WHERE u.plan_id = ? AND u.is_active = 1
              {cutoff_clause}
              AND EXISTS (
                  SELECT 1 FROM plan_images i
                  WHERE i.update_id = u.id AND i.is_active = 1
              )
            ORDER BY u.published_at DESC, u.id DESC
            LIMIT ? OFFSET ?
            """,
            params,
        ).fetchall()
        has_more = len(rows) > limit
        visible = rows[:limit]
        items = []
        for update in visible:
            images = conn.execute(
                """
                SELECT * FROM plan_images
                WHERE update_id = ? AND is_active = 1
                ORDER BY position, id
                """,
                (update["id"],),
            ).fetchall()
            items.append(
                {
                    "id": str(update["id"]),
                    "title": update["title"],
                    "publishedAt": _iso_time(update["published_at"]),
                    "images": [
                        _serialize_image(request, image) for image in images
                    ],
                }
            )
    return {
        "plan": {
            "id": str(plan["id"]),
            "aliasIds": alias_ids,
            "slug": plan["slug"],
            "name": plan["name"],
            "uploaderName": plan["uploader_name"],
        },
        "items": items,
        "count": len(items),
        "offset": offset,
        "nextOffset": offset + len(items) if has_more else None,
        "hasMore": has_more,
    }


def _article_summary_query() -> str:
    return """
        WITH ranked_versions AS (
            SELECT v.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY v.article_id
                       ORDER BY v.captured_at DESC, v.id DESC
                   ) AS row_number
            FROM plan_article_versions v
            WHERE v.is_active = 1
              AND EXISTS (
                  SELECT 1 FROM plan_article_images image
                  WHERE image.version_id = v.id AND image.is_active = 1
              )
        ), latest_versions AS (
            SELECT * FROM ranked_versions WHERE row_number = 1
        )
        SELECT article.*,
               version.id AS latest_version_id,
               version.captured_at,
               COUNT(image.id) AS image_count
        FROM plan_articles article
        JOIN latest_versions version ON version.article_id = article.id
        JOIN plan_article_images image
          ON image.version_id = version.id AND image.is_active = 1
        WHERE article.is_active = 1
    """


def _serialize_article_summary(
    request: Request,
    conn: sqlite3.Connection,
    row: sqlite3.Row,
) -> dict[str, Any]:
    thumbnail = conn.execute(
        """
        SELECT thumbnail_filename FROM plan_article_images
        WHERE version_id = ? AND is_active = 1
        ORDER BY position, id LIMIT 1
        """,
        (row["latest_version_id"],),
    ).fetchone()
    captured_at = int(row["captured_at"])
    captured = datetime.fromtimestamp(captured_at, CHINA_TZ)
    now = datetime.now(CHINA_TZ)
    return {
        "id": str(row["id"]),
        "contentType": "article",
        "sourceName": row["source_name"],
        "sourceArticleId": row["source_article_id"],
        "name": row["title"],
        "uploaderName": "原文内容",
        "publishedAt": _iso_time(int(row["published_at"])),
        "latestVersionId": str(row["latest_version_id"]),
        "latestUpdatedAt": _iso_time(captured_at),
        "updatedToday": (
            now.year == captured.year
            and now.month == captured.month
            and now.day == captured.day
        ),
        "latestImageCount": int(row["image_count"]),
        "latestThumbnailUrl": (
            _media_url(request, thumbnail["thumbnail_filename"])
            if thumbnail is not None
            else None
        ),
    }


@public_router.get("/plan-articles")
def list_plan_articles(
    request: Request,
    q: str = Query(default="", max_length=100),
    ids: str = Query(default="", max_length=500),
    activity: str = Query(default="all", max_length=12),
    limit: int = Query(default=20, ge=1, le=50),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    keyword = _clean_name(q, maximum=100)
    activity = activity.strip().lower()
    if activity not in {"all", "recent", "history"}:
        raise HTTPException(status_code=400, detail="原文活跃范围不正确")
    article_ids = list(
        dict.fromkeys(
            int(value.strip())
            for value in ids.split(",")
            if value.strip().isdigit()
        )
    )[:50]
    query = _article_summary_query()
    params: list[Any] = []
    if article_ids:
        placeholders = ",".join("?" for _ in article_ids)
        query += f" AND article.id IN ({placeholders})"
        params.extend(article_ids)
    if keyword:
        query += " AND article.title LIKE ?"
        params.append(f"%{keyword}%")
    if not article_ids and activity != "all":
        cutoff = datetime.now(CHINA_TZ) - timedelta(days=6)
        cutoff_ts = int(
            cutoff.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        )
        query += (
            " AND article.published_at >= ?"
            if activity == "recent"
            else " AND article.published_at < ?"
        )
        params.append(cutoff_ts)
    query += (
        " GROUP BY article.id, version.id"
        " ORDER BY article.published_at DESC, article.id DESC"
        " LIMIT ? OFFSET ?"
    )
    params.extend([limit + 1, offset])
    with closing(_connect()) as conn:
        rows = conn.execute(query, params).fetchall()
        has_more = len(rows) > limit
        visible = rows[:limit]
        items = [
            _serialize_article_summary(request, conn, row) for row in visible
        ]
    return {
        "enabled": PLAN_ARTICLES_PUBLIC_ENABLED,
        "items": items,
        "count": len(items),
        "offset": offset,
        "nextOffset": offset + len(items) if has_more else None,
        "hasMore": has_more,
    }


@public_router.get("/plan-articles/recent")
def recent_plan_articles(
    request: Request,
    limit: int = Query(default=6, ge=1, le=20),
) -> dict[str, Any]:
    query = _article_summary_query()
    query += (
        " GROUP BY article.id, version.id"
        " ORDER BY article.published_at DESC, article.id DESC LIMIT ?"
    )
    with closing(_connect()) as conn:
        rows = conn.execute(query, (limit,)).fetchall()
        items = [
            _serialize_article_summary(request, conn, row) for row in rows
        ]
    return {
        "enabled": PLAN_ARTICLES_PUBLIC_ENABLED,
        "items": items,
        "count": len(items),
    }


@public_router.get("/plan-articles/{article_id}/versions")
def plan_article_versions(
    request: Request,
    article_id: int,
    limit: int = Query(default=10, ge=1, le=30),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    with closing(_connect()) as conn:
        article = conn.execute(
            """
            SELECT * FROM plan_articles
            WHERE id = ? AND is_active = 1
            """,
            (article_id,),
        ).fetchone()
        if article is None:
            raise HTTPException(status_code=404, detail="原文内容不存在或已下架")
        rows = conn.execute(
            """
            SELECT version.* FROM plan_article_versions version
            WHERE version.article_id = ? AND version.is_active = 1
              AND EXISTS (
                  SELECT 1 FROM plan_article_images image
                  WHERE image.version_id = version.id AND image.is_active = 1
              )
            ORDER BY version.captured_at DESC, version.id DESC
            LIMIT ? OFFSET ?
            """,
            (article_id, limit + 1, offset),
        ).fetchall()
        has_more = len(rows) > limit
        visible = rows[:limit]
        items = []
        for version in visible:
            images = conn.execute(
                """
                SELECT * FROM plan_article_images
                WHERE version_id = ? AND is_active = 1
                ORDER BY position, id
                """,
                (version["id"],),
            ).fetchall()
            items.append(
                {
                    "id": str(version["id"]),
                    "title": version["title"],
                    "publishedAt": _iso_time(version["captured_at"]),
                    "sourcePublishedAt": _iso_time(version["published_at"]),
                    "images": [
                        _serialize_image(request, image) for image in images
                    ],
                }
            )
    return {
        "article": {
            "id": str(article["id"]),
            "contentType": "article",
            "sourceName": article["source_name"],
            "sourceArticleId": article["source_article_id"],
            "name": article["title"],
            "uploaderName": "原文内容",
            "publishedAt": _iso_time(article["published_at"]),
        },
        "items": items,
        "count": len(items),
        "offset": offset,
        "nextOffset": offset + len(items) if has_more else None,
        "hasMore": has_more,
    }


@admin_router.get("/plans", dependencies=[Depends(_require_admin)])
def admin_list_plans(request: Request) -> dict[str, Any]:
    with closing(_connect()) as conn:
        plans = conn.execute(
            """
            SELECT p.*,
                   (SELECT COUNT(*) FROM plan_updates u
                    WHERE u.plan_id = p.id) AS update_count,
                   (SELECT COUNT(*) FROM plan_aliases a
                    WHERE a.canonical_plan_id = p.id) AS alias_count,
                   (SELECT a.canonical_plan_id FROM plan_aliases a
                    WHERE a.alias_plan_id = p.id) AS canonical_plan_id
            FROM plans p ORDER BY p.updated_at DESC, p.id DESC
            """
        ).fetchall()
    return {
        "items": [
            {
                "id": str(row["id"]),
                "slug": row["slug"],
                "name": row["name"],
                "uploaderName": row["uploader_name"],
                "isActive": bool(row["is_active"]),
                "updateCount": int(row["update_count"]),
                "aliasCount": int(row["alias_count"]),
                "canonicalPlanId": (
                    str(row["canonical_plan_id"])
                    if row["canonical_plan_id"] is not None
                    else None
                ),
                "updatedAt": _iso_time(row["updated_at"]),
            }
            for row in plans
        ]
    }


@admin_router.get("/plan-sync/articles", dependencies=[Depends(_require_admin)])
def admin_list_plan_sync_articles(
    status: str = Query(default="pending_name", max_length=40),
    limit: int = Query(default=50, ge=1, le=200),
) -> dict[str, Any]:
    allowed_statuses = {
        "imported",
        "duplicate",
        "failed",
        "ignored",
        "mirrored",
        "name_configured",
        "pending_name",
        "retry_queued",
    }
    if status not in allowed_statuses:
        raise HTTPException(status_code=400, detail="同步状态不正确")
    with closing(_connect()) as conn:
        if not _ensure_plan_sync_article_columns(conn):
            return {"items": []}
        rows = conn.execute(
            """
            SELECT source_name, source_article_id, source_title,
                   raw_plan_name, resolved_plan_name, published_at,
                   status, error, needs_review, synced_at
            FROM plan_sync_articles
            WHERE status = ?
            ORDER BY synced_at DESC, id DESC
            LIMIT ?
            """,
            (status, limit),
        ).fetchall()
    return {
        "items": [
            {
                "sourceName": row["source_name"],
                "sourceArticleId": row["source_article_id"],
                "sourceTitle": row["source_title"],
                "rawPlanName": row["raw_plan_name"],
                "resolvedPlanName": row["resolved_plan_name"],
                "publishedAt": (
                    _iso_time(row["published_at"])
                    if int(row["published_at"] or 0) > 0
                    else None
                ),
                "status": row["status"],
                "error": row["error"],
                "needsReview": bool(row["needs_review"]),
                "syncedAt": _iso_time(row["synced_at"]),
            }
            for row in rows
        ]
    }


@admin_router.get(
    "/plan-sync/pending-names",
    dependencies=[Depends(_require_admin)],
)
def admin_list_pending_plan_names(
    q: str = Query(default="", max_length=60),
    limit: int = Query(default=40, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    keyword = _clean_name(q)
    with closing(_connect()) as conn:
        if not _ensure_plan_sync_article_columns(conn):
            return {
                "items": [],
                "count": 0,
                "totalNames": 0,
                "unidentifiedArticles": 0,
                "hasMore": False,
                "nextOffset": None,
            }
        where_keyword = ""
        params: list[Any] = []
        if keyword:
            where_keyword = "AND raw_plan_name LIKE ?"
            params.append(f"%{keyword}%")
        total_names = int(
            conn.execute(
                f"""
                SELECT COUNT(*) FROM (
                    SELECT raw_plan_name
                    FROM plan_sync_articles
                    WHERE status = 'pending_name'
                      AND TRIM(raw_plan_name) != ''
                      {where_keyword}
                    GROUP BY raw_plan_name
                )
                """,
                params,
            ).fetchone()[0]
        )
        unidentified_articles = int(
            conn.execute(
                """
                SELECT COUNT(*) FROM plan_sync_articles
                WHERE status = 'pending_name'
                  AND TRIM(raw_plan_name) = ''
                """
            ).fetchone()[0]
        )
        rows = conn.execute(
            f"""
            WITH grouped AS (
                SELECT raw_plan_name,
                       COUNT(*) AS article_count,
                       MIN(synced_at) AS oldest_synced_at,
                       MAX(synced_at) AS newest_synced_at
                FROM plan_sync_articles
                WHERE status = 'pending_name'
                  AND TRIM(raw_plan_name) != ''
                  {where_keyword}
                GROUP BY raw_plan_name
            )
            SELECT g.*,
                   (
                       SELECT source_title FROM plan_sync_articles a
                       WHERE a.status = 'pending_name'
                         AND a.raw_plan_name = g.raw_plan_name
                       ORDER BY a.synced_at DESC, a.id DESC LIMIT 1
                   ) AS sample_title,
                   (
                       SELECT source_article_id FROM plan_sync_articles a
                       WHERE a.status = 'pending_name'
                         AND a.raw_plan_name = g.raw_plan_name
                       ORDER BY a.synced_at DESC, a.id DESC LIMIT 1
                   ) AS sample_article_id,
                   (
                       SELECT error FROM plan_sync_articles a
                       WHERE a.status = 'pending_name'
                         AND a.raw_plan_name = g.raw_plan_name
                       ORDER BY a.synced_at DESC, a.id DESC LIMIT 1
                   ) AS sample_error
            FROM grouped g
            ORDER BY g.article_count DESC,
                     g.oldest_synced_at,
                     g.raw_plan_name COLLATE NOCASE
            LIMIT ? OFFSET ?
            """,
            (*params, limit + 1, offset),
        ).fetchall()
    has_more = len(rows) > limit
    visible = rows[:limit]
    return {
        "items": [
            {
                "rawPlanName": row["raw_plan_name"],
                "articleCount": int(row["article_count"]),
                "oldestAt": _iso_time(int(row["oldest_synced_at"])),
                "newestAt": _iso_time(int(row["newest_synced_at"])),
                "sampleTitle": row["sample_title"],
                "sampleArticleId": str(row["sample_article_id"]),
                "sampleError": row["sample_error"],
            }
            for row in visible
        ],
        "count": len(visible),
        "totalNames": total_names,
        "unidentifiedArticles": unidentified_articles,
        "offset": offset,
        "hasMore": has_more,
        "nextOffset": offset + len(visible) if has_more else None,
    }


def _fetch_source_article_images(source_article_id: str) -> list[str]:
    if not source_article_id.isdigit():
        raise HTTPException(status_code=400, detail="来源文章编号不正确")
    url = f"{PLAN_SOURCE_API_URL}/addons/cms/api.archives/detail"
    payload = json.dumps({"id": int(source_article_id)}).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={
            "User-Agent": "CaimasterPlanAdmin/1.0",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(
                request,
                timeout=PLAN_SOURCE_REQUEST_TIMEOUT,
            ) as response:
                raw = response.read(3 * 1024 * 1024 + 1)
            if len(raw) > 3 * 1024 * 1024:
                raise ValueError("source response too large")
            body = json.loads(raw.decode("utf-8"))
            if not isinstance(body, dict) or body.get("code") != 1:
                raise ValueError("source rejected request")
            archive = ((body.get("data") or {}).get("archivesInfo") or {})
            image_urls = extract_image_urls(
                archive.get("content"),
                PLAN_SOURCE_API_URL,
            )
            if not image_urls:
                fallback = str(archive.get("image") or "").strip().split("?", 1)[0]
                if fallback.startswith("https://"):
                    image_urls = [fallback]
            if not image_urls:
                raise HTTPException(status_code=404, detail="这篇文章没有可拆分图片")
            return image_urls[:30]
        except HTTPException:
            raise
        except (
            urllib.error.URLError,
            TimeoutError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            ValueError,
        ) as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(0.4 * (attempt + 1))
    raise HTTPException(
        status_code=502,
        detail=f"暂时无法读取来源图片：{last_error}",
    )


def _pending_article_for_split(source_article_id: str) -> sqlite3.Row:
    with closing(_connect()) as conn:
        if not _ensure_plan_sync_article_columns(conn):
            raise HTTPException(status_code=404, detail="没有找到待处理文章")
        row = conn.execute(
            """
            SELECT source_article_id, source_title, raw_plan_name, synced_at
            FROM plan_sync_articles
            WHERE source_name = 'hongxisaishi'
              AND source_article_id = ?
              AND status IN ('pending_name', 'name_configured')
            LIMIT 1
            """,
            (source_article_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="没有找到待拆分文章")
    if not str(row["raw_plan_name"] or "").strip():
        raise HTTPException(status_code=409, detail="这篇文章尚未提取出名称")
    return row


@admin_router.get(
    "/plan-sync/article-images",
    dependencies=[Depends(_require_admin)],
)
def admin_get_pending_article_images(
    source_article_id: str = Query(alias="sourceArticleId", max_length=40),
) -> dict[str, Any]:
    source_article_id = source_article_id.strip()
    article = _pending_article_for_split(source_article_id)
    image_urls = _fetch_source_article_images(source_article_id)
    return {
        "sourceArticleId": source_article_id,
        "sourceTitle": article["source_title"],
        "rawPlanName": article["raw_plan_name"],
        "imageCount": len(image_urls),
        "images": [
            {"position": index + 1, "imageUrl": image_url}
            for index, image_url in enumerate(image_urls)
        ],
    }


@admin_router.post(
    "/plan-sync/image-assignments",
    dependencies=[Depends(_require_admin)],
)
def admin_save_plan_image_assignment(
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    source_article_id = str(body.get("sourceArticleId") or "").strip()
    raw_name = _clean_name(body.get("rawPlanName"))
    raw_targets = body.get("targets")
    if not raw_name:
        raise HTTPException(status_code=400, detail="待拆分名称不能为空")
    if not isinstance(raw_targets, list) or not raw_targets or len(raw_targets) > 30:
        raise HTTPException(status_code=400, detail="请为每张图片选择计划")
    article = _pending_article_for_split(source_article_id)
    if _clean_name(article["raw_plan_name"]) != raw_name:
        raise HTTPException(status_code=409, detail="文章名称已经变化，请重新打开")
    image_urls = _fetch_source_article_images(source_article_id)
    if len(raw_targets) != len(image_urls):
        raise HTTPException(
            status_code=409,
            detail="来源图片数量已经变化，请重新检查后再保存",
        )
    targets = []
    for value in raw_targets:
        text = str(value or "").strip()
        target = (
            IGNORE_IMAGE_ASSIGNMENT
            if text.upper() == IGNORE_IMAGE_ASSIGNMENT
            else _clean_name(text)
        )
        if not target:
            raise HTTPException(status_code=400, detail="每张图片都必须选择计划或忽略")
        targets.append(target)
    plan_names = {
        target for target in targets if target != IGNORE_IMAGE_ASSIGNMENT
    }
    if not plan_names:
        raise HTTPException(status_code=400, detail="不能忽略这篇文章的全部图片")

    rules = _load_source_name_rules()
    image_assignments = dict(rules["imageAssignments"])
    image_assignments[raw_name] = targets
    allowed_names = set(rules["allowedNames"]) | plan_names
    ignored_names = set(rules["ignoredNames"])
    ignored_names.discard(raw_name)
    aliases = dict(rules["aliases"])
    aliases.pop(raw_name, None)
    updated_rules = _normalize_source_name_rules(
        {
            **rules,
            "allowedNames": sorted(allowed_names),
            "aliases": aliases,
            "imageAssignments": image_assignments,
            "ignoredNames": sorted(ignored_names),
        }
    )
    _save_source_name_rules(updated_rules)

    with closing(_connect()) as conn:
        cursor = conn.execute(
            """
            UPDATE plan_sync_articles
            SET status = 'name_configured',
                resolved_plan_name = '',
                error = 'image split configured; waiting for next sync',
                needs_review = 0,
                synced_at = ?
            WHERE raw_plan_name = ?
              AND status = 'pending_name'
            """,
            (_now_ts(), raw_name),
        )
        conn.commit()
    return {
        "ok": True,
        "rawPlanName": raw_name,
        "imageCount": len(targets),
        "planNames": sorted(plan_names),
        "updatedRows": cursor.rowcount,
    }


@admin_router.get("/plan-sync/summary", dependencies=[Depends(_require_admin)])
def admin_plan_sync_summary() -> dict[str, Any]:
    now = _now_ts()
    with closing(_connect()) as conn:
        _ensure_plan_sync_run_table(conn)
        if not _ensure_plan_sync_article_columns(conn):
            return {
                "items": {},
                "total": 0,
                "lastSyncedAt": None,
                "rulesPath": str(PLAN_SOURCE_MAP_PATH),
                "latestRun": None,
                "governance": _empty_sync_governance(),
            }
        rows = conn.execute(
            """
            SELECT status, COUNT(*) AS count, MAX(synced_at) AS last_synced_at
            FROM plan_sync_articles
            GROUP BY status
            """
        ).fetchall()
        latest_run = conn.execute(
            """
            SELECT * FROM plan_sync_runs
            ORDER BY started_at DESC, id DESC
            LIMIT 1
            """
        ).fetchone()
        governance = _sync_governance_summary(conn, now=now)
    counts = {row["status"]: int(row["count"]) for row in rows}
    last_synced_at = max(
        (int(row["last_synced_at"] or 0) for row in rows),
        default=0,
    )
    return {
        "items": counts,
        "total": sum(counts.values()),
        "lastSyncedAt": _iso_time(last_synced_at) if last_synced_at else None,
        "rulesPath": str(PLAN_SOURCE_MAP_PATH),
        "latestRun": _serialize_sync_run(latest_run) if latest_run is not None else None,
        "governance": governance,
    }


def _empty_sync_governance() -> dict[str, Any]:
    return {
        "pendingArticles": 0,
        "pendingDistinctNames": 0,
        "pendingUnidentifiedArticles": 0,
        "pendingLast24Hours": 0,
        "pendingLast7Days": 0,
        "pendingOlderThan7Days": 0,
        "oldestPendingAt": None,
        "failedArticles": 0,
        "retryQueued": 0,
        "activePlans": 0,
        "visiblePlans": 0,
        "hiddenActivePlans": 0,
        "mirroredArticles": 0,
        "mirroredVersions": 0,
        "mirrorBacklog": 0,
        "topPendingNames": [],
    }


def _sync_governance_summary(
    conn: sqlite3.Connection,
    *,
    now: int,
) -> dict[str, Any]:
    pending_statuses = ("pending_name", "name_configured")
    pending = conn.execute(
        """
        SELECT
          COUNT(*) AS article_count,
          COUNT(DISTINCT LOWER(NULLIF(TRIM(
            CASE
              WHEN raw_plan_name != '' THEN raw_plan_name
              ELSE resolved_plan_name
            END
          ), ''))) AS distinct_name_count,
          SUM(CASE WHEN TRIM(raw_plan_name) = ''
                        AND TRIM(resolved_plan_name) = ''
                   THEN 1 ELSE 0 END) AS unidentified_count,
          SUM(CASE WHEN synced_at >= ? THEN 1 ELSE 0 END) AS last_24_hours,
          SUM(CASE WHEN synced_at >= ? THEN 1 ELSE 0 END) AS last_7_days,
          SUM(CASE WHEN synced_at < ? THEN 1 ELSE 0 END) AS older_than_7_days,
          MIN(synced_at) AS oldest_synced_at
        FROM plan_sync_articles
        WHERE status IN (?, ?)
        """,
        (
            now - 24 * 60 * 60,
            now - 7 * 24 * 60 * 60,
            now - 7 * 24 * 60 * 60,
            *pending_statuses,
        ),
    ).fetchone()
    top_names = conn.execute(
        """
        SELECT
          CASE
            WHEN TRIM(raw_plan_name) != '' THEN TRIM(raw_plan_name)
            WHEN TRIM(resolved_plan_name) != '' THEN TRIM(resolved_plan_name)
            ELSE '未识别名称'
          END AS name,
          COUNT(*) AS article_count,
          MIN(synced_at) AS oldest_synced_at,
          MAX(synced_at) AS newest_synced_at
        FROM plan_sync_articles
        WHERE status IN (?, ?)
        GROUP BY name COLLATE NOCASE
        ORDER BY article_count DESC, oldest_synced_at, name COLLATE NOCASE
        LIMIT 8
        """,
        pending_statuses,
    ).fetchall()
    failed_articles = int(
        conn.execute(
            "SELECT COUNT(*) FROM plan_sync_articles WHERE status = 'failed'"
        ).fetchone()[0]
    )
    retry_queued = int(
        conn.execute(
            "SELECT COUNT(*) FROM plan_sync_articles WHERE status = 'retry_queued'"
        ).fetchone()[0]
    )
    active_plans = int(
        conn.execute("SELECT COUNT(*) FROM plans WHERE is_active = 1").fetchone()[0]
    )
    visible_plans = int(
        conn.execute(
            """
            SELECT COUNT(DISTINCT p.id)
            FROM plans p
            JOIN plan_updates u ON u.plan_id = p.id AND u.is_active = 1
            JOIN plan_images i ON i.update_id = u.id AND i.is_active = 1
            WHERE p.is_active = 1
            """
        ).fetchone()[0]
    )
    article_tables = {
        str(row["name"])
        for row in conn.execute(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND name IN ('plan_articles', 'plan_article_versions')
            """
        )
    }
    if article_tables == {"plan_articles", "plan_article_versions"}:
        mirrored_articles = int(
            conn.execute("SELECT COUNT(*) FROM plan_articles").fetchone()[0]
        )
        mirrored_versions = int(
            conn.execute(
                "SELECT COUNT(*) FROM plan_article_versions"
            ).fetchone()[0]
        )
        if PLAN_ARTICLE_MIRROR_SINCE > 0:
            mirror_backlog = int(
                conn.execute(
                    """
                    SELECT COUNT(*)
                    FROM plan_sync_articles sync
                    LEFT JOIN plan_articles article
                      ON article.source_name = sync.source_name
                     AND article.source_article_id = sync.source_article_id
                    WHERE sync.status != 'ignored'
                      AND sync.published_at >= ?
                      AND article.id IS NULL
                    """,
                    (PLAN_ARTICLE_MIRROR_SINCE,),
                ).fetchone()[0]
            )
        else:
            mirror_backlog = 0
    else:
        mirrored_articles = 0
        mirrored_versions = 0
        mirror_backlog = 0
    oldest_pending = int(pending["oldest_synced_at"] or 0)
    return {
        "pendingArticles": int(pending["article_count"] or 0),
        "pendingDistinctNames": int(pending["distinct_name_count"] or 0),
        "pendingUnidentifiedArticles": int(pending["unidentified_count"] or 0),
        "pendingLast24Hours": int(pending["last_24_hours"] or 0),
        "pendingLast7Days": int(pending["last_7_days"] or 0),
        "pendingOlderThan7Days": int(pending["older_than_7_days"] or 0),
        "oldestPendingAt": _iso_time(oldest_pending) if oldest_pending else None,
        "failedArticles": failed_articles,
        "retryQueued": retry_queued,
        "activePlans": active_plans,
        "visiblePlans": visible_plans,
        "hiddenActivePlans": max(0, active_plans - visible_plans),
        "mirroredArticles": mirrored_articles,
        "mirroredVersions": mirrored_versions,
        "mirrorBacklog": mirror_backlog,
        "topPendingNames": [
            {
                "name": row["name"],
                "articleCount": int(row["article_count"]),
                "oldestAt": _iso_time(int(row["oldest_synced_at"])),
                "newestAt": _iso_time(int(row["newest_synced_at"])),
            }
            for row in top_names
        ],
    }


@admin_router.get("/plan-sync/health", dependencies=[Depends(_require_admin)])
def admin_plan_sync_health() -> dict[str, Any]:
    checks: list[dict[str, str]] = []
    for module_name in ("fastapi", "PIL", "multipart"):
        checks.append(
            _health_item(
                "ok" if _module_available(module_name) else "error",
                f"python module {module_name}",
                "available" if _module_available(module_name) else "missing",
            )
        )

    checks.append(
        _health_item(
            (
                "error"
                if not PLAN_ADMIN_TOKEN
                or PLAN_ADMIN_TOKEN.startswith("replace-with-")
                else "ok"
            ),
            "CAIMASTER_PLAN_ADMIN_TOKEN",
            (
                "still set to example placeholder"
                if PLAN_ADMIN_TOKEN.startswith("replace-with-")
                else "configured"
                if PLAN_ADMIN_TOKEN
                else "missing"
            ),
        )
    )
    source_enabled = os.environ.get("CAIMASTER_PLAN_SOURCE_ENABLED") == "1"
    checks.append(
        _health_item(
            "ok" if source_enabled else "warn",
            "CAIMASTER_PLAN_SOURCE_ENABLED",
            "enabled" if source_enabled else "not enabled",
        )
    )

    try:
        rules = _load_source_name_rules()
        checks.append(
            _health_item(
                "ok",
                "plan source map",
                (
                    f"{PLAN_SOURCE_MAP_PATH} "
                    f"aliases={len(rules['aliases'])} "
                    f"allowed={len(rules['allowedNames'])} "
                    f"ignored={len(rules['ignoredNames'])}"
                ),
            )
        )
    except HTTPException as exc:
        checks.append(_health_item("error", "plan source map", str(exc.detail)))

    if not API_APP_PATH.is_file():
        checks.append(_health_item("error", "api app.py", f"missing: {API_APP_PATH}"))
    else:
        try:
            app_source = API_APP_PATH.read_text(encoding="utf-8")
        except OSError as exc:
            checks.append(_health_item("error", "api app.py", f"cannot read: {exc}"))
        else:
            checks.append(
                _health_item(
                    "ok" if "install_plan_routes" in app_source else "error",
                    "api app.py",
                    (
                        "plan routes installed"
                        if "install_plan_routes" in app_source
                        else "missing install_plan_routes(app)"
                    ),
                )
            )

    checks.append(
        _health_item(
            "ok" if PLAN_ADMIN_HTML.is_file() else "error",
            "admin html",
            str(PLAN_ADMIN_HTML) if PLAN_ADMIN_HTML.is_file() else "missing",
        )
    )
    if PLAN_MEDIA_DIR.is_dir():
        media_writable = os.access(PLAN_MEDIA_DIR, os.W_OK)
        checks.append(
            _health_item(
                "ok" if media_writable else "error",
                "media directory",
                f"{PLAN_MEDIA_DIR} writable={media_writable}",
            )
        )
    else:
        parent_writable = os.access(PLAN_MEDIA_DIR.parent, os.W_OK)
        checks.append(
            _health_item(
                "warn" if parent_writable else "error",
                "media directory",
                f"missing: {PLAN_MEDIA_DIR}; parent_writable={parent_writable}",
            )
        )

    for path, name in (
        (PLAN_SYNC_SERVICE_PATH, "sync service"),
        (PLAN_SYNC_TIMER_PATH, "sync timer"),
    ):
        checks.append(
            _health_item(
                "ok" if path.is_file() else "warn",
                name,
                str(path) if path.is_file() else "missing",
            )
        )

    with closing(_connect()) as conn:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).fetchall()
        tables = {row["name"] for row in rows}
        required_tables = {"plans", "plan_updates", "plan_images"}
        sync_tables = {"plan_sync_articles", "plan_sync_images", "plan_sync_runs"}
        missing_required = sorted(required_tables - tables)
        missing_sync = sorted(sync_tables - tables)
        checks.append(
            _health_item(
                "error" if missing_required else "ok",
                "plan database",
                (
                    f"missing tables: {missing_required}"
                    if missing_required
                    else f"core tables present: {PLAN_DB_PATH}"
                ),
            )
        )
        checks.append(
            _health_item(
                "warn" if missing_sync else "ok",
                "sync database",
                (
                    f"missing tables: {missing_sync}"
                    if missing_sync
                    else "sync tables present"
                ),
            )
        )
        pending_count = 0
        failed_count = 0
        retry_count = 0
        latest_run = None
        if not missing_sync:
            pending_count = int(
                conn.execute(
                    """
                    SELECT COUNT(*) FROM plan_sync_articles
                    WHERE status IN ('pending_name', 'name_configured')
                    """
                ).fetchone()[0]
            )
            failed_count = int(
                conn.execute(
                    """
                    SELECT COUNT(*) FROM plan_sync_articles
                    WHERE status = 'failed'
                    """
                ).fetchone()[0]
            )
            retry_count = int(
                conn.execute(
                    """
                    SELECT COUNT(*) FROM plan_sync_articles
                    WHERE status = 'retry_queued'
                    """
                ).fetchone()[0]
            )
            latest_run = conn.execute(
                """
                SELECT * FROM plan_sync_runs
                ORDER BY started_at DESC, id DESC
                LIMIT 1
                """
            ).fetchone()

    checks.append(
        _health_item(
            "warn" if pending_count else "ok",
            "pending names",
            str(pending_count),
        )
    )
    checks.append(
        _health_item(
            "warn" if failed_count else "ok",
            "failed articles",
            str(failed_count),
        )
    )
    checks.append(
        _health_item(
            "ok",
            "retry queued",
            str(retry_count),
        )
    )
    if latest_run is not None:
        serialized_run = _serialize_sync_run(latest_run)
        checks.append(
            _health_item(
                "error" if serialized_run["status"] == "failed" else "ok",
                "latest sync run",
                (
                    f"{serialized_run['status']} "
                    f"started={serialized_run['startedAt']} "
                    f"candidates={serialized_run['candidates']}"
                ),
            )
        )
    else:
        checks.append(_health_item("warn", "latest sync run", "none"))

    return {
        "ok": not any(check["level"] == "error" for check in checks),
        "checks": checks,
    }


@admin_router.post("/plan-sync/articles/retry", dependencies=[Depends(_require_admin)])
def admin_retry_plan_sync_articles(
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    source_article_id = str(body.get("sourceArticleId") or "").strip()
    retry_all = bool(body.get("all", False))
    if not source_article_id and not retry_all:
        raise HTTPException(status_code=400, detail="请选择要重试的文章")

    params: list[Any] = ["retry queued by admin", _now_ts()]
    where_clause = "status = 'failed'"
    if source_article_id:
        where_clause += " AND source_article_id = ?"
        params.append(source_article_id)

    with closing(_connect()) as conn:
        if not _ensure_plan_sync_article_columns(conn):
            return {"ok": True, "updatedRows": 0}
        cursor = conn.execute(
            f"""
            UPDATE plan_sync_articles
            SET status = 'retry_queued',
                error = ?,
                needs_review = 0,
                synced_at = ?
            WHERE {where_clause}
            """,
            params,
        )
        conn.commit()
    return {"ok": True, "updatedRows": cursor.rowcount}


def _serialize_sync_run(row: sqlite3.Row) -> dict[str, Any]:
    try:
        counts = json.loads(row["counts_json"] or "{}")
    except json.JSONDecodeError:
        counts = {}
    if not isinstance(counts, dict):
        counts = {}
    return {
        "id": str(row["id"]),
        "sourceName": row["source_name"],
        "startedAt": _iso_time(row["started_at"]),
        "finishedAt": (
            _iso_time(row["finished_at"])
            if row["finished_at"] is not None
            else None
        ),
        "status": row["status"],
        "candidates": int(row["candidates"]),
        "counts": counts,
        "error": row["error"],
    }


@admin_router.get("/plan-sync/runs", dependencies=[Depends(_require_admin)])
def admin_list_plan_sync_runs(
    limit: int = Query(default=10, ge=1, le=50),
) -> dict[str, Any]:
    with closing(_connect()) as conn:
        _ensure_plan_sync_run_table(conn)
        rows = conn.execute(
            """
            SELECT * FROM plan_sync_runs
            ORDER BY started_at DESC, id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return {"items": [_serialize_sync_run(row) for row in rows]}


@admin_router.get("/plan-sync/name-rules", dependencies=[Depends(_require_admin)])
def admin_get_plan_sync_name_rules() -> dict[str, Any]:
    return {
        "path": str(PLAN_SOURCE_MAP_PATH),
        "rules": _load_source_name_rules(),
    }


@admin_router.put("/plan-sync/name-rules", dependencies=[Depends(_require_admin)])
def admin_update_plan_sync_name_rules(
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    rules = _normalize_source_name_rules(body.get("rules", body))
    _save_source_name_rules(rules)
    return {"ok": True, "rules": rules}


@admin_router.post(
    "/plan-sync/name-rules/actions",
    dependencies=[Depends(_require_admin)],
)
def admin_apply_plan_sync_name_rule_action(
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    action = str(body.get("action") or "").strip()
    raw_name = _clean_name(body.get("rawName"))
    standard_name = _clean_name(
        body.get("standardName") or body.get("name") or raw_name
    )
    if action not in {"allow", "ignore"}:
        raise HTTPException(status_code=400, detail="名称治理动作不正确")
    if not raw_name:
        raise HTTPException(status_code=400, detail="来源名称不能为空")

    rules = _load_source_name_rules()
    aliases = dict(rules["aliases"])
    allowed_names = set(rules["allowedNames"])
    ignored_names = set(rules["ignoredNames"])
    resolved_name = ""

    if action == "ignore":
        ignored_names.add(raw_name)
        aliases.pop(raw_name, None)
        next_status = "ignored"
        error = "name ignored by admin"
    else:
        if not standard_name:
            raise HTTPException(status_code=400, detail="标准名称不能为空")
        resolved_name = standard_name
        allowed_names.add(standard_name)
        ignored_names.discard(raw_name)
        if raw_name == standard_name:
            aliases.pop(raw_name, None)
        else:
            aliases[raw_name] = standard_name
        next_status = "name_configured"
        error = "name rule configured; waiting for next sync"

    updated_rules = {
        **rules,
        "allowedNames": sorted(allowed_names),
        "aliases": dict(sorted(aliases.items())),
        "ignoredNames": sorted(ignored_names),
    }
    _save_source_name_rules(updated_rules)

    updated_rows = 0
    with closing(_connect()) as conn:
        if _ensure_plan_sync_article_columns(conn):
            cursor = conn.execute(
                """
                UPDATE plan_sync_articles
                SET status = ?,
                    resolved_plan_name = ?,
                    error = ?,
                    needs_review = 0,
                    synced_at = ?
                WHERE raw_plan_name = ?
                  AND status = 'pending_name'
                """,
                (
                    next_status,
                    resolved_name,
                    error,
                    _now_ts(),
                    raw_name,
                ),
            )
            conn.commit()
            updated_rows = cursor.rowcount

    return {
        "ok": True,
        "updatedRows": updated_rows,
        "rules": updated_rules,
    }


@admin_router.post("/plans", dependencies=[Depends(_require_admin)])
def create_plan(body: dict[str, Any] = Body(default={})) -> dict[str, Any]:
    name = _clean_name(body.get("name"))
    if not name:
        raise HTTPException(status_code=400, detail="请输入计划名称")
    uploader_name = _clean_name(
        body.get("uploaderName") or "球镜助手",
        maximum=40,
    )
    slug = _slug(_clean_name(body.get("slug")) or name)
    now = _now_ts()
    with closing(_connect()) as conn:
        try:
            cursor = conn.execute(
                """
                INSERT INTO plans(
                    slug, name, uploader_name, is_active, created_at, updated_at
                ) VALUES (?, ?, ?, 1, ?, ?)
                """,
                (slug, name, uploader_name, now, now),
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="计划名称标识已存在") from exc
    return {"id": str(cursor.lastrowid), "name": name, "slug": slug}


@admin_router.patch(
    "/plans/{plan_id}",
    dependencies=[Depends(_require_admin)],
)
def update_plan(
    plan_id: int,
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    fields = []
    params: list[Any] = []
    if "name" in body:
        name = _clean_name(body.get("name"))
        if not name:
            raise HTTPException(status_code=400, detail="计划名称不能为空")
        fields.append("name = ?")
        params.append(name)
    if "isActive" in body:
        fields.append("is_active = ?")
        params.append(1 if bool(body.get("isActive")) else 0)
    if not fields:
        raise HTTPException(status_code=400, detail="没有可修改内容")
    fields.append("updated_at = ?")
    params.extend([_now_ts(), plan_id])
    with closing(_connect()) as conn:
        cursor = conn.execute(
            f"UPDATE plans SET {', '.join(fields)} WHERE id = ?",
            params,
        )
        conn.commit()
    if cursor.rowcount == 0:
        raise HTTPException(status_code=404, detail="计划不存在")
    return {"ok": True}


@admin_router.post(
    "/plans/{source_plan_id}/merge",
    dependencies=[Depends(_require_admin)],
)
def merge_plan(
    source_plan_id: int,
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    target_text = str(body.get("targetPlanId") or "").strip()
    if not target_text.isdigit():
        raise HTTPException(status_code=400, detail="请选择目标计划")
    target_plan_id = int(target_text)
    execute = body.get("execute") is True
    now = _now_ts()

    with closing(_connect()) as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            canonical_source = _canonical_plan_id(conn, source_plan_id)
            canonical_target = _canonical_plan_id(conn, target_plan_id)
            if canonical_source != source_plan_id:
                raise HTTPException(status_code=409, detail="来源计划已经合并")
            if canonical_target == source_plan_id:
                raise HTTPException(status_code=400, detail="不能合并到自身")
            source = conn.execute(
                "SELECT id, name, is_active FROM plans WHERE id = ?",
                (source_plan_id,),
            ).fetchone()
            target = conn.execute(
                "SELECT id, name, is_active FROM plans WHERE id = ?",
                (canonical_target,),
            ).fetchone()
            if source is None or target is None:
                raise HTTPException(status_code=404, detail="来源计划或目标计划不存在")
            if not bool(target["is_active"]):
                raise HTTPException(status_code=409, detail="目标计划已下架")

            update_count = int(
                conn.execute(
                    "SELECT COUNT(*) FROM plan_updates WHERE plan_id = ?",
                    (source_plan_id,),
                ).fetchone()[0]
            )
            image_count = int(
                conn.execute(
                    """
                    SELECT COUNT(*) FROM plan_images i
                    JOIN plan_updates u ON u.id = i.update_id
                    WHERE u.plan_id = ?
                    """,
                    (source_plan_id,),
                ).fetchone()[0]
            )
            inherited_alias_count = int(
                conn.execute(
                    "SELECT COUNT(*) FROM plan_aliases WHERE canonical_plan_id = ?",
                    (source_plan_id,),
                ).fetchone()[0]
            )
            result = {
                "ok": True,
                "executed": execute,
                "source": {"id": str(source["id"]), "name": source["name"]},
                "target": {"id": str(target["id"]), "name": target["name"]},
                "updateCount": update_count,
                "imageCount": image_count,
                "inheritedAliasCount": inherited_alias_count,
            }
            if not execute:
                conn.rollback()
                return result

            conn.execute(
                "UPDATE plan_updates SET plan_id = ? WHERE plan_id = ?",
                (canonical_target, source_plan_id),
            )
            sync_table = conn.execute(
                """
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'plan_sync_articles'
                """
            ).fetchone()
            if sync_table is not None:
                conn.execute(
                    "UPDATE plan_sync_articles SET plan_id = ? WHERE plan_id = ?",
                    (canonical_target, source_plan_id),
                )
            conn.execute(
                """
                UPDATE plan_aliases SET canonical_plan_id = ?
                WHERE canonical_plan_id = ?
                """,
                (canonical_target, source_plan_id),
            )
            conn.execute(
                """
                INSERT INTO plan_aliases(alias_plan_id, canonical_plan_id, created_at)
                VALUES (?, ?, ?)
                """,
                (source_plan_id, canonical_target, now),
            )
            conn.execute(
                "UPDATE plans SET is_active = 0, updated_at = ? WHERE id = ?",
                (now, source_plan_id),
            )
            conn.execute(
                "UPDATE plans SET updated_at = ? WHERE id = ?",
                (now, canonical_target),
            )
            conn.commit()
            return result
        except Exception:
            conn.rollback()
            raise


def _prepare_image(contents: bytes) -> tuple[bytes, bytes, int, int]:
    if len(contents) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="单张图片不能超过15MB")
    try:
        with Image.open(io.BytesIO(contents)) as opened:
            opened.verify()
        with Image.open(io.BytesIO(contents)) as opened:
            image = ImageOps.exif_transpose(opened).convert("RGB")
            width, height = image.size
            original = io.BytesIO()
            image.save(original, format="JPEG", quality=95, optimize=True)
            thumbnail = image.copy()
            thumbnail.thumbnail((600, 900), Image.Resampling.LANCZOS)
            thumb_data = io.BytesIO()
            thumbnail.save(thumb_data, format="JPEG", quality=84, optimize=True)
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
        raise HTTPException(status_code=400, detail="图片文件无效") from exc
    return original.getvalue(), thumb_data.getvalue(), width, height


@admin_router.post(
    "/plans/{plan_id}/updates",
    dependencies=[Depends(_require_admin)],
)
async def create_plan_update(
    plan_id: int,
    title: str = Query(default="今日更新", max_length=80),
    published_at: str = Query(default="", max_length=40),
    files: list[UploadFile] = File(...),
) -> dict[str, Any]:
    if not files:
        raise HTTPException(status_code=400, detail="请选择图片")
    if len(files) > 30:
        raise HTTPException(status_code=400, detail="单次最多上传30张图片")
    prepared = []
    for upload in files:
        contents = await upload.read(MAX_UPLOAD_BYTES + 1)
        prepared.append(_prepare_image(contents))
    publish_ts = _parse_publish_time(published_at)
    safe_title = _clean_name(title, maximum=80) or "今日更新"
    now = _now_ts()
    written: list[Path] = []
    with closing(_connect()) as conn:
        plan = conn.execute(
            "SELECT id FROM plans WHERE id = ?",
            (plan_id,),
        ).fetchone()
        if plan is None:
            raise HTTPException(status_code=404, detail="计划不存在")
        try:
            cursor = conn.execute(
                """
                INSERT INTO plan_updates(
                    plan_id, title, published_at, is_active, created_at
                ) VALUES (?, ?, ?, 1, ?)
                """,
                (plan_id, safe_title, publish_ts, now),
            )
            update_id = int(cursor.lastrowid)
            for index, (original, thumbnail, width, height) in enumerate(prepared):
                stem = uuid4().hex
                filename = f"{stem}.jpg"
                thumbnail_filename = f"{stem}_thumb.jpg"
                original_path = PLAN_MEDIA_DIR / filename
                thumbnail_path = PLAN_MEDIA_DIR / thumbnail_filename
                original_path.write_bytes(original)
                thumbnail_path.write_bytes(thumbnail)
                written.extend([original_path, thumbnail_path])
                conn.execute(
                    """
                    INSERT INTO plan_images(
                        update_id, filename, thumbnail_filename, position,
                        width, height, is_active, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                    (
                        update_id,
                        filename,
                        thumbnail_filename,
                        index,
                        width,
                        height,
                        now,
                    ),
                )
            conn.execute(
                "UPDATE plans SET updated_at = ? WHERE id = ?",
                (publish_ts, plan_id),
            )
            conn.commit()
        except Exception:
            conn.rollback()
            for path in written:
                path.unlink(missing_ok=True)
            raise
    return {
        "ok": True,
        "updateId": str(update_id),
        "imageCount": len(prepared),
        "publishedAt": _iso_time(publish_ts),
    }


@admin_router.patch(
    "/plan-updates/{update_id}",
    dependencies=[Depends(_require_admin)],
)
def update_plan_update(
    update_id: int,
    body: dict[str, Any] = Body(default={}),
) -> dict[str, Any]:
    if "isActive" not in body:
        raise HTTPException(status_code=400, detail="没有可修改内容")
    with closing(_connect()) as conn:
        cursor = conn.execute(
            "UPDATE plan_updates SET is_active = ? WHERE id = ?",
            (1 if bool(body.get("isActive")) else 0, update_id),
        )
        conn.commit()
    if cursor.rowcount == 0:
        raise HTTPException(status_code=404, detail="更新批次不存在")
    return {"ok": True}


def install_plan_routes(app: FastAPI) -> None:
    _init_store()
    app.mount(
        "/media/plans",
        StaticFiles(directory=PLAN_MEDIA_DIR),
        name="plan_media",
    )
    app.include_router(public_router)
    app.include_router(admin_router)

    @app.get("/admin/plans", response_class=HTMLResponse)
    def plan_admin_page() -> FileResponse:
        if not PLAN_ADMIN_HTML.exists():
            raise HTTPException(status_code=404, detail="管理页面不存在")
        return FileResponse(PLAN_ADMIN_HTML, media_type="text/html")

    @app.get("/privacy", response_class=HTMLResponse, include_in_schema=False)
    def privacy_page() -> FileResponse:
        if not PRIVACY_HTML.exists():
            raise HTTPException(status_code=404, detail="隐私政策页面不存在")
        return FileResponse(PRIVACY_HTML, media_type="text/html")

    @app.get("/support", response_class=HTMLResponse, include_in_schema=False)
    def support_page() -> FileResponse:
        if not SUPPORT_HTML.exists():
            raise HTTPException(status_code=404, detail="支持页面不存在")
        return FileResponse(SUPPORT_HTML, media_type="text/html")
