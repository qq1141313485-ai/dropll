from __future__ import annotations

import fcntl
import gzip
import hashlib
import json
import logging
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from dataclasses import replace
from datetime import datetime, timedelta
from html.parser import HTMLParser
from pathlib import Path
import re
from typing import Any
from uuid import uuid4

from plan_source_common import (
    IGNORE_IMAGE_ASSIGNMENT,
    PlanNameRules,
    SourceError,
    extract_image_urls,
    normalize_plan_name,
    parse_plan_title_info,
)
from plans import (
    CHINA_TZ,
    PLAN_MEDIA_DIR,
    _connect,
    _init_store,
    _prepare_image,
)
from plan_image_classifier import (
    ImageAuthorClassifier,
    OcrProviderUnavailable,
    OcrUsageLimitReached,
    aliyun_general_ocr,
    aliyun_ocr_enabled,
    title_candidates,
)


SOURCE_KIND = os.environ.get("CAIMASTER_PLAN_SOURCE_KIND", "hongxi_json").strip().lower()
SOURCE_NAME = os.environ.get(
    "CAIMASTER_PLAN_SOURCE_NAME",
    "zlwhd" if SOURCE_KIND == "zlwhd_html" else "hongxisaishi",
).strip() or "hongxisaishi"
API_BASE_URL = os.environ.get(
    "CAIMASTER_PLAN_SOURCE_API",
    "https://api.tchongxi.com",
).rstrip("/")
SOURCE_WEB_URL = os.environ.get(
    "CAIMASTER_PLAN_SOURCE_WEB",
    "https://www.zlwhd.com" if SOURCE_KIND == "zlwhd_html" else API_BASE_URL,
).rstrip("/")
MAX_ARTICLES_PER_RUN = max(
    1, int(os.environ.get("CAIMASTER_PLAN_SOURCE_MAX_ARTICLES_PER_RUN", "40"))
)
MAX_PAGES = max(1, int(os.environ.get("CAIMASTER_PLAN_SOURCE_MAX_PAGES", "30")))
LOOKBACK_DAYS = max(
    1,
    int(os.environ.get("CAIMASTER_PLAN_SOURCE_LOOKBACK_DAYS", "2")),
)
QUEUED_RETRY_LIMIT = max(
    1,
    int(os.environ.get("CAIMASTER_PLAN_SOURCE_QUEUED_RETRY_LIMIT", "100")),
)
MAPPING_PATH = Path(
    os.environ.get(
        "CAIMASTER_PLAN_SOURCE_MAP",
        "/opt/caimaster-api/plan_source_map.json",
    )
)
LOCK_PATH = Path(
    os.environ.get(
        "CAIMASTER_PLAN_SOURCE_LOCK",
        "/tmp/caimaster-plan-source-sync.lock",
    )
)
REQUEST_TIMEOUT = float(
    os.environ.get("CAIMASTER_PLAN_SOURCE_TIMEOUT_SECONDS", "20")
)
DRY_RUN = os.environ.get("CAIMASTER_PLAN_SOURCE_DRY_RUN", "0") == "1"
MIRROR_ARTICLES = (
    os.environ.get("CAIMASTER_PLAN_SOURCE_MIRROR_ARTICLES", "0") == "1"
)
MIRROR_BACKFILL_LIMIT = max(
    1,
    int(os.environ.get("CAIMASTER_PLAN_SOURCE_MIRROR_BACKFILL_LIMIT", "10")),
)
MIRROR_SINCE = max(
    0,
    int(os.environ.get("CAIMASTER_PLAN_SOURCE_MIRROR_SINCE", "0")),
)
USER_AGENT = "CaimasterPlanSync/1.0 (+authorized-content-syndication)"
logging.basicConfig(
    level=os.environ.get("CAIMASTER_PLAN_SOURCE_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("plan_source_sync")


class _ArticleLinkParser(HTMLParser):
    """Extract article links from the static zlwhd.com home page."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.items: list[dict[str, str]] = []
        self._href = ""
        self._text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        href = dict(attrs).get("href") or ""
        if re.search(r"/sys-nd/\d+\.html(?:[?#].*)?$", href):
            self._href = urllib.parse.urljoin(SOURCE_WEB_URL + "/", href)
            self._text = []

    def handle_data(self, data: str) -> None:
        if self._href:
            self._text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "a" and self._href:
            title = " ".join("".join(self._text).split())
            match = re.search(r"(\d{4}-\d{2}-\d{2})", title)
            if match:
                title = title.replace(match.group(1), "").strip()
            if title:
                article_id = re.search(r"/sys-nd/(\d+)\.html", self._href)
                if article_id:
                    self.items.append(
                        {
                            "id": article_id.group(1),
                            "title": title,
                            "detail_url": self._href,
                            "date_text": match.group(1) if match else "",
                        }
                    )
            self._href = ""
            self._text = []


def _decode_zlwhd_news_info(raw: bytes) -> dict[str, Any]:
    """Read the embedded newsInfo object emitted by the site builder."""
    text = raw.decode("utf-8", errors="replace")
    marker = '"newsInfo":'
    start = text.find(marker)
    if start < 0:
        raise SourceError("zlwhd article has no newsInfo metadata")
    try:
        info, _ = json.JSONDecoder().raw_decode(text[start + len(marker):])
    except json.JSONDecodeError as exc:
        raise SourceError("invalid zlwhd article metadata") from exc
    if not isinstance(info, dict):
        raise SourceError("invalid zlwhd newsInfo metadata")
    # zlwhd stores publication time as JavaScript milliseconds.
    if not info.get("publishtime") and info.get("date"):
        try:
            info["publishtime"] = int(info["date"]) // 1000
        except (TypeError, ValueError):
            pass
    return info


def _zlwhd_title(title: str, published_at: int = 0) -> str:
    """Convert the site's MMDD title to the full date format used by the app."""
    value = " ".join(str(title or "").split())
    if re.match(r"^\d{8}", value):
        return value
    mmdd = re.match(r"^(\d{2})(\d{2})(.*)$", value)
    if not mmdd:
        return value
    year = datetime.fromtimestamp(published_at, CHINA_TZ).year if published_at else datetime.now(CHINA_TZ).year
    return f"{year}{mmdd.group(1)}{mmdd.group(2)}{mmdd.group(3)}"


def _init_sync_store() -> None:
    with closing(_connect()) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS plan_sync_articles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL,
                source_title TEXT NOT NULL,
                raw_plan_name TEXT NOT NULL DEFAULT '',
                resolved_plan_name TEXT NOT NULL DEFAULT '',
                plan_id INTEGER,
                update_id INTEGER,
                published_at INTEGER,
                status TEXT NOT NULL,
                error TEXT NOT NULL DEFAULT '',
                needs_review INTEGER NOT NULL DEFAULT 0,
                synced_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id)
            );
            CREATE TABLE IF NOT EXISTS plan_sync_images (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL,
                source_url TEXT NOT NULL,
                content_sha256 TEXT NOT NULL,
                image_id INTEGER NOT NULL,
                synced_at INTEGER NOT NULL,
                UNIQUE(source_name, source_url),
                UNIQUE(source_name, content_sha256)
            );
            CREATE TABLE IF NOT EXISTS plan_sync_article_updates (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL,
                plan_name TEXT NOT NULL,
                plan_id INTEGER NOT NULL,
                update_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id, update_id)
            );
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
            CREATE TABLE IF NOT EXISTS plan_ocr_results (
                content_sha256 TEXT PRIMARY KEY,
                source_url TEXT NOT NULL,
                provider TEXT NOT NULL,
                text TEXT NOT NULL,
                confidence REAL NOT NULL,
                raw_json TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS plan_ocr_decisions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL,
                source_url TEXT NOT NULL,
                content_sha256 TEXT NOT NULL,
                candidates_json TEXT NOT NULL DEFAULT '[]',
                matched_plan_name TEXT,
                confidence REAL NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                reason TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id, source_url)
            );
            CREATE TABLE IF NOT EXISTS plan_ocr_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content_sha256 TEXT NOT NULL,
                source_url TEXT NOT NULL,
                attempted_at INTEGER NOT NULL,
                outcome TEXT NOT NULL DEFAULT 'started'
            );
            CREATE INDEX IF NOT EXISTS idx_plan_ocr_usage_attempted
                ON plan_ocr_usage(attempted_at);
            CREATE INDEX IF NOT EXISTS idx_plan_sync_articles_status
                ON plan_sync_articles(source_name, status, source_article_id);
            CREATE INDEX IF NOT EXISTS idx_plan_sync_runs_source_time
                ON plan_sync_runs(source_name, started_at DESC);
            """
        )
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


def _start_sync_run() -> int:
    now = int(time.time())
    with closing(_connect()) as conn:
        cursor = conn.execute(
            """
            INSERT INTO plan_sync_runs(source_name, started_at, status)
            VALUES (?, ?, 'running')
            """,
            (SOURCE_NAME, now),
        )
        conn.commit()
    return int(cursor.lastrowid)


def _finish_sync_run(
    run_id: int,
    *,
    status: str,
    candidates: int,
    counts: dict[str, int],
    error: str = "",
) -> None:
    with closing(_connect()) as conn:
        conn.execute(
            """
            UPDATE plan_sync_runs
            SET finished_at = ?,
                status = ?,
                candidates = ?,
                counts_json = ?,
                error = ?
            WHERE id = ?
            """,
            (
                int(time.time()),
                status,
                candidates,
                json.dumps(counts, ensure_ascii=False, sort_keys=True),
                error[:500],
                run_id,
            ),
        )
        conn.commit()


def _request(
    url: str,
    *,
    data: bytes | None = None,
    content_type: str | None = None,
) -> bytes:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/json,image/*;q=0.9,*/*;q=0.5",
    }
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=data, headers=headers)
    last_error: Exception | None = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                if response.status != 200:
                    raise SourceError(f"HTTP {response.status}: {url}")
                contents = response.read(15 * 1024 * 1024 + 1)
                if response.headers.get("Content-Encoding", "").lower() == "gzip":
                    contents = gzip.decompress(contents)
                return contents
        except (urllib.error.URLError, TimeoutError, SourceError) as exc:
            last_error = exc
            if attempt < 3:
                time.sleep(2**attempt)
    raise SourceError(f"request failed: {url}: {last_error}")


def _request_json(
    path: str,
    *,
    query: dict[str, Any] | None = None,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    url = f"{API_BASE_URL}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    payload = None
    content_type = None
    if body is not None:
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        content_type = "application/json"
    raw = _request(url, data=payload, content_type=content_type)
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SourceError(f"invalid JSON: {url}") from exc
    if not isinstance(decoded, dict) or decoded.get("code") != 1:
        raise SourceError(f"source rejected request: {decoded.get('msg', '')}")
    return decoded


def _load_name_rules() -> PlanNameRules:
    if not MAPPING_PATH.exists():
        return PlanNameRules.from_mapping({})
    try:
        raw = json.loads(MAPPING_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceError(f"invalid mapping file: {MAPPING_PATH}") from exc
    return PlanNameRules.from_mapping(raw)


def _fetch_queued_articles() -> dict[str, dict[str, Any]]:
    with closing(_connect()) as conn:
        rows = conn.execute(
            """
            SELECT source_article_id, source_title, published_at
            FROM plan_sync_articles
            WHERE source_name = ?
              AND status IN ('name_configured', 'retry_queued')
            ORDER BY synced_at, id
            LIMIT ?
            """,
            (SOURCE_NAME, QUEUED_RETRY_LIMIT),
        ).fetchall()
    return {
        str(row["source_article_id"]): {
            "id": row["source_article_id"],
            "title": row["source_title"],
            "publishtime": int(row["published_at"] or 0),
        }
        for row in rows
    }


def _fetch_mirror_backlog() -> dict[str, dict[str, Any]]:
    if MIRROR_SINCE <= 0:
        return {}
    with closing(_connect()) as conn:
        rows = conn.execute(
            """
            SELECT sync.source_article_id, sync.source_title,
                   sync.published_at
            FROM plan_sync_articles sync
            LEFT JOIN plan_articles article
              ON article.source_name = sync.source_name
             AND article.source_article_id = sync.source_article_id
            WHERE sync.source_name = ?
              AND sync.status != 'ignored'
              AND sync.published_at >= ?
              AND article.id IS NULL
            ORDER BY sync.published_at DESC, sync.id DESC
            LIMIT ?
            """,
            (SOURCE_NAME, MIRROR_SINCE, MIRROR_BACKFILL_LIMIT),
        ).fetchall()
    return {
        str(row["source_article_id"]): {
            "id": row["source_article_id"],
            "title": row["source_title"],
            "publishtime": int(row["published_at"] or 0),
        }
        for row in rows
    }


def _fetch_articles(*, use_sync_store: bool = True) -> list[dict[str, Any]]:
    cutoff = datetime.now(CHINA_TZ) - timedelta(days=LOOKBACK_DAYS - 1)
    cutoff = cutoff.replace(hour=0, minute=0, second=0, microsecond=0)
    imported_ids: set[str] = set()
    collected: dict[str, dict[str, Any]] = {}
    if use_sync_store:
        with closing(_connect()) as conn:
            statuses = (
                ("ignored",)
                if MIRROR_ARTICLES
                else ("imported", "duplicate", "ignored", "pending_name")
            )
            placeholders = ",".join("?" for _ in statuses)
            imported_ids = {
                row[0]
                for row in conn.execute(
                    f"""
                    SELECT source_article_id FROM plan_sync_articles
                    WHERE source_name = ?
                      AND status IN ({placeholders})
                    """,
                    (SOURCE_NAME, *statuses),
                )
            }
        collected = (
            _fetch_mirror_backlog()
            if MIRROR_ARTICLES
            else _fetch_queued_articles()
        )
    queued_count = len(collected)
    if SOURCE_KIND == "zlwhd_html":
        raw = _request(SOURCE_WEB_URL + "/")
        parser = _ArticleLinkParser()
        parser.feed(raw.decode("utf-8", errors="replace"))
        for item in parser.items:
            title = item["title"]
            # The source site mixes football and basketball recommendations.
            if "篮球" in title:
                continue
            published_ts = 0
            if item.get("date_text"):
                try:
                    published_ts = int(
                        datetime.strptime(item["date_text"], "%Y-%m-%d")
                        .replace(tzinfo=CHINA_TZ)
                        .timestamp()
                    )
                except ValueError:
                    published_ts = 0
            if published_ts and datetime.fromtimestamp(published_ts, CHINA_TZ) < cutoff:
                continue
            if item["id"] in imported_ids:
                continue
            item["publishtime"] = published_ts
            item["title"] = _zlwhd_title(title, published_ts)
            collected[item["id"]] = item
        # Process the newest batch first; subsequent timer runs continue the backlog.
        candidates = sorted(
            collected.values(),
            key=lambda item: int(item.get("publishtime") or 0),
            reverse=True,
        )[:MAX_ARTICLES_PER_RUN]
        return sorted(
            candidates,
            key=lambda item: int(item.get("publishtime") or 0),
        )
    old_streak = 0
    encountered_imported = False
    for page in range(1, MAX_PAGES + 1):
        response = _request_json(
            "/addons/cms/api.archives/index",
            query={"page": page, "channel": -1, "model": -1},
        )
        data = response.get("data") or {}
        page_list = data.get("pageList") or {}
        items = page_list.get("data") or []
        if not isinstance(items, list) or not items:
            break
        for item in items:
            if not isinstance(item, dict):
                continue
            article_id = str(item.get("id") or "").strip()
            if not article_id:
                continue
            if article_id in imported_ids:
                encountered_imported = True
                continue
            published_ts = int(item.get("publishtime") or item.get("createtime") or 0)
            if MIRROR_ARTICLES and (
                published_ts <= 0 or published_ts < MIRROR_SINCE
            ):
                old_streak += 1
                continue
            if published_ts and datetime.fromtimestamp(published_ts, CHINA_TZ) < cutoff:
                old_streak += 1
                continue
            old_streak = 0
            collected[article_id] = item
        if encountered_imported or old_streak >= 20:
            break
    if queued_count:
        logger.info("queued configured articles=%s", queued_count)
    return sorted(
        collected.values(),
        key=lambda item: int(item.get("publishtime") or item.get("createtime") or 0),
    )


def _record_article(
    article: dict[str, Any],
    *,
    status: str,
    error: str = "",
    raw_plan_name: str = "",
    resolved_plan_name: str = "",
    needs_review: bool = False,
    plan_id: int | None = None,
    update_id: int | None = None,
) -> None:
    now = int(time.time())
    article_id = str(article.get("id") or "")
    published_at = int(article.get("publishtime") or article.get("createtime") or 0)
    with closing(_connect()) as conn:
        conn.execute(
            """
            INSERT INTO plan_sync_articles(
                source_name, source_article_id, source_title, raw_plan_name,
                resolved_plan_name, plan_id, update_id, published_at, status,
                error, needs_review, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_name, source_article_id) DO UPDATE SET
                source_title = excluded.source_title,
                raw_plan_name = excluded.raw_plan_name,
                resolved_plan_name = excluded.resolved_plan_name,
                plan_id = COALESCE(
                    excluded.plan_id, plan_sync_articles.plan_id
                ),
                update_id = COALESCE(
                    excluded.update_id, plan_sync_articles.update_id
                ),
                published_at = excluded.published_at,
                status = excluded.status,
                error = excluded.error,
                needs_review = excluded.needs_review,
                synced_at = excluded.synced_at
            """,
            (
                SOURCE_NAME,
                article_id,
                str(article.get("title") or "")[:200],
                raw_plan_name[:60],
                resolved_plan_name[:60],
                plan_id,
                update_id,
                published_at,
                status,
                error[:500],
                1 if needs_review else 0,
                now,
            ),
        )
        conn.commit()


def _find_or_create_plan(conn: sqlite3.Connection, name: str, now: int) -> int:
    existing = conn.execute(
        """
        SELECT COALESCE(a.canonical_plan_id, p.id) AS id
        FROM plans p
        LEFT JOIN plan_aliases a ON a.alias_plan_id = p.id
        WHERE p.name = ?
        ORDER BY p.id
        LIMIT 1
        """,
        (name,),
    ).fetchone()
    if existing is not None:
        return int(existing["id"])
    slug = f"source-{hashlib.sha1(name.encode('utf-8')).hexdigest()[:16]}"
    cursor = conn.execute(
        """
        INSERT INTO plans(
            slug, name, uploader_name, is_active, created_at, updated_at
        ) VALUES (?, ?, '球镜助手', 1, ?, ?)
        """,
        (slug, name, now, now),
    )
    return int(cursor.lastrowid)


def _new_image_urls(image_urls: list[str]) -> list[str]:
    if not image_urls:
        return []
    placeholders = ",".join("?" for _ in image_urls)
    with closing(_connect()) as conn:
        existing = {
            row["source_url"]
            for row in conn.execute(
                f"""
                SELECT source_url FROM plan_sync_images
                WHERE source_name = ? AND source_url IN ({placeholders})
                """,
                (SOURCE_NAME, *image_urls),
            )
        }
    return [url for url in image_urls if url not in existing]


def _article_archive(article: dict[str, Any]) -> dict[str, Any]:
    if SOURCE_KIND == "zlwhd_html":
        detail_url = str(article.get("detail_url") or "").strip()
        if not detail_url:
            detail_url = f"{SOURCE_WEB_URL}/sys-nd/{article.get('id')}.html"
        raw = _request(detail_url)
        return _decode_zlwhd_news_info(raw)
    article_id = str(article.get("id") or "").strip()
    detail = _request_json(
        "/addons/cms/api.archives/detail",
        body={"id": int(article_id)},
    )
    return ((detail.get("data") or {}).get("archivesInfo") or {})


def _article_image_urls(
    article: dict[str, Any],
    archive: dict[str, Any],
) -> list[str]:
    if SOURCE_KIND == "zlwhd_html":
        content = archive.get("richContent")
        image_urls = extract_image_urls(content, SOURCE_WEB_URL)
        if image_urls:
            return image_urls
    image_urls = extract_image_urls(archive.get("content"), API_BASE_URL)
    if not image_urls:
        fallback = str(archive.get("image") or article.get("image") or "").strip()
        fallback = fallback.split("?", 1)[0]
        if fallback.startswith("https://"):
            image_urls = [fallback]
    return image_urls


def _image_plan_names(
    parsed: Any,
    image_urls: list[str],
) -> list[str]:
    assignments = list(parsed.image_plan_names)
    if not assignments:
        return [parsed.name] * len(image_urls)
    if len(assignments) != len(image_urls):
        raise SourceError(
            "image assignment awaits review: "
            f"{parsed.raw_name} "
            f"(expected {len(assignments)} images, got {len(image_urls)})"
        )
    return assignments


def _permissive_rules(rules: PlanNameRules) -> PlanNameRules:
    return PlanNameRules(
        aliases=rules.aliases,
        image_assignments={},
        allowed_names=rules.allowed_names,
        ignored_names=rules.ignored_names,
        excluded_title_words=rules.excluded_title_words,
        allow_auto_create=True,
    )


def _ocr_image_plan_names(
    article: dict[str, Any],
    rules: PlanNameRules,
    raw_name: str,
    image_urls: list[str],
) -> tuple[list[str], dict[str, bytes]]:
    if not aliyun_ocr_enabled():
        raise SourceError(f"plan name awaits mapping: {raw_name}")
    candidates = title_candidates(raw_name, rules)
    if not candidates:
        raise SourceError(f"plan OCR has no known author candidates: {raw_name}")
    contents_by_url: dict[str, bytes] = {}
    decisions = []
    with closing(_connect()) as conn:
        classifier = ImageAuthorClassifier(conn, rules, aliyun_general_ocr)
        for image_url in image_urls:
            contents = _request(image_url)
            contents_by_url[image_url] = contents
            try:
                decisions.append(
                    classifier.classify(
                        article_id=str(article.get("id") or ""),
                        source_url=image_url,
                        contents=contents,
                        candidates=candidates,
                    )
                )
            except OcrUsageLimitReached as exc:
                raise SourceError(f"plan OCR usage limit reached: {exc}") from exc
            except OcrProviderUnavailable as exc:
                raise SourceError(f"plan OCR unavailable: {exc}") from exc
        conn.commit()
    unresolved = [decision for decision in decisions if decision.plan_name is None]
    if unresolved:
        reasons = ",".join(sorted({decision.reason for decision in unresolved}))
        raise SourceError(
            f"plan OCR awaits review: {raw_name} "
            f"({len(unresolved)}/{len(decisions)} unresolved: {reasons})"
        )
    return [str(decision.plan_name) for decision in decisions], contents_by_url


def _sync_article(article: dict[str, Any], rules: PlanNameRules) -> str:
    article_id = str(article.get("id") or "").strip()
    mapping_error: SourceError | None = None
    try:
        parsed = parse_plan_title_info(article.get("title"), rules)
    except SourceError as exc:
        if not str(exc).startswith("plan name awaits mapping"):
            raise
        mapping_error = exc
        parsed = parse_plan_title_info(
            article.get("title"),
            _permissive_rules(rules),
        )
    archive = _article_archive(article)
    image_urls = _article_image_urls(article, archive)
    if not image_urls:
        raise SourceError("article has no downloadable images")

    image_urls = image_urls[:30]
    downloaded_contents: dict[str, bytes] = {}
    if mapping_error is None:
        image_plan_names = _image_plan_names(parsed, image_urls)
    else:
        image_plan_names, downloaded_contents = _ocr_image_plan_names(
            article,
            rules,
            parsed.raw_name,
            image_urls,
        )
        parsed = replace(
            parsed,
            name=image_plan_names[0],
            needs_review=False,
            image_plan_names=tuple(image_plan_names),
        )
    title_date = parsed.published_date
    eligible_urls = [
        image_url
        for image_url, plan_name in zip(image_urls, image_plan_names)
        if plan_name != IGNORE_IMAGE_ASSIGNMENT
    ]
    new_urls = set(_new_image_urls(eligible_urls))
    if not new_urls:
        _record_article(
            article,
            status="duplicate",
            raw_plan_name=parsed.raw_name,
            resolved_plan_name=parsed.name,
            needs_review=parsed.needs_review,
        )
        return "duplicate"

    downloaded = []
    for image_url, plan_name in zip(image_urls, image_plan_names):
        if plan_name == IGNORE_IMAGE_ASSIGNMENT:
            continue
        if image_url not in new_urls:
            continue
        contents = downloaded_contents.get(image_url)
        if contents is None:
            contents = _request(image_url)
        digest = hashlib.sha256(contents).hexdigest()
        original, thumbnail, width, height = _prepare_image(contents)
        downloaded.append(
            (
                image_url,
                digest,
                original,
                thumbnail,
                width,
                height,
                plan_name,
            )
        )

    now = int(time.time())
    published_at = int(
        archive.get("publishtime")
        or article.get("publishtime")
        or title_date.timestamp()
    )
    written: list[Path] = []
    with closing(_connect()) as conn:
        try:
            fresh = []
            for image in downloaded:
                duplicate = conn.execute(
                    """
                    SELECT 1 FROM plan_sync_images
                    WHERE source_name = ?
                      AND (source_url = ? OR content_sha256 = ?)
                    LIMIT 1
                    """,
                    (SOURCE_NAME, image[0], image[1]),
                ).fetchone()
                if duplicate is None:
                    fresh.append(image)
            if not fresh:
                conn.rollback()
                _record_article(
                    article,
                    status="duplicate",
                    raw_plan_name=parsed.raw_name,
                    resolved_plan_name=parsed.name,
                    needs_review=parsed.needs_review,
                )
                return "duplicate"

            grouped: dict[str, list[tuple[Any, ...]]] = {}
            for image in fresh:
                grouped.setdefault(str(image[6]), []).append(image)

            imported_targets: list[tuple[str, int, int]] = []
            for target_name, target_images in grouped.items():
                target_plan_id = _find_or_create_plan(
                    conn,
                    target_name,
                    now,
                )
                cursor = conn.execute(
                    """
                    INSERT INTO plan_updates(
                        plan_id, title, published_at, is_active, created_at
                    ) VALUES (?, ?, ?, 1, ?)
                    """,
                    (
                        target_plan_id,
                        str(article.get("title") or "今日更新")[:80],
                        published_at,
                        now,
                    ),
                )
                target_update_id = int(cursor.lastrowid)
                imported_targets.append(
                    (target_name, target_plan_id, target_update_id)
                )
                for position, image in enumerate(target_images):
                    (
                        source_url,
                        digest,
                        original,
                        thumbnail,
                        width,
                        height,
                        _,
                    ) = image
                    stem = uuid4().hex
                    filename = f"{stem}.jpg"
                    thumbnail_filename = f"{stem}_thumb.jpg"
                    original_path = PLAN_MEDIA_DIR / filename
                    thumbnail_path = PLAN_MEDIA_DIR / thumbnail_filename
                    original_path.write_bytes(original)
                    thumbnail_path.write_bytes(thumbnail)
                    written.extend((original_path, thumbnail_path))
                    image_cursor = conn.execute(
                        """
                        INSERT INTO plan_images(
                            update_id, filename, thumbnail_filename, position,
                            width, height, is_active, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                        """,
                        (
                            target_update_id,
                            filename,
                            thumbnail_filename,
                            position,
                            width,
                            height,
                            now,
                        ),
                    )
                    conn.execute(
                        """
                        INSERT INTO plan_sync_images(
                            source_name, source_article_id, source_url,
                            content_sha256, image_id, synced_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (
                            SOURCE_NAME,
                            article_id,
                            source_url,
                            digest,
                            int(image_cursor.lastrowid),
                            now,
                        ),
                    )
                conn.execute(
                    """
                    INSERT INTO plan_sync_article_updates(
                        source_name, source_article_id, plan_name,
                        plan_id, update_id, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        SOURCE_NAME,
                        article_id,
                        target_name,
                        target_plan_id,
                        target_update_id,
                        now,
                    ),
                )
                conn.execute(
                    """
                    UPDATE plans SET updated_at = ?, is_active = 1
                    WHERE id = ?
                    """,
                    (published_at, target_plan_id),
                )

            plan_id = imported_targets[0][1]
            update_id = imported_targets[0][2]
            conn.execute(
                """
                INSERT INTO plan_sync_articles(
                    source_name, source_article_id, source_title, plan_id,
                    update_id, published_at, status, error, raw_plan_name,
                    resolved_plan_name, needs_review, synced_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'imported', '', ?, ?, ?, ?)
                ON CONFLICT(source_name, source_article_id) DO UPDATE SET
                    source_title = excluded.source_title,
                    plan_id = excluded.plan_id,
                    update_id = excluded.update_id,
                    published_at = excluded.published_at,
                    status = 'imported',
                    error = '',
                    raw_plan_name = excluded.raw_plan_name,
                    resolved_plan_name = excluded.resolved_plan_name,
                    needs_review = excluded.needs_review,
                    synced_at = excluded.synced_at
                """,
                (
                    SOURCE_NAME,
                    article_id,
                    str(article.get("title") or "")[:200],
                    plan_id,
                    update_id,
                    published_at,
                    parsed.raw_name,
                    parsed.name,
                    1 if parsed.needs_review else 0,
                    now,
                ),
            )
            conn.commit()
        except Exception:
            conn.rollback()
            for path in written:
                path.unlink(missing_ok=True)
            raise
    return "imported"


def _sync_article_mirror(
    article: dict[str, Any],
    rules: PlanNameRules,
) -> str:
    """Save one source article as one ordered, versioned collection."""
    article_id = str(article.get("id") or "").strip()
    if not article_id:
        raise SourceError("article has no source id")
    source_title = " ".join(str(article.get("title") or "").strip().split())
    parsed = parse_plan_title_info(source_title, _permissive_rules(rules))
    archive = _article_archive(article)
    image_urls = _article_image_urls(article, archive)[:30]
    if not image_urls:
        raise SourceError("article has no downloadable images")

    prepared = []
    version_fingerprint = hashlib.sha256()
    version_fingerprint.update(source_title.encode("utf-8"))
    for position, source_url in enumerate(image_urls):
        contents = _request(source_url)
        content_sha256 = hashlib.sha256(contents).hexdigest()
        version_fingerprint.update(b"\0")
        version_fingerprint.update(source_url.encode("utf-8"))
        version_fingerprint.update(b"\0")
        version_fingerprint.update(content_sha256.encode("ascii"))
        original, thumbnail, width, height = _prepare_image(contents)
        prepared.append(
            (
                position,
                source_url,
                content_sha256,
                original,
                thumbnail,
                width,
                height,
            )
        )
    content_sha256 = version_fingerprint.hexdigest()
    published_at = int(
        archive.get("publishtime")
        or article.get("publishtime")
        or article.get("createtime")
        or parsed.published_date.timestamp()
    )
    now = int(time.time())

    with closing(_connect()) as conn:
        existing = conn.execute(
            """
            SELECT article.id FROM plan_articles article
            JOIN plan_article_versions version
              ON version.article_id = article.id
            WHERE article.source_name = ?
              AND article.source_article_id = ?
              AND version.content_sha256 = ?
            LIMIT 1
            """,
            (SOURCE_NAME, article_id, content_sha256),
        ).fetchone()
    if existing is not None:
        _record_article(
            article,
            status="mirrored",
            raw_plan_name=parsed.raw_name,
        )
        return "duplicate"

    written: list[Path] = []
    with closing(_connect()) as conn:
        try:
            conn.execute(
                """
                INSERT INTO plan_articles(
                    source_name, source_article_id, title, published_at,
                    is_active, created_at, updated_at
                ) VALUES (?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(source_name, source_article_id) DO UPDATE SET
                    title = excluded.title,
                    published_at = excluded.published_at,
                    is_active = 1,
                    updated_at = excluded.updated_at
                """,
                (
                    SOURCE_NAME,
                    article_id,
                    source_title[:200],
                    published_at,
                    now,
                    now,
                ),
            )
            article_row = conn.execute(
                """
                SELECT id FROM plan_articles
                WHERE source_name = ? AND source_article_id = ?
                """,
                (SOURCE_NAME, article_id),
            ).fetchone()
            if article_row is None:
                raise RuntimeError("mirrored article was not created")
            cursor = conn.execute(
                """
                INSERT INTO plan_article_versions(
                    article_id, content_sha256, title, published_at,
                    captured_at, is_active
                ) VALUES (?, ?, ?, ?, ?, 1)
                """,
                (
                    int(article_row["id"]),
                    content_sha256,
                    source_title[:200],
                    published_at,
                    now,
                ),
            )
            version_id = int(cursor.lastrowid)
            for (
                position,
                source_url,
                image_sha256,
                original,
                thumbnail,
                width,
                height,
            ) in prepared:
                stem = uuid4().hex
                filename = f"{stem}.jpg"
                thumbnail_filename = f"{stem}_thumb.jpg"
                original_path = PLAN_MEDIA_DIR / filename
                thumbnail_path = PLAN_MEDIA_DIR / thumbnail_filename
                original_path.write_bytes(original)
                thumbnail_path.write_bytes(thumbnail)
                written.extend((original_path, thumbnail_path))
                conn.execute(
                    """
                    INSERT INTO plan_article_images(
                        version_id, filename, thumbnail_filename, source_url,
                        content_sha256, position, width, height, is_active,
                        created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                    (
                        version_id,
                        filename,
                        thumbnail_filename,
                        source_url,
                        image_sha256,
                        position,
                        width,
                        height,
                        now,
                    ),
                )
            conn.commit()
        except Exception:
            conn.rollback()
            for path in written:
                path.unlink(missing_ok=True)
            raise
    _record_article(
        article,
        status="mirrored",
        raw_plan_name=parsed.raw_name,
    )
    return "imported"


def _status_for_source_error(message: str) -> str:
    if message.startswith(
        (
            "plan name awaits mapping",
            "image assignment awaits review",
            "plan OCR has no known author candidates",
            "plan OCR awaits review",
            "plan OCR usage limit reached",
            "plan OCR unavailable",
        )
    ):
        return "pending_name"
    if message.startswith(("excluded", "title", "ignored")):
        return "ignored"
    return "failed"


def _pending_raw_plan_name(
    message: str,
    article: dict[str, Any],
    rules: PlanNameRules,
) -> str:
    prefixes = (
        "plan name awaits mapping:",
        "image assignment awaits review:",
        "plan OCR has no known author candidates:",
        "plan OCR awaits review:",
    )
    for prefix in prefixes:
        if message.startswith(prefix):
            candidate = message[len(prefix) :].split(" (", 1)[0]
            if candidate.strip():
                return normalize_plan_name(candidate)
    try:
        return parse_plan_title_info(
            article.get("title"),
            _permissive_rules(rules),
        ).raw_name
    except SourceError:
        return ""


def _run_dry_run() -> int:
    rules = _load_name_rules()
    articles = _fetch_articles(use_sync_store=False)
    counts = {
        "valid": 0,
        "failed": 0,
        "ignored": 0,
        "pending_name": 0,
    }
    for article in articles:
        article_id = str(article.get("id") or "")
        try:
            parsed = parse_plan_title_info(
                article.get("title"),
                _permissive_rules(rules) if MIRROR_ARTICLES else rules,
            )
            archive = _article_archive(article)
            image_urls = _article_image_urls(article, archive)
            if not image_urls:
                raise SourceError("article has no downloadable images")
            image_plan_names = (
                ["原文合集"] * len(image_urls[:30])
                if MIRROR_ARTICLES
                else _image_plan_names(parsed, image_urls[:30])
            )
            counts["valid"] += 1
            logger.info(
                "dry-run article=%s raw_name=%s resolved_name=%s "
                "images=%s targets=%s needs_review=%s",
                article_id,
                parsed.raw_name,
                parsed.name,
                len(image_urls),
                len(set(image_plan_names)),
                parsed.needs_review,
            )
        except SourceError as exc:
            status = _status_for_source_error(str(exc))
            counts[status] += 1
            logger.warning("dry-run article=%s status=%s error=%s", article_id, status, exc)
        except Exception as exc:
            counts["failed"] += 1
            logger.exception("dry-run article=%s failed", article_id)
    logger.info("dry-run complete candidates=%s counts=%s", len(articles), counts)
    return 0 if counts["failed"] == 0 else 1


def run() -> int:
    if MIRROR_ARTICLES and MIRROR_SINCE <= 0:
        logger.error(
            "article mirror requires CAIMASTER_PLAN_SOURCE_MIRROR_SINCE; "
            "refusing unbounded historical migration"
        )
        return 1
    if DRY_RUN:
        return _run_dry_run()
    if os.environ.get("CAIMASTER_PLAN_SOURCE_ENABLED", "0") != "1":
        logger.info("source sync disabled")
        return 0
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            logger.info("another sync is already running")
            return 0
        _init_store()
        _init_sync_store()
        run_id = _start_sync_run()
        counts = {
            "imported": 0,
            "duplicate": 0,
            "failed": 0,
            "ignored": 0,
            "pending_name": 0,
            "retry_queued": 0,
        }
        candidate_count = 0
        try:
            rules = _load_name_rules()
            articles = _fetch_articles()
            candidate_count = len(articles)
            for article in articles:
                article_id = str(article.get("id") or "")
                try:
                    outcome = (
                        _sync_article_mirror(article, rules)
                        if MIRROR_ARTICLES
                        else _sync_article(article, rules)
                    )
                    counts[outcome] += 1
                except SourceError as exc:
                    message = str(exc)
                    status = _status_for_source_error(message)
                    counts[status] += 1
                    raw_plan_name = ""
                    if status == "pending_name":
                        raw_plan_name = _pending_raw_plan_name(
                            message,
                            article,
                            rules,
                        )
                    _record_article(
                        article,
                        status=status,
                        error=message,
                        raw_plan_name=raw_plan_name,
                        needs_review=status == "pending_name",
                    )
                    logger.warning(
                        "article=%s status=%s error=%s",
                        article_id,
                        status,
                        exc,
                    )
                except Exception as exc:
                    counts["failed"] += 1
                    _record_article(
                        article,
                        status="failed",
                        error=f"{type(exc).__name__}: {exc}",
                    )
                    logger.exception("article=%s failed", article_id)
            logger.info("sync complete candidates=%s counts=%s", len(articles), counts)
            run_status = "failed" if counts["failed"] else "ok"
            _finish_sync_run(
                run_id,
                status=run_status,
                candidates=candidate_count,
                counts=counts,
            )
            return 0 if counts["failed"] == 0 else 1
        except Exception as exc:
            logger.exception("sync run failed")
            _finish_sync_run(
                run_id,
                status="failed",
                candidates=candidate_count,
                counts=counts,
                error=f"{type(exc).__name__}: {exc}",
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(run())
