import json
import tempfile
import unittest
from pathlib import Path

from market_odds_api import MarketOddsService


class MarketOddsServiceTest(unittest.TestCase):
    def test_returns_matched_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "latest.json"
            path.write_text(
                json.dumps(
                    {
                        "provider": "test-provider",
                        "generatedAt": "2099-08-03T12:00:00+08:00",
                        "items": {
                            "123": {
                                "matchId": "123",
                                "bookmakers": [{"key": "example", "markets": {}}],
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            result = MarketOddsService(path).get("123")
            self.assertTrue(result["available"])
            self.assertFalse(result["stale"])
            self.assertEqual(result["provider"], "test-provider")

    def test_missing_or_unmatched_snapshot_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = MarketOddsService(Path(tmp) / "missing.json").get("123")
            self.assertFalse(result["available"])
            self.assertEqual(result["bookmakers"], [])

    def test_rejects_invalid_match_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                MarketOddsService(Path(tmp) / "latest.json").get("../../secret")


if __name__ == "__main__":
    unittest.main()
