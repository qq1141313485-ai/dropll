import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from sync_team_metadata import sync


class TeamMetadataSyncTest(unittest.TestCase):
    def test_sync_requires_expected_source_id_and_caches_badge(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            aliases = root / "aliases.json"
            aliases.write_text(
                json.dumps(
                    {
                        "测试队": {
                            "query": "Test FC",
                            "sourceTeamId": "42",
                            "sourceName": "Test FC",
                        }
                    }
                ),
                encoding="utf-8",
            )

            def download(_: str, destination: Path) -> None:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(b"x" * 300)

            with (
                patch(
                    "sync_team_metadata._source_team",
                    return_value={
                        "idTeam": "42",
                        "strTeam": "Test FC",
                        "idLeague": "99",
                        "strLeague": "Test League",
                        "strCountry": "Test",
                        "strBadge": "https://example.com/badge.png",
                    },
                ),
                patch("sync_team_metadata._download_badge", side_effect=download),
            ):
                result = sync(aliases, root / "cache", "123", 0)

            self.assertEqual(result["teamCount"], 1)
            self.assertEqual(result["errorCount"], 0)
            team = result["teams"]["测试队"]
            self.assertEqual(team["sourceTeamId"], "42")
            self.assertEqual(team["sourceLeagueId"], "99")
            self.assertEqual(team["badgeFile"], "badges/42.png")
            self.assertEqual(team["badgeBytes"], 300)
            self.assertTrue((root / "cache" / "manifest.json").exists())

    def test_sync_rejects_changed_source_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            aliases = root / "aliases.json"
            aliases.write_text(
                json.dumps(
                    {
                        "测试队": {
                            "query": "Test FC",
                            "sourceTeamId": "42",
                            "sourceName": "Test FC",
                        }
                    }
                ),
                encoding="utf-8",
            )
            with patch(
                "sync_team_metadata._source_team",
                return_value={
                    "idTeam": "42",
                    "strTeam": "Wrong Team",
                    "strBadge": "https://example.com/badge.png",
                },
            ):
                result = sync(aliases, root / "cache", "123", 0)

            self.assertEqual(result["teamCount"], 0)
            self.assertEqual(result["errorCount"], 1)
            self.assertIn("source name changed", result["errors"][0]["error"])


if __name__ == "__main__":
    unittest.main()
