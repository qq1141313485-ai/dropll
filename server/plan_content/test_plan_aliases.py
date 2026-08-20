import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    from starlette.requests import Request

    import plan_source_sync
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


class PlanAliasTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        self.db_path = root / "plans.db"
        self.media_dir = root / "media"
        self.db_patch = patch.object(plans, "PLAN_DB_PATH", self.db_path)
        self.media_patch = patch.object(plans, "PLAN_MEDIA_DIR", self.media_dir)
        self.db_patch.start()
        self.media_patch.start()
        plans._init_store()
        with plans._connect() as conn:
            conn.executescript(
                """
                INSERT INTO plans(id, slug, name, uploader_name, is_active, created_at, updated_at)
                VALUES
                  (1, 'target', '标准计划', '球镜助手', 1, 1, 1),
                  (2, 'source', '旧名称晚场', '球镜助手', 1, 1, 2);
                INSERT INTO plan_updates(id, plan_id, title, published_at, is_active, created_at)
                VALUES (10, 2, '今日更新', 2, 1, 2);
                INSERT INTO plan_images(
                    id, update_id, filename, thumbnail_filename, position,
                    width, height, is_active, created_at
                ) VALUES (20, 10, 'a.jpg', 'a_thumb.jpg', 0, 100, 200, 1, 2);
                """
            )
            conn.commit()

    def tearDown(self) -> None:
        self.media_patch.stop()
        self.db_patch.stop()
        self.temp_dir.cleanup()

    def test_preview_does_not_modify_data(self) -> None:
        preview = plans.merge_plan(
            2,
            {"targetPlanId": "1", "execute": False},
        )

        self.assertFalse(preview["executed"])
        self.assertEqual(preview["updateCount"], 1)
        self.assertEqual(preview["imageCount"], 1)
        with plans._connect() as conn:
            self.assertEqual(
                conn.execute("SELECT plan_id FROM plan_updates WHERE id = 10").fetchone()[0],
                2,
            )
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM plan_aliases").fetchone()[0], 0)

    def test_merge_preserves_old_id_for_public_api_and_sync(self) -> None:
        result = plans.merge_plan(
            2,
            {"targetPlanId": "1", "execute": True},
        )

        self.assertTrue(result["executed"])
        summary = plans.list_plans(
            _request(),
            q="",
            ids="2",
            activity="all",
            limit=20,
            offset=0,
        )
        self.assertEqual(summary["items"][0]["id"], "1")
        self.assertEqual(summary["items"][0]["aliasIds"], ["2"])
        updates = plans.plan_updates(
            _request(),
            2,
            days=None,
            limit=10,
            offset=0,
        )
        self.assertEqual(updates["plan"]["id"], "1")
        self.assertEqual(updates["plan"]["aliasIds"], ["2"])

        with plans._connect() as conn:
            resolved = plan_source_sync._find_or_create_plan(
                conn,
                "旧名称晚场",
                3,
            )
            self.assertEqual(resolved, 1)
            self.assertEqual(
                conn.execute("SELECT is_active FROM plans WHERE id = 2").fetchone()[0],
                0,
            )


if __name__ == "__main__":
    unittest.main()
