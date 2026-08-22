import unittest
from unittest.mock import patch

import app_plan_smoke


def _summary(plan_id: str = "12") -> dict:
    return {
        "id": plan_id,
        "slug": f"plan-{plan_id}",
        "name": "单刀",
        "uploaderName": "球镜助手",
        "latestUpdatedAt": "2026-07-25T16:20+08:00",
        "updatedToday": True,
        "latestImageCount": 2,
        "latestThumbnailUrl": "https://api.cclloo.com/media/plans/thumb.jpg",
    }


def _updates_body() -> dict:
    return {
        "plan": {
            "id": "12",
            "slug": "plan-12",
            "name": "单刀",
            "uploaderName": "球镜助手",
        },
        "items": [
            {
                "id": "31",
                "title": "今日更新",
                "publishedAt": "2026-07-25T16:20+08:00",
                "images": [
                    {
                        "id": 101,
                        "imageUrl": "https://api.cclloo.com/media/plans/image.jpg",
                        "thumbnailUrl": "https://api.cclloo.com/media/plans/thumb.jpg",
                        "width": 900,
                        "height": 1400,
                        "position": 0,
                    }
                ],
            }
        ],
        "count": 1,
        "hasMore": False,
    }


class AppPlanSmokeTest(unittest.TestCase):
    def test_smoke_passes_with_valid_plan_payloads(self) -> None:
        def fake_request(base_url, path, query=None):
            if path == "/v1/plans/recent":
                return {"items": [_summary()]}
            if path == "/v1/plans":
                if query and query.get("q") == "__NO_SUCH_PLAN_987654__":
                    return {"items": []}
                return {"items": [_summary()]}
            if path == "/v1/plans/12/updates":
                return _updates_body()
            raise AssertionError(path)

        with patch.object(app_plan_smoke, "_request_json", side_effect=fake_request):
            ok, checks = app_plan_smoke.run(
                "https://api.cclloo.com",
                require_data=True,
            )

        self.assertTrue(ok)
        self.assertEqual(
            [check.level for check in checks],
            ["ok", "ok", "ok", "ok"],
        )

    def test_empty_recent_is_warning_without_required_data(self) -> None:
        with patch.object(
            app_plan_smoke,
            "_request_json",
            return_value={"items": []},
        ):
            ok, checks = app_plan_smoke.run("https://api.cclloo.com")

        self.assertTrue(ok)
        self.assertEqual(checks[0].level, "warn")
        self.assertEqual(checks[0].name, "recent plans")

    def test_missing_image_url_fails_update_validation(self) -> None:
        body = _updates_body()
        body["items"][0]["images"][0].pop("imageUrl")

        def fake_request(base_url, path, query=None):
            if path == "/v1/plans/recent":
                return {"items": [_summary()]}
            if path == "/v1/plans":
                if query and query.get("q") == "__NO_SUCH_PLAN_987654__":
                    return {"items": []}
                return {"items": [_summary()]}
            if path == "/v1/plans/12/updates":
                return body
            raise AssertionError(path)

        with patch.object(app_plan_smoke, "_request_json", side_effect=fake_request):
            ok, checks = app_plan_smoke.run(
                "https://api.cclloo.com",
                require_data=True,
            )

        self.assertFalse(ok)
        self.assertEqual(checks[-1].level, "error")
        self.assertIn("missing fields", checks[-1].detail)

    def test_ignored_name_query_fails_search_check(self) -> None:
        def fake_request(base_url, path, query=None):
            if path == "/v1/plans/recent":
                return {"items": [_summary()]}
            if path == "/v1/plans":
                return {"items": [_summary()]}
            if path == "/v1/plans/12/updates":
                return _updates_body()
            raise AssertionError(path)

        with patch.object(app_plan_smoke, "_request_json", side_effect=fake_request):
            ok, checks = app_plan_smoke.run("https://api.cclloo.com")

        self.assertFalse(ok)
        search_check = next(
            check for check in checks if check.name == "plan name search"
        )
        self.assertEqual(search_check.level, "error")
        self.assertIn("missing-name query returned items", search_check.detail)


if __name__ == "__main__":
    unittest.main()
