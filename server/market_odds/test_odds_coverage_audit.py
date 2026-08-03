import unittest

from odds_coverage_audit import (
    audit,
    build_public_snapshot,
    budget_block_reason,
    decide_event,
    market_coverage,
    merge_opening_prices,
)


ALIASES = {
    "Home CN": ["Home United"],
    "Away CN": ["Away City"],
}


def event(
    event_id="provider-1",
    home="Home United",
    away="Away City",
    kickoff="2026-08-04T00:00:00+08:00",
):
    return {
        "id": event_id,
        "home_team": home,
        "away_team": away,
        "commence_time": kickoff,
        "bookmakers": [
            {
                "key": "example",
                "markets": [
                    {"key": "h2h", "outcomes": []},
                    {"key": "spreads", "outcomes": []},
                    {"key": "totals", "outcomes": []},
                ],
            }
        ],
    }


class OddsCoverageAuditTest(unittest.TestCase):
    def setUp(self):
        self.match = {
            "id": "official-1",
            "number": "001",
            "league": "League CN",
            "home": "Home CN",
            "away": "Away CN",
            "kickoff": "2026-08-04 00:00:00",
        }

    def test_strict_alias_and_kickoff_match(self):
        decision = decide_event(self.match, [event()], ALIASES)
        self.assertEqual(decision.status, "matched")
        self.assertEqual(decision.event["id"], "provider-1")
        self.assertEqual(decision.kickoff_delta_minutes, 0)

    def test_reversed_home_and_away_do_not_match(self):
        decision = decide_event(
            self.match,
            [event(home="Away City", away="Home United")],
            ALIASES,
        )
        self.assertEqual(decision.status, "unmatched")

    def test_market_coverage_requires_all_three_markets(self):
        full = market_coverage(event())
        self.assertTrue(full["complete"])
        partial_event = event()
        partial_event["bookmakers"][0]["markets"].pop()
        self.assertFalse(market_coverage(partial_event)["complete"])

    def test_unmapped_league_is_reported_without_guessing(self):
        result = audit([self.match], {}, {}, ALIASES)
        self.assertEqual(result["summary"]["unmappedLeagues"], 1)
        self.assertEqual(result["items"][0]["status"], "unmapped_league")

    def test_report_counts_complete_strict_matches(self):
        result = audit(
            [self.match],
            {"soccer_test": [event()]},
            {"League CN": "soccer_test"},
            ALIASES,
            {"last": 3, "used": 10, "remaining": 490},
        )
        self.assertEqual(result["summary"]["matched"], 1)
        self.assertEqual(result["summary"]["allMarketsComplete"], 1)
        self.assertEqual(result["usage"]["last"], 3)

    def test_public_snapshot_contains_only_strict_matches_and_safe_odds(self):
        provider_event = event()
        provider_event["bookmakers"][0].update(
            {
                "title": "Example Sportsbook",
                "last_update": "2026-08-03T12:00:00Z",
            }
        )
        provider_event["bookmakers"][0]["markets"][0]["outcomes"] = [
            {"name": "Home United", "price": 2.1},
            {"name": "Draw", "price": 3.2},
            {"name": "Away City", "price": 3.4},
        ]
        report = audit(
            [self.match],
            {"soccer_test": [provider_event]},
            {"League CN": "soccer_test"},
            ALIASES,
        )
        snapshot = build_public_snapshot(report, {"soccer_test": [provider_event]})
        item = snapshot["items"]["official-1"]
        self.assertEqual(item["providerEventId"], "provider-1")
        self.assertEqual(item["bookmakers"][0]["markets"]["h2h"][0]["price"], 2.1)
        self.assertNotIn("apiKey", str(snapshot))

    def test_opening_price_survives_later_snapshots(self):
        previous = {
            "items": {
                "official-1": {
                    "bookmakers": [
                        {
                            "key": "example",
                            "markets": {
                                "h2h": [
                                    {
                                        "name": "Home United",
                                        "price": 2.1,
                                        "openingPrice": 2.2,
                                    }
                                ]
                            },
                        }
                    ]
                }
            }
        }
        current = {
            "items": {
                "official-1": {
                    "bookmakers": [
                        {
                            "key": "example",
                            "markets": {
                                "h2h": [{"name": "Home United", "price": 2.0}]
                            },
                        }
                    ]
                }
            }
        }
        merged = merge_opening_prices(current, previous)
        outcome = merged["items"]["official-1"]["bookmakers"][0]["markets"]["h2h"][0]
        self.assertEqual(outcome["price"], 2.0)
        self.assertEqual(outcome["openingPrice"], 2.2)

    def test_budget_blocks_expensive_or_low_balance_runs(self):
        sports = ["one", "two"]
        self.assertIsNone(budget_block_reason(sports, 470, 100, 12))
        self.assertIn("exceeds limit", budget_block_reason(sports, 470, 100, 5))
        self.assertIn("below reserve", budget_block_reason(sports, 105, 100, 12))


if __name__ == "__main__":
    unittest.main()
