from __future__ import annotations

import hashlib
import io
import json
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Iterable

from plan_source_common import CHINA_TZ, PlanNameRules, normalize_plan_name


DESCRIPTORS = (
    "上午场", "下午场", "早场", "晚场", "半全场", "进球数",
    "高赔", "中赔", "低配", "单关", "系列", "早单", "晚单",
    "夜场", "早", "晚", "2.0", "3.0",
)
_SEPARATOR = re.compile(r"[,，、+＋&＆|/／;；\s]+")
_NOISE = re.compile(r"[\s_\-—:：·,，、。.!！?？()（）\[\]【】]+")


@dataclass(frozen=True)
class OcrText:
    text: str
    confidence: float
    raw: dict[str, Any]


@dataclass(frozen=True)
class ImageClassification:
    plan_name: str | None
    confidence: float
    status: str
    reason: str
    ocr_text: str


class OcrUsageLimitReached(RuntimeError):
    pass


class OcrProviderUnavailable(RuntimeError):
    """The configured OCR provider cannot currently process requests."""


def _reserve_ocr_call(
    conn: sqlite3.Connection,
    *,
    content_sha256: str,
    source_url: str,
) -> int:
    limit = max(0, int(os.environ.get("CAIMASTER_PLAN_OCR_MONTHLY_LIMIT", "180")))
    daily_limit = max(
        0,
        int(os.environ.get("CAIMASTER_PLAN_OCR_DAILY_LIMIT", "6")),
    )
    now = datetime.now(CHINA_TZ)
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if now.month == 12:
        next_month = month_start.replace(year=now.year + 1, month=1)
    else:
        next_month = month_start.replace(month=now.month + 1)
    used = int(
        conn.execute(
            """
            SELECT COUNT(*) FROM plan_ocr_usage
            WHERE attempted_at >= ? AND attempted_at < ?
            """,
            (int(month_start.timestamp()), int(next_month.timestamp())),
        ).fetchone()[0]
    )
    used_today = int(
        conn.execute(
            "SELECT COUNT(*) FROM plan_ocr_usage WHERE attempted_at >= ?",
            (int(day_start.timestamp()),),
        ).fetchone()[0]
    )
    if used_today >= daily_limit:
        raise OcrUsageLimitReached(
            f"daily OCR limit reached ({used_today}/{daily_limit})"
        )
    if used >= limit:
        raise OcrUsageLimitReached(
            f"monthly OCR limit reached ({used}/{limit})"
        )
    cursor = conn.execute(
        """
        INSERT INTO plan_ocr_usage(
            content_sha256, source_url, attempted_at, outcome
        ) VALUES (?, ?, ?, 'started')
        """,
        (content_sha256, source_url, int(time.time())),
    )
    conn.commit()
    return int(cursor.lastrowid)


def _compact(value: str) -> str:
    return _NOISE.sub("", str(value or "")).lower()


def _without_descriptors(value: str) -> str:
    result = normalize_plan_name(value)
    changed = True
    while changed:
        changed = False
        for word in DESCRIPTORS:
            if result.endswith(word) and len(result) > len(word):
                result = normalize_plan_name(result[: -len(word)])
                changed = True
                break
    return result


def title_candidates(raw_name: str, rules: PlanNameRules) -> tuple[str, ...]:
    """Extract canonical authors without assuming an image sequence."""
    candidates: list[str] = []
    known = sorted(
        rules.allowed_names | frozenset(rules.aliases.values()),
        key=len,
        reverse=True,
    )
    for part in _SEPARATOR.split(normalize_plan_name(raw_name)):
        part = normalize_plan_name(part)
        if not part:
            continue
        mapped = rules.aliases.get(part)
        if mapped:
            candidates.append(mapped)
            continue
        stripped = _without_descriptors(part)
        mapped = rules.aliases.get(stripped, stripped)
        if mapped in rules.allowed_names:
            candidates.append(mapped)
            continue
        compact_part = _compact(part)
        contained = [
            name for name in known
            if len(_compact(name)) >= 2 and _compact(name) in compact_part
        ]
        if len(contained) == 1:
            candidates.append(contained[0])
    return tuple(dict.fromkeys(candidates))


def classify_ocr_text(
    ocr: OcrText,
    candidates: Iterable[str],
    rules: PlanNameRules,
    *,
    minimum_confidence: float | None = None,
) -> ImageClassification:
    candidates = tuple(dict.fromkeys(candidates))
    if minimum_confidence is None:
        minimum_confidence = min(
            1.0,
            max(
                0.0,
                float(
                    os.environ.get(
                        "CAIMASTER_PLAN_OCR_MIN_CONFIDENCE",
                        "0.90",
                    )
                ),
            ),
        )
    if ocr.confidence < minimum_confidence:
        return ImageClassification(
            None, ocr.confidence, "unresolved",
            "ocr_confidence_too_low", ocr.text,
        )
    compact_text = _compact(ocr.text)
    matches: set[str] = set()
    for candidate in candidates:
        terms = {candidate}
        terms.update(
            alias for alias, target in rules.aliases.items()
            if target == candidate
        )
        if any(
            len(_compact(term)) >= 2 and _compact(term) in compact_text
            for term in terms
        ):
            matches.add(candidate)
    if len(matches) == 1:
        return ImageClassification(
            matches.pop(), ocr.confidence, "resolved",
            "unique_candidate_match", ocr.text,
        )
    reason = "no_candidate_match" if not matches else "ambiguous_candidate_match"
    return ImageClassification(
        None, ocr.confidence, "unresolved", reason, ocr.text,
    )


class ImageAuthorClassifier:
    def __init__(
        self,
        conn: sqlite3.Connection,
        rules: PlanNameRules,
        provider: Callable[[bytes], OcrText],
    ) -> None:
        self.conn = conn
        self.rules = rules
        self.provider = provider

    def classify(
        self,
        *,
        article_id: str,
        source_url: str,
        contents: bytes,
        candidates: Iterable[str],
    ) -> ImageClassification:
        candidates = tuple(candidates)
        digest = hashlib.sha256(contents).hexdigest()
        row = self.conn.execute(
            "SELECT text, confidence, raw_json FROM plan_ocr_results "
            "WHERE content_sha256 = ?",
            (digest,),
        ).fetchone()
        if row is None:
            usage_id = _reserve_ocr_call(
                self.conn,
                content_sha256=digest,
                source_url=source_url,
            )
            try:
                ocr = self.provider(contents)
            except Exception:
                self.conn.execute(
                    "UPDATE plan_ocr_usage SET outcome = 'failed' WHERE id = ?",
                    (usage_id,),
                )
                self.conn.commit()
                raise
            self.conn.execute(
                "UPDATE plan_ocr_usage SET outcome = 'success' WHERE id = ?",
                (usage_id,),
            )
            self.conn.execute(
                """
                INSERT INTO plan_ocr_results(
                    content_sha256, source_url, provider, text,
                    confidence, raw_json, created_at
                ) VALUES (?, ?, 'aliyun_general', ?, ?, ?, ?)
                """,
                (
                    digest, source_url, ocr.text, ocr.confidence,
                    json.dumps(ocr.raw, ensure_ascii=False), int(time.time()),
                ),
            )
        else:
            ocr = OcrText(
                str(row["text"]),
                float(row["confidence"]),
                json.loads(row["raw_json"] or "{}"),
            )
        decision = classify_ocr_text(ocr, candidates, self.rules)
        self.conn.execute(
            """
            INSERT INTO plan_ocr_decisions(
                source_name, source_article_id, source_url, content_sha256,
                candidates_json, matched_plan_name, confidence, status,
                reason, created_at
            ) VALUES ('hongxisaishi', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_name, source_article_id, source_url) DO UPDATE SET
                content_sha256 = excluded.content_sha256,
                candidates_json = excluded.candidates_json,
                matched_plan_name = excluded.matched_plan_name,
                confidence = excluded.confidence,
                status = excluded.status,
                reason = excluded.reason,
                created_at = excluded.created_at
            """,
            (
                article_id, source_url, digest,
                json.dumps(candidates, ensure_ascii=False),
                decision.plan_name, decision.confidence, decision.status,
                decision.reason, int(time.time()),
            ),
        )
        return decision


def aliyun_ocr_enabled() -> bool:
    return os.environ.get("CAIMASTER_PLAN_OCR_ENABLED", "0") == "1"


def aliyun_general_ocr(contents: bytes) -> OcrText:
    """Call Alibaba OCR; imports stay lazy so disabled OCR cannot break sync."""
    try:
        from alibabacloud_ocr_api20210707.client import Client as OcrClient
        from alibabacloud_ocr_api20210707.models import RecognizeGeneralRequest
        from alibabacloud_tea_openapi.models import Config
        from alibabacloud_tea_util.models import RuntimeOptions
    except ModuleNotFoundError as exc:
        raise RuntimeError("Alibaba Cloud OCR SDK is not installed") from exc

    access_key_id = os.environ.get("ALIYUN_OCR_ACCESS_KEY_ID", "")
    access_key_secret = os.environ.get("ALIYUN_OCR_ACCESS_KEY_SECRET", "")
    if not access_key_id or not access_key_secret:
        raise RuntimeError("Alibaba Cloud OCR credentials are not configured")
    config = Config(
        access_key_id=access_key_id,
        access_key_secret=access_key_secret,
        endpoint=os.environ.get(
            "ALIYUN_OCR_ENDPOINT", "ocr-api.cn-hangzhou.aliyuncs.com"
        ),
    )
    try:
        response = OcrClient(config).recognize_general_with_options(
            RecognizeGeneralRequest(body=io.BytesIO(contents)),
            RuntimeOptions(),
        )
    except Exception as exc:
        # An expired OCR subscription will not recover on the next five-minute
        # source sync. Surface it as a controllable pending state instead.
        if "OcrServiceExpired" in str(exc):
            raise OcrProviderUnavailable("Alibaba OCR service expired") from exc
        raise
    raw_data = getattr(response.body, "data", "") or "{}"
    data = raw_data if isinstance(raw_data, dict) else json.loads(raw_data)
    words = data.get("prism_wordsInfo") or []
    text = "\n".join(
        str(item.get("word") or "") for item in words if item.get("word")
    )
    probabilities = [
        float(item["prob"]) for item in words
        if isinstance(item, dict) and item.get("prob") is not None
    ]
    confidence = sum(probabilities) / len(probabilities) if probabilities else 0.0
    if confidence > 1:
        confidence /= 100
    return OcrText(text, confidence, data)
