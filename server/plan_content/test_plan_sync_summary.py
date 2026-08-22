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
        self.map_patch = patch.object(
            plans,
            "PLAN_SOURCE_MAP_PATH",
            root / "plan_source_map.json",
        )
        self.db_patch.start()
        self.media_patch.start()
        self.map_patch.start()
        plans._init_store()

    def tearDown(self) -> None:
        self.map_patch.stop()
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

    def test_mirror_backlog_only_counts_articles_after_cutover(self) -> None:
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
                    published_at, status, synced_at
                ) VALUES
                  ('source', 'old', '起点前', 99, 'imported', 99),
                  ('source', 'new', '起点后', 101, 'imported', 101),
                  ('source', 'done', '已镜像', 102, 'mirrored', 102);
                INSERT INTO plan_articles(
                    source_name, source_article_id, title, published_at,
                    is_active, created_at, updated_at
                ) VALUES ('source', 'done', '已镜像', 102, 1, 102, 102);
                """
            )
            conn.commit()
            with patch.object(plans, "PLAN_ARTICLE_MIRROR_SINCE", 100):
                result = plans._sync_governance_summary(conn, now=200)

        self.assertEqual(result["mirroredArticles"], 1)
        self.assertEqual(result["mirrorBacklog"], 1)

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

    def test_image_split_rule_is_saved_once_and_queues_same_name(self) -> None:
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
                INSERT INTO plan_sync_articles(
                    source_name, source_article_id, source_title,
                    raw_plan_name, status, synced_at
                ) VALUES
                  ('hongxisaishi', '10', '组合文章一', '甲，乙', 'pending_name', 1),
                  ('hongxisaishi', '11', '组合文章二', '甲，乙', 'pending_name', 2);
                """
            )
            conn.commit()

        with patch.object(
            plans,
            "_fetch_source_article_images",
            return_value=["https://one", "https://two", "https://three"],
        ):
            result = plans.admin_save_plan_image_assignment(
                {
                    "sourceArticleId": "10",
                    "rawPlanName": "甲，乙",
                    "targets": ["乙", plans.IGNORE_IMAGE_ASSIGNMENT, "甲"],
                }
            )

        self.assertEqual(result["updatedRows"], 2)
        self.assertEqual(result["planNames"], ["乙", "甲"])
        rules = plans._load_source_name_rules()
        self.assertEqual(
            rules["imageAssignments"]["甲，乙"],
            ["乙", plans.IGNORE_IMAGE_ASSIGNMENT, "甲"],
        )
        self.assertNotIn(plans.IGNORE_IMAGE_ASSIGNMENT, rules["allowedNames"])
        with closing(plans._connect()) as conn:
            statuses = conn.execute(
                "SELECT status FROM plan_sync_articles ORDER BY id"
            ).fetchall()
        self.assertEqual(
            [row["status"] for row in statuses],
            ["name_configured", "name_configured"],
        )

    def test_image_split_rejects_changed_image_count(self) -> None:
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
                    raw_plan_name, status, synced_at
                ) VALUES ('hongxisaishi', '20', '组合文章', '甲，乙', 'pending_name', 1);
                """
            )
            conn.commit()

        with patch.object(
            plans,
            "_fetch_source_article_images",
            return_value=["https://one", "https://two"],
        ):
            with self.assertRaises(plans.HTTPException) as raised:
                plans.admin_save_plan_image_assignment(
                    {
                        "sourceArticleId": "20",
                        "rawPlanName": "甲，乙",
                        "targets": ["甲"],
                    }
                )
        self.assertEqual(raised.exception.status_code, 409)


if __name__ == "__main__":
    unittest.main()
