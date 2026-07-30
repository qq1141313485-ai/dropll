import sqlite3
import unittest
from unittest import mock

from plan_image_classifier import (
    ImageAuthorClassifier,
    OcrUsageLimitReached,
    OcrText,
    classify_ocr_text,
    title_candidates,
)
from plan_source_common import PlanNameRules


def rules() -> PlanNameRules:
    return PlanNameRules.from_mapping({
        "allowAutoCreate": False,
        "allowedNames": ["扫地僧", "平哥", "红中"],
        "aliases": {"平哥计划": "平哥"},
    })


class PlanImageClassifierTest(unittest.TestCase):
    def test_title_candidates_ignore_series_descriptors(self) -> None:
        self.assertEqual(
            title_candidates("扫地僧早场，平哥3.0", rules()),
            ("扫地僧", "平哥"),
        )

    def test_unique_author_in_image_is_resolved(self) -> None:
        result = classify_ocr_text(
            OcrText("扫地僧 晚场 高赔", 0.96, {}),
            ("扫地僧", "平哥"), rules(),
        )
        self.assertEqual(result.plan_name, "扫地僧")

    def test_alias_in_image_is_resolved(self) -> None:
        result = classify_ocr_text(
            OcrText("平哥计划 2.0", 0.91, {}),
            ("扫地僧", "平哥"), rules(),
        )
        self.assertEqual(result.plan_name, "平哥")

    def test_ambiguous_image_stays_unresolved(self) -> None:
        result = classify_ocr_text(
            OcrText("扫地僧 平哥 联合", 0.95, {}),
            ("扫地僧", "平哥"), rules(),
        )
        self.assertIsNone(result.plan_name)
        self.assertEqual(result.reason, "ambiguous_candidate_match")

    def test_low_confidence_stays_unresolved(self) -> None:
        result = classify_ocr_text(
            OcrText("扫地僧", 0.40, {}), ("扫地僧",), rules(),
        )
        self.assertIsNone(result.plan_name)

    def test_provider_confidence_contract_uses_zero_to_one(self) -> None:
        result = classify_ocr_text(
            OcrText("扫地僧", 0.71, {}), ("扫地僧",), rules(),
        )
        self.assertIsNone(result.plan_name)

    def test_image_order_does_not_change_authors(self) -> None:
        texts = (
            OcrText("扫地僧 早场", 0.95, {}),
            OcrText("平哥 3.0", 0.94, {}),
        )
        forward = [
            classify_ocr_text(text, ("扫地僧", "平哥"), rules()).plan_name
            for text in texts
        ]
        reversed_result = [
            classify_ocr_text(text, ("扫地僧", "平哥"), rules()).plan_name
            for text in reversed(texts)
        ]
        self.assertEqual(forward, ["扫地僧", "平哥"])
        self.assertEqual(reversed_result, ["平哥", "扫地僧"])

    def test_cache_avoids_second_provider_call(self) -> None:
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.executescript(
            """
            CREATE TABLE plan_ocr_results (
                content_sha256 TEXT PRIMARY KEY, source_url TEXT NOT NULL,
                provider TEXT NOT NULL, text TEXT NOT NULL,
                confidence REAL NOT NULL, raw_json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE plan_ocr_decisions (
                id INTEGER PRIMARY KEY, source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL, source_url TEXT NOT NULL,
                content_sha256 TEXT NOT NULL, candidates_json TEXT NOT NULL,
                matched_plan_name TEXT, confidence REAL NOT NULL,
                status TEXT NOT NULL, reason TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id, source_url)
            );
            CREATE TABLE plan_ocr_usage (
                id INTEGER PRIMARY KEY, content_sha256 TEXT NOT NULL,
                source_url TEXT NOT NULL, attempted_at INTEGER NOT NULL,
                outcome TEXT NOT NULL
            );
            """
        )
        calls = []

        def provider(contents: bytes) -> OcrText:
            calls.append(contents)
            return OcrText("红中 晚场", 0.98, {"ok": True})

        classifier = ImageAuthorClassifier(conn, rules(), provider)
        for article_id in ("1", "2"):
            result = classifier.classify(
                article_id=article_id,
                source_url=f"https://example/{article_id}.jpg",
                contents=b"same-image",
                candidates=("红中",),
            )
            self.assertEqual(result.plan_name, "红中")
        self.assertEqual(calls, [b"same-image"])
        self.assertEqual(
            conn.execute("SELECT COUNT(*) FROM plan_ocr_usage").fetchone()[0],
            1,
        )

    def test_monthly_limit_blocks_provider_before_call(self) -> None:
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.executescript(
            """
            CREATE TABLE plan_ocr_results (
                content_sha256 TEXT PRIMARY KEY, source_url TEXT NOT NULL,
                provider TEXT NOT NULL, text TEXT NOT NULL,
                confidence REAL NOT NULL, raw_json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE plan_ocr_decisions (
                id INTEGER PRIMARY KEY, source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL, source_url TEXT NOT NULL,
                content_sha256 TEXT NOT NULL, candidates_json TEXT NOT NULL,
                matched_plan_name TEXT, confidence REAL NOT NULL,
                status TEXT NOT NULL, reason TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id, source_url)
            );
            CREATE TABLE plan_ocr_usage (
                id INTEGER PRIMARY KEY, content_sha256 TEXT NOT NULL,
                source_url TEXT NOT NULL, attempted_at INTEGER NOT NULL,
                outcome TEXT NOT NULL
            );
            """
        )
        calls = []

        def provider(contents: bytes) -> OcrText:
            calls.append(contents)
            return OcrText("红中", 0.98, {})

        classifier = ImageAuthorClassifier(conn, rules(), provider)
        with mock.patch.dict(
            "os.environ",
            {"CAIMASTER_PLAN_OCR_MONTHLY_LIMIT": "1"},
            clear=False,
        ):
            classifier.classify(
                article_id="1",
                source_url="https://example/1.jpg",
                contents=b"first",
                candidates=("红中",),
            )
            with self.assertRaises(OcrUsageLimitReached):
                classifier.classify(
                    article_id="2",
                    source_url="https://example/2.jpg",
                    contents=b"second",
                    candidates=("红中",),
                )
        self.assertEqual(calls, [b"first"])

    def test_daily_limit_blocks_provider_before_call(self) -> None:
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.executescript(
            """
            CREATE TABLE plan_ocr_results (
                content_sha256 TEXT PRIMARY KEY, source_url TEXT NOT NULL,
                provider TEXT NOT NULL, text TEXT NOT NULL,
                confidence REAL NOT NULL, raw_json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE plan_ocr_decisions (
                id INTEGER PRIMARY KEY, source_name TEXT NOT NULL,
                source_article_id TEXT NOT NULL, source_url TEXT NOT NULL,
                content_sha256 TEXT NOT NULL, candidates_json TEXT NOT NULL,
                matched_plan_name TEXT, confidence REAL NOT NULL,
                status TEXT NOT NULL, reason TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(source_name, source_article_id, source_url)
            );
            CREATE TABLE plan_ocr_usage (
                id INTEGER PRIMARY KEY, content_sha256 TEXT NOT NULL,
                source_url TEXT NOT NULL, attempted_at INTEGER NOT NULL,
                outcome TEXT NOT NULL
            );
            """
        )
        calls = []

        def provider(contents: bytes) -> OcrText:
            calls.append(contents)
            return OcrText("红中", 0.98, {})

        classifier = ImageAuthorClassifier(conn, rules(), provider)
        with mock.patch.dict(
            "os.environ",
            {
                "CAIMASTER_PLAN_OCR_DAILY_LIMIT": "1",
                "CAIMASTER_PLAN_OCR_MONTHLY_LIMIT": "180",
            },
            clear=False,
        ):
            classifier.classify(
                article_id="1",
                source_url="https://example/1.jpg",
                contents=b"first",
                candidates=("红中",),
            )
            with self.assertRaises(OcrUsageLimitReached):
                classifier.classify(
                    article_id="2",
                    source_url="https://example/2.jpg",
                    contents=b"second",
                    candidates=("红中",),
                )
        self.assertEqual(calls, [b"first"])


if __name__ == "__main__":
    unittest.main()
