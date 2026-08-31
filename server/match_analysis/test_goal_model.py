import math
import unittest

from goal_model import build_goal_proxy


class GoalProxyTests(unittest.TestCase):
    def test_returns_probability_for_three_or_four_total_goals(self):
        result = build_goal_proxy(
            {
                "home": {"summary": {"matches": 10, "goalsFor": 12, "goalsAgainst": 8}},
                "away": {"summary": {"matches": 10, "goalsFor": 10, "goalsAgainst": 14}},
            }
        )
        self.assertTrue(result["available"])
        self.assertEqual(result["type"], "goals_proxy")
        self.assertGreater(result["pTotal3Or4"], 0)
        self.assertLess(result["pTotal3Or4"], 1)
        self.assertAlmostEqual(result["totalLambda"], result["homeLambda"] + result["awayLambda"], places=4)

    def test_marks_missing_recent_data_unavailable(self):
        result = build_goal_proxy({"home": {}, "away": {}})
        self.assertFalse(result["available"])
        self.assertIn("unavailable", result["reason"])


if __name__ == "__main__":
    unittest.main()
