import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

try:
    import plans
except ModuleNotFoundError as exc:
    raise unittest.SkipTest(f"server dependencies unavailable: {exc.name}") from exc


class PlanSyncSummaryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        self.db_patch = patch.object(plans, "PLAN_DB_PATH", root / "plans.db")
        self.media_patch = patch.object(plans, "PLAN_MEDIA_DIR", root / "media")
        self.db_patch.start()
        self.media_patch.start()
        plans._init_store()

    def tearDown(self) -> None:
        self.media_patch.stop()
        self.db_patch.stop()
        self.temp_dir.cleanup()

    def test_governance_separates_articles_names_ages_and_visibility(self) -> None:
        now = 2_000_000_000
        with closing(plans._connect()) as conn:
            conn.executescript(
                """
                CREATE TABLE plan_sync_articles(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_name TEXT NOT NULL,
                    source_article_id TEXT NOT NULL,
                    source_title TEXT NOT NULL,
                    raw_plan_name TEXT NOT NULL DEFAULT '',
                    resolved_plan_name TEXT NOT NULL DEFAULT '',
                    plan_id INTEGER,
                    update_id INTEGER,
                    published_at INTEGER,
                    status TEXT NOT NULL,
                    error TEXT NOT NULL DEFAULT '',
                    needs_review INTEGER NOT NULL DEFAULT 0,
                    synced_at INTEGER NOT NULL
                );
                """
            )
            rows = (
                ("1", "公牛", "pending_name", now - 60),
                ("2", "公牛", "pending_name", now - 8 * 24 * 60 * 60),
                ("3", "凤凰", "name_configured", now - 2 * 24 * 60 * 60),
                ("4", "失败项", "failed", now - 60),
                ("5", "重试项", "retry_queued", now - 60),
                ("6", "", "pending_name", now - 60),
            )
            conn.executemany(
                """
                INSERT INTO plan_sync_articles(
                    source_name, source_article_id, source_title,
                    raw_plan_name, status, synced_at
                ) VALUES ('source', ?, 'title', ?, ?, ?)
                """,
                rows,
            )
            conn.executescript(
                """
                INSERT INTO plans(
                    id, slug, name, uploader_name, is_active, created_at, updated_at
                ) VALUES
                  (1, 'visible', '可见', '球镜助手', 1, 1, 1),
                  (2, 'hidden', '无图', '球镜助手', 1, 1, 1),
                  (3, 'inactive', '已下架', '球镜助手', 0, 1, 1);
                INSERT INTO plan_updates(
                    id, plan_id, title, published_at, is_active, created_at
                ) VALUES (1, 1, '更新', 1, 1, 1);
                INSERT INTO plan_images(
                    id, update_id, filename, thumbnail_filename, position,
                    width, height, is_active, created_at
                ) VALUES (1, 1, '1.jpg', '1_thumb.jpg', 0, 100, 200, 1, 1);
                """
            )
            conn.commit()

            result = plans._sync_governance_summary(conn, now=now)

        self.assertEqual(result["pendingArticles"], 4)
        self.assertEqual(result["pendingDistinctNames"], 2)
        self.assertEqual(result["pendingUnidentifiedArticles"], 1)
        self.assertEqual(result["pendingLast24Hours"], 2)
        self.assertEqual(result["pendingLast7Days"], 3)
        self.assertEqual(result["pendingOlderThan7Days"], 1)
        self.assertEqual(result["failedArticles"], 1)
        self.assertEqual(result["retryQueued"], 1)
        self.assertEqual(result["activePlans"], 2)
        self.assertEqual(result["visiblePlans"], 1)
        self.assertEqual(result["hiddenActivePlans"], 1)
        self.assertEqual(result["topPendingNames"][0]["name"], "公牛")
        self.assertEqual(result["topPendingNames"][0]["articleCount"], 2)

    def test_empty_governance_shape_is_stable(self) -> None:
        self.assertEqual(
            plans._empty_sync_governance()["pendingDistinctNames"],
            0,
        )
        self.assertEqual(plans._empty_sync_governance()["topPendingNames"], [])

    def test_pending_names_are_grouped_for_nontechnical_admin(self) -> None:
        with closing(plans._connect()) as conn:
            conn.executescript(
                """
                CREATE TABLE plan_sync_articles(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_name TEXT NOT NULL,
                    source_article_id TEXT NOT NULL,
                    source_title TEXT NOT NULL,
                    raw_plan_name TEXT NOT NULL DEFAULT '',
                    resolved_plan_name TEXT NOT NULL DEFAULT '',
                    plan_id INTEGER,
                    update_id INTEGER,
                    published_at INTEGER,
                    status TEXT NOT NULL,
                    error TEXT NOT NULL DEFAULT '',
                    needs_review INTEGER NOT NULL DEFAULT 0,
                    synced_at INTEGER NOT NULL
                );
                INSERT INTO plan_sync_articles(
                    source_name, source_article_id, source_title,
                    raw_plan_name, status, error, synced_at
                ) VALUES
                  ('source', '1', '旧文章', '公牛', 'pending_name', '待确认', 10),
                  ('source', '2', '新文章', '公牛', 'pending_name', '待确认', 20),
                  ('source', '3', '凤凰文章', '凤凰', 'pending_name', '待确认', 15),
                  ('source', '4', '无名称', '', 'pending_name', '待确认', 30),
                  ('source', '5', '已处理', '公牛', 'imported', '', 40);
                """
            )
            conn.commit()

        result = plans.admin_list_pending_plan_names(
            q="",
            limit=20,
            offset=0,
        )

        self.assertEqual(result["totalNames"], 2)
        self.assertEqual(result["unidentifiedArticles"], 1)
        self.assertFalse(result["hasMore"])
        self.assertEqual(result["items"][0]["rawPlanName"], "公牛")
        self.assertEqual(result["items"][0]["articleCount"], 2)
        self.assertEqual(result["items"][0]["sampleTitle"], "新文章")

        filtered = plans.admin_list_pending_plan_names(
            q="凤",
            limit=20,
            offset=0,
        )
        self.assertEqual(filtered["totalNames"], 1)
        self.assertEqual(filtered["items"][0]["rawPlanName"], "凤凰")


if __name__ == "__main__":
    unittest.main()
