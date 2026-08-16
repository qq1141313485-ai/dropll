import unittest

from build_team_alias_review import build_review_queue, merge_review_queue


class BuildTeamAliasReviewTest(unittest.TestCase):
    def test_unique_kickoff_generates_review_only_candidate(self):
        coverage = {
            "items": [
                {
                    "status": "unmatched",
                    "matchId": "1",
                    "number": "周日001",
                    "league": "测试联赛",
                    "sportKey": "soccer_test",
                    "kickoff": "2026-08-16T10:30:00+00:00",
                    "home": "主队中文",
                    "away": "客队中文",
                }
            ]
        }
        fixtures = {
            "soccer_test": [
                {
                    "id": "provider-1",
                    "commence_time": "2026-08-16T10:30:00Z",
                    "home_team": "Home FC",
                    "away_team": "Away FC",
                }
            ]
        }
        self.assertEqual(
            build_review_queue(coverage, fixtures),
            [
                {
                    "status": "review_required",
                    "reason": "unique provider fixture at matching kickoff",
                    "matchId": "1",
                    "number": "周日001",
                    "league": "测试联赛",
                    "kickoff": "2026-08-16T10:30:00+00:00",
                    "kickoffDeltaMinutes": 0,
                    "providerEventId": "provider-1",
                    "candidates": [
                        {"localName": "主队中文", "providerName": "Home FC"},
                        {"localName": "客队中文", "providerName": "Away FC"},
                    ],
                }
            ],
        )

    def test_kickoff_collision_is_not_emitted(self):
        coverage = {
            "items": [
                {
                    "status": "unmatched",
                    "sportKey": "soccer_test",
                    "kickoff": "2026-08-16T10:30:00+00:00",
                    "home": "主队中文",
                    "away": "客队中文",
                }
            ]
        }
        fixtures = {
            "soccer_test": [
                {
                    "commence_time": "2026-08-16T10:30:00Z",
                    "home_team": "Home A",
                    "away_team": "Away A",
                },
                {
                    "commence_time": "2026-08-16T10:30:00Z",
                    "home_team": "Home B",
                    "away_team": "Away B",
                },
            ]
        }
        self.assertEqual(build_review_queue(coverage, fixtures), [])

    def test_naive_official_kickoff_matches_utc_provider_time(self):
        coverage = {
            "items": [
                {
                    "status": "unmatched",
                    "sportKey": "soccer_test",
                    "kickoff": "2026-08-16 18:30:00",
                    "home": "主队中文",
                    "away": "客队中文",
                }
            ]
        }
        fixtures = {
            "soccer_test": [
                {
                    "id": "provider-1",
                    "commence_time": "2026-08-16T10:30:00Z",
                    "home_team": "Home FC",
                    "away_team": "Away FC",
                }
            ]
        }
        self.assertEqual(len(build_review_queue(coverage, fixtures)), 1)

    def test_matched_rows_do_not_reenter_review_queue(self):
        coverage = {
            "items": [
                {
                    "status": "matched",
                    "sportKey": "soccer_test",
                    "kickoff": "2026-08-16 18:30:00",
                    "home": "主队中文",
                    "away": "客队中文",
                }
            ]
        }
        fixtures = {
            "soccer_test": [
                {
                    "commence_time": "2026-08-16T10:30:00Z",
                    "home_team": "Home FC",
                    "away_team": "Away FC",
                }
            ]
        }
        self.assertEqual(build_review_queue(coverage, fixtures), [])

    def test_existing_review_candidate_is_kept_without_unique_fixture(self):
        coverage = {
            "items": [
                {
                    "status": "review",
                    "matchId": "review-1",
                    "sportKey": "soccer_test",
                    "kickoff": "2026-08-16 18:30:00",
                    "home": "中文主队",
                    "away": "中文客队",
                    "providerHome": "Provider Home",
                    "providerAway": "Provider Away",
                    "reason": "manual review required",
                }
            ]
        }
        queue = build_review_queue(coverage, {"soccer_test": []})
        self.assertEqual(queue[0]["matchId"], "review-1")
        self.assertEqual(
            queue[0]["candidates"][1],
            {"localName": "中文客队", "providerName": "Provider Away"},
        )

    def test_review_queue_retains_only_unresolved_active_items(self):
        existing = [
            {
                "matchId": "kept",
                "kickoff": "2026-08-16 18:30:00",
                "candidates": [{"localName": "主队", "providerName": "Home FC"}],
            },
            {
                "matchId": "resolved",
                "kickoff": "2026-08-16 18:30:00",
                "candidates": [{"localName": "客队", "providerName": "Away FC"}],
            },
        ]
        queue = merge_review_queue(
            [],
            existing,
            {"客队": ["Away FC"]},
            {"kept", "resolved"},
        )
        self.assertEqual([item["matchId"] for item in queue], ["kept"])


if __name__ == "__main__":
    unittest.main()
