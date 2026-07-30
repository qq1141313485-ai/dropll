import unittest

from audit_match_analysis_coverage import build_report


class MatchAnalysisCoverageTest(unittest.TestCase):
    def test_optional_injury_and_standings_do_not_make_match_unhealthy(self):
        report = build_report(
            [{"id": "1", "number": "周一001", "home": "主队", "away": "客队"}],
            lambda _: {
                "availability": {
                    "headToHead": True,
                    "recentHome": True,
                    "recentAway": True,
                    "keyPlayers": True,
                    "futureHome": True,
                    "futureAway": True,
                    "standings": False,
                    "injuries": False,
                }
            },
        )
        self.assertTrue(report["healthy"])
        self.assertEqual(0, report["incompleteCount"])

    def test_missing_required_section_is_reported(self):
        report = build_report(
            [{"id": "2", "number": "周一002", "home": "甲", "away": "乙"}],
            lambda _: {"availability": {"headToHead": True}},
        )
        self.assertFalse(report["healthy"])
        self.assertIn("keyPlayers", report["matches"][0]["missingRequired"])


if __name__ == "__main__":
    unittest.main()
