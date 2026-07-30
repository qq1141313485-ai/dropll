import os
import tempfile
import time
import unittest
from pathlib import Path

from match_analysis import (
    CACHE_TTL_SECONDS,
    MatchAnalysisService,
    collect_analysis,
    normalize_analysis,
)


def _payloads():
    return {
        "head": {
            "success": True,
            "value": {
                "homeTeamShortName": "马尔默",
                "awayTeamShortName": "埃夫斯堡",
            },
        },
        "history": {
            "success": True,
            "value": {
                "matchList": [
                    {
                        "matchDate": "2025-04-08",
                        "leagueShortName": "瑞超",
                        "homeTeamShortName": "马尔默",
                        "awayTeamShortName": "埃夫斯堡",
                        "fullCourtGoal": "2:1",
                        "halfCourtGoal": "0:0",
                        "winningTeam": "home",
                    },
                    {
                        "matchDate": "2024-05-05",
                        "leagueShortName": "瑞超",
                        "homeTeamShortName": "埃夫斯堡",
                        "awayTeamShortName": "马尔默",
                        "fullCourtGoal": "3:1",
                        "halfCourtGoal": "1:0",
                        "winningTeam": "home",
                    },
                ]
            },
        },
        "standings": {
            "success": True,
            "value": {
                "leagueShortName": "瑞超",
                "seasonName": "2026",
                "homeTables": {
                    "total": {
                        "teamShortName": "马尔默",
                        "ranking": 7,
                        "points": 20,
                        "totalLegCnt": 13,
                        "winGoalMatchCnt": 6,
                        "drawMatchCnt": 2,
                        "lossGoalMatchCnt": 5,
                        "goalCnt": 27,
                        "lossGoalCnt": 22,
                    }
                },
                "awayTables": {
                    "total": {
                        "teamShortName": "埃夫斯堡",
                        "ranking": 9,
                        "points": 18,
                        "totalLegCnt": 14,
                        "winGoalMatchCnt": 4,
                        "drawMatchCnt": 6,
                        "lossGoalMatchCnt": 4,
                        "goalCnt": 18,
                        "lossGoalCnt": 17,
                    }
                },
            },
        },
        "recent": {
            "success": True,
            "value": {
                "home": {
                    "matchList": [
                        {
                            "matchDate": "2026-07-21",
                            "leagueShortName": "瑞超",
                            "homeTeamShortName": "卡尔马",
                            "awayTeamShortName": "马尔默",
                            "fullCourtGoal": "2:2",
                            "halfCourtGoal": "2:1",
                        }
                    ]
                },
                "away": {
                    "matchList": [
                        {
                            "matchDate": "2026-07-19",
                            "leagueShortName": "瑞超",
                            "homeTeamShortName": "埃夫斯堡",
                            "awayTeamShortName": "天狼星",
                            "fullCourtGoal": "1:3",
                            "halfCourtGoal": "0:0",
                        }
                    ]
                },
            },
        },
        "players": {
            "success": True,
            "value": {
                "home": {
                    "teamShortName": "马尔默",
                    "playerList": [
                        {
                            "personId": 1,
                            "personName": "主队射手",
                            "uniformNo": "9",
                            "playerPositionDesc": "前锋",
                            "appearanceCnt": 3,
                            "startedMatchCnt": 3,
                            "goalCnt": 2,
                            "assistCnt": 1,
                        }
                    ],
                },
                "away": {"teamShortName": "埃夫斯堡", "playerList": []},
            },
        },
        "injuries": {
            "success": True,
            "value": {
                "home": {
                    "teamShortName": "马尔默",
                    "injuriesAndSuspensionsList": [
                        {
                            "personId": 2,
                            "personName": "伤停后卫",
                            "injuryFlag": 1,
                            "suspensionFlag": 0,
                        }
                    ],
                },
                "away": {
                    "teamShortName": "埃夫斯堡",
                    "injuriesAndSuspensionsList": [],
                },
            },
        },
        "future": {
            "success": True,
            "value": {
                "home": {
                    "teamShortName": "马尔默",
                    "matchList": [
                        {
                            "matchId": 7,
                            "matchDateTime": "2026-08-02 18:00:00",
                            "tournamentShortName": "瑞超",
                            "homeTeamShortName": "马尔默",
                            "awayTeamShortName": "卡尔马",
                        }
                    ],
                },
                "away": {"teamShortName": "埃夫斯堡", "matchList": []},
            },
        },
    }


class NormalizeAnalysisTests(unittest.TestCase):
    def test_normalizes_required_detail_sections(self):
        result = normalize_analysis("2040634", _payloads())

        self.assertEqual(result["teams"]["home"], "马尔默")
        self.assertEqual(result["headToHead"]["summary"]["wins"], 1)
        self.assertEqual(result["headToHead"]["summary"]["losses"], 1)
        self.assertEqual(result["standings"]["home"]["total"]["ranking"], 7)
        self.assertEqual(result["recent"]["home"]["matches"][0]["result"], "平")
        self.assertEqual(result["recent"]["away"]["matches"][0]["result"], "负")
        self.assertEqual(result["keyPlayers"]["home"]["players"][0]["goals"], 2)
        self.assertTrue(result["injuries"]["home"]["players"][0]["injured"])
        self.assertEqual(result["future"]["home"]["matches"][0]["id"], "7")
        self.assertTrue(result["availability"]["headToHead"])
        self.assertTrue(result["availability"]["keyPlayers"])
        self.assertTrue(result["availability"]["injuries"])
        self.assertTrue(result["availability"]["futureHome"])
        self.assertFalse(result["availability"]["futureAway"])

    def test_collect_uses_all_sources_and_survives_one_missing_source(self):
        payloads = _payloads()
        requested = []

        def fetch(path, params):
            requested.append((path, params))
            if path == "getMatchTablesV2.qry":
                return {}
            by_path = {
                "getMatchHeadV1.qry": payloads["head"],
                "getResultHistoryV1.qry": payloads["history"],
                "getMatchResultV1.qry": payloads["recent"],
                "getMatchPlayerV1.qry": payloads["players"],
                "getInjurySuspensionV1.qry": payloads["injuries"],
                "getFutureMatchesV1.qry": payloads["future"],
            }
            return by_path[path]

        result = collect_analysis("2040634", fetch)

        self.assertEqual(len(requested), 7)
        self.assertFalse(result["availability"]["standings"])
        self.assertTrue(result["availability"]["headToHead"])

    def test_rejects_non_numeric_match_id(self):
        with self.assertRaises(ValueError):
            collect_analysis("../bad", lambda *_: {})

    def test_match_records_are_sorted_before_limit_is_applied(self):
        payloads = _payloads()
        history = payloads["history"]["value"]["matchList"]
        history.insert(
            0,
            {
                "matchDate": "2023-01-01",
                "homeTeamShortName": "马尔默",
                "awayTeamShortName": "埃夫斯堡",
                "fullCourtGoal": "1:0",
            },
        )
        history.append(
            {
                "matchDate": "2026/07/25 19:30",
                "homeTeamShortName": "马尔默",
                "awayTeamShortName": "埃夫斯堡",
                "fullCourtGoal": "2:0",
            },
        )

        result = normalize_analysis("2040634", payloads)

        self.assertEqual(
            result["headToHead"]["matches"][0]["date"],
            "2026/07/25 19:30",
        )


class CacheTests(unittest.TestCase):
    def test_fresh_cache_avoids_duplicate_source_requests(self):
        calls = 0
        payloads = _payloads()

        def fetch(path, _params):
            nonlocal calls
            calls += 1
            mapping = {
                "getMatchHeadV1.qry": "head",
                "getResultHistoryV1.qry": "history",
                "getMatchTablesV2.qry": "standings",
                "getMatchResultV1.qry": "recent",
                "getMatchPlayerV1.qry": "players",
                "getInjurySuspensionV1.qry": "injuries",
                "getFutureMatchesV1.qry": "future",
            }
            return payloads[mapping[path]]

        with tempfile.TemporaryDirectory() as directory:
            service = MatchAnalysisService(directory, fetch)
            first = service.get("2040634")
            second = service.get("2040634")

        self.assertEqual(calls, 7)
        self.assertEqual(first, second)

    def test_stale_cache_is_returned_when_refresh_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "2040634.json"
            path.write_text('{"matchId":"2040634","stale":false}', encoding="utf-8")
            old = time.time() - CACHE_TTL_SECONDS - 10
            os.utime(path, (old, old))

            def fail(*_args):
                from match_analysis import AnalysisSourceError

                raise AnalysisSourceError("offline")

            service = MatchAnalysisService(directory, fail)
            result = service.get("2040634")

        self.assertTrue(result["stale"])


if __name__ == "__main__":
    unittest.main()
