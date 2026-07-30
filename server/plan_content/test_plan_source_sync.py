import unittest
from datetime import datetime

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


if __name__ == "__main__":
    unittest.main()
