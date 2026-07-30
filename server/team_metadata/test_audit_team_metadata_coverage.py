import unittest

from audit_team_metadata_coverage import build_report


class CoverageAuditTest(unittest.TestCase):
    def test_reports_exactly_mapped_teams_as_covered(self) -> None:
        report = build_report(
            {
                "items": [
                    {
                        "number": "周二001",
                        "league": "欧冠",
                        "home": "库奥皮奥",
                        "away": "萨巴赫",
                    }
                ]
            },
            {"teams": {"库奥皮奥": {}, "萨巴赫": {}}},
        )
        self.assertEqual(2, report["coveredCount"])
        self.assertEqual(0, report["missingCount"])
        self.assertEqual(1.0, report["coverage"])

    def test_lists_unmapped_team_with_match_context(self) -> None:
        report = build_report(
            {
                "items": [
                    {
                        "number": "周三002",
                        "league": "欧协联",
                        "home": "新球队",
                        "away": "哈茨",
                    }
                ]
            },
            {"teams": {"哈茨": {}}},
        )
        self.assertEqual(
            [{"name": "新球队", "matches": ["周三002 欧协联"]}],
            report["missing"],
        )
        self.assertEqual(0.5, report["coverage"])


if __name__ == "__main__":
    unittest.main()
