import sqlite3
import unittest
from datetime import datetime, timedelta
from unittest import mock

import plan_source_sync
from plan_source_common import (
    CHINA_TZ,
    IGNORE_IMAGE_ASSIGNMENT,
    PlanNameRules,
    SourceError,
    extract_image_urls,
    parse_plan_title,
    parse_plan_title_info,
)


class PlanSourceSyncTest(unittest.TestCase):
    def test_zlwhd_homepage_links_and_title_normalization(self) -> None:
        html = (
            '<a href="/sys-nd/100.html">0905大鹏 <span>2026-09-05</span></a>'
            '<a href="/sys-nd/101.html">0905篮球推荐 2026-09-05</a>'
        )
        with mock.patch.object(plan_source_sync, "SOURCE_WEB_URL", "https://www.zlwhd.com"):
            parser = plan_source_sync._ArticleLinkParser()
            parser.feed(html)
        self.assertEqual(parser.items[0]["id"], "100")
        self.assertEqual(parser.items[0]["title"], "0905大鹏")
        self.assertEqual(
            plan_source_sync._zlwhd_title("0905大鹏", 1788537600),
            "20260905大鹏",
        )

    def test_zlwhd_news_info_and_rich_content(self) -> None:
        raw = (
            '<script>{"newsInfo":{"id":100,"title":"0905大鹏",'
            '"date":1788606960000,"richContent":"<p><img src=\\"//cdn.example/a.jpg\\"></p>"}}</script>'
        ).encode("utf-8")
        info = plan_source_sync._decode_zlwhd_news_info(raw)
        self.assertEqual(info["publishtime"], 1788606960)
        with mock.patch.object(plan_source_sync, "SOURCE_KIND", "zlwhd_html"):
            self.assertEqual(
                plan_source_sync._article_image_urls({}, info),
                ["https://cdn.example/a.jpg"],
            )

    def test_compact_date_title(self) -> None:
        name, published = parse_plan_title("20260725公牛", {})

        self.assertEqual(name, "公牛")
        self.assertEqual(published, datetime(2026, 7, 25, tzinfo=CHINA_TZ))

    def test_separated_date_and_mapping(self) -> None:
        name, _ = parse_plan_title(
            "2026-07-25 凤凰",
            {"凤凰": "凤凰计划"},
        )

        self.assertEqual(name, "凤凰计划")

    def test_structured_rules_resolve_alias(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "aliases": {"老牛": "公牛"},
                "allowedNames": ["公牛"],
            }
        )

        parsed = parse_plan_title_info("20260725 老牛", rules)

        self.assertEqual(parsed.raw_name, "老牛")
        self.assertEqual(parsed.name, "公牛")
        self.assertFalse(parsed.needs_review)

    def test_structured_rules_hold_unknown_name_for_review(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "allowedNames": ["公牛"],
            }
        )

        with self.assertRaisesRegex(SourceError, "awaits mapping"):
            parse_plan_title_info("20260725 新计划", rules)

    def test_image_assignments_resolve_each_image_target(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "imageAssignments": {
                    "扫地僧，辉哥中赔": ["辉哥", "扫地僧"],
                },
            }
        )

        parsed = parse_plan_title_info(
            "20260726 扫地僧，辉哥中赔",
            rules,
        )

        self.assertEqual(parsed.name, "辉哥")
        self.assertEqual(parsed.image_plan_names, ("辉哥", "扫地僧"))
        self.assertEqual(rules.allowed_names, frozenset({"辉哥", "扫地僧"}))
        self.assertFalse(parsed.needs_review)

    def test_image_assignments_require_a_list(self) -> None:
        with self.assertRaisesRegex(SourceError, "must be a JSON array"):
            PlanNameRules.from_mapping(
                {
                    "imageAssignments": {
                        "扫地僧，辉哥中赔": "辉哥",
                    },
                }
            )

    def test_image_assignments_allow_explicit_ignored_image(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "imageAssignments": {
                    "小米柒月": ["柒月", "__IGNORE__", "小米"],
                },
            }
        )

        parsed = parse_plan_title_info("20260726 小米柒月", rules)

        self.assertEqual(parsed.name, "柒月")
        self.assertEqual(
            parsed.image_plan_names,
            ("柒月", IGNORE_IMAGE_ASSIGNMENT, "小米"),
        )
        self.assertEqual(rules.allowed_names, frozenset({"柒月", "小米"}))

    def test_structured_rules_resolve_session_suffix_to_allowed_base(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "allowedNames": ["平哥"],
            }
        )

        for suffix in ("早", "晚", "早场", "晚场", "早单", "晚单"):
            with self.subTest(suffix=suffix):
                parsed = parse_plan_title_info(f"20260726 平哥{suffix}", rules)
                self.assertEqual(parsed.raw_name, f"平哥{suffix}")
                self.assertEqual(parsed.name, "平哥")
                self.assertFalse(parsed.needs_review)

    def test_session_suffix_requires_an_existing_allowed_base(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "allowedNames": ["公牛"],
            }
        )

        with self.assertRaisesRegex(SourceError, "awaits mapping"):
            parse_plan_title_info("20260726 陌生计划早", rules)

    def test_explicitly_allowed_session_name_is_not_shortened(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": False,
                "allowedNames": ["今早", "今"],
            }
        )

        parsed = parse_plan_title_info("20260726 今早", rules)

        self.assertEqual(parsed.name, "今早")

    def test_structured_rules_require_allowlist_when_auto_create_is_off(self) -> None:
        rules = PlanNameRules.from_mapping({"allowAutoCreate": False})

        with self.assertRaisesRegex(SourceError, "awaits mapping"):
            parse_plan_title_info("20260725 新计划", rules)

    def test_structured_rules_mark_auto_created_name_for_review(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": True,
                "allowedNames": ["公牛"],
            }
        )

        parsed = parse_plan_title_info("20260725 新计划", rules)

        self.assertEqual(parsed.name, "新计划")
        self.assertTrue(parsed.needs_review)

    def test_structured_rules_ignore_configured_name(self) -> None:
        rules = PlanNameRules.from_mapping(
            {
                "allowAutoCreate": True,
                "ignoredNames": ["临时通知"],
            }
        )

        with self.assertRaisesRegex(SourceError, "ignored"):
            parse_plan_title_info("20260725 临时通知", rules)

    def test_non_plan_article_is_rejected(self) -> None:
        with self.assertRaisesRegex(SourceError, "excluded"):
            parse_plan_title("20260725 APP下载二维码", {})

    def test_content_images_are_absolute_and_deduplicated(self) -> None:
        urls = extract_image_urls(
            '<p><img src="/uploads/a.jpg"><img src="/uploads/a.jpg">'
            '<img src="https://cdn.example.com/b.jpg"></p>',
            "https://api.tchongxi.com",
        )

        self.assertEqual(
            urls,
            [
                "https://api.tchongxi.com/uploads/a.jpg",
                "https://cdn.example.com/b.jpg",
            ],
        )

    def test_queued_articles_require_an_explicit_admin_action(self) -> None:
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.executescript(
            """
            CREATE TABLE plan_sync_articles (
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
                synced_at INTEGER NOT NULL
            );
            """
        )
        now = datetime.now(CHINA_TZ).replace(hour=12, minute=0, second=0, microsecond=0)
        today = int(now.timestamp())
        yesterday = int((now - timedelta(days=1)).timestamp())
        conn.executemany(
            """
            INSERT INTO plan_sync_articles(
                source_name, source_article_id, source_title, published_at,
                status, error, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                ("hongxisaishi", "1", "20260731 今日文章", today, "pending_name",
                 "plan OCR usage limit reached: daily OCR limit reached (200/200)", today),
                ("hongxisaishi", "2", "20260730 旧文章", yesterday, "pending_name",
                 "plan OCR usage limit reached: daily OCR limit reached (200/200)", yesterday),
                ("hongxisaishi", "3", "20260730 人工配置", yesterday, "name_configured",
                 "", yesterday),
                ("hongxisaishi", "4", "20260731 人工重试", today, "retry_queued",
                 "", today),
            ],
        )
        conn.commit()
        self.addCleanup(conn.close)

        with mock.patch.object(plan_source_sync, "_connect", return_value=conn):
            items = plan_source_sync._fetch_queued_articles()

        self.assertNotIn("1", items)
        self.assertIn("3", items)
        self.assertIn("4", items)
        self.assertNotIn("2", items)

    def test_unavailable_ocr_is_held_for_review(self) -> None:
        self.assertEqual(
            plan_source_sync._status_for_source_error(
                "plan OCR unavailable: Alibaba OCR service expired"
            ),
            "pending_name",
        )


if __name__ == "__main__":
    unittest.main()
