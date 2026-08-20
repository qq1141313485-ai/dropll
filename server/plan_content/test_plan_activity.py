import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

try:
    from fastapi import HTTPException
    from starlette.requests import Request

    import plans
except ModuleNotFoundError as exc:
    raise unittest.SkipTest(f"server dependencies unavailable: {exc.name}") from exc


def _request() -> Request:
    return Request(
        {
            "type": "http",
            "scheme": "https",
            "server": ("api.example", 443),
            "client": ("127.0.0.1", 1234),
            "method": "GET",
            "path": "/v1/plans",
            "root_path": "",
            "query_string": b"",
            "headers": [],
        }
    )


class PlanActivityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        self.db_patch = patch.object(plans, "PLAN_DB_PATH", root / "plans.db")
        self.media_patch = patch.object(plans, "PLAN_MEDIA_DIR", root / "media")
        self.db_patch.start()
        self.media_patch.start()
        plans._init_store()

        now = datetime.now(plans.CHINA_TZ)
        recent = int(now.timestamp())
        history = int((now - timedelta(days=8)).timestamp())
        with plans._connect() as conn:
            conn.executescript(
                """
                INSERT INTO plans(id, slug, name, uploader_name, is_active, created_at, updated_at)
                VALUES
                  (1, 'recent', '近期计划', '球镜助手', 1, 1, 1),
                  (2, 'history', '历史计划', '球镜助手', 1, 1, 1);
                """
            )
            for plan_id, published_at in ((1, recent), (2, history)):
                conn.execute(
                    """
                    INSERT INTO plan_updates(
                        id, plan_id, title, published_at, is_active, created_at
                    ) VALUES (?, ?, '更新', ?, 1, ?)
                    """,
                    (plan_id, plan_id, published_at, published_at),
                )
                conn.execute(
                    """
                    INSERT INTO plan_images(
                        id, update_id, filename, thumbnail_filename, position,
                        width, height, is_active, created_at
                    ) VALUES (?, ?, ?, ?, 0, 100, 200, 1, ?)
                    """,
                    (
                        plan_id,
                        plan_id,
                        f"{plan_id}.jpg",
                        f"{plan_id}_thumb.jpg",
                        published_at,
                    ),
                )
            conn.commit()

    def tearDown(self) -> None:
        self.media_patch.stop()
        self.db_patch.stop()
        self.temp_dir.cleanup()

    def _list(self, activity: str, ids: str = "") -> list[str]:
        body = plans.list_plans(
            _request(),
            q="",
            ids=ids,
            activity=activity,
            limit=20,
            offset=0,
        )
        return [item["id"] for item in body["items"]]

    def test_recent_and_history_are_separated(self) -> None:
        self.assertEqual(self._list("recent"), ["1"])
        self.assertEqual(self._list("history"), ["2"])
        self.assertEqual(self._list("all"), ["1", "2"])

    def test_id_lookup_ignores_activity_filter(self) -> None:
        self.assertEqual(self._list("recent", ids="2"), ["2"])

    def test_invalid_activity_is_rejected(self) -> None:
        with self.assertRaises(HTTPException) as raised:
            self._list("unknown")
        self.assertEqual(raised.exception.status_code, 400)


if __name__ == "__main__":
    unittest.main()
