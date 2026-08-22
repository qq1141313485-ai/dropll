import sqlite3
import sys
import tempfile
import types
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock

try:
    import python_multipart  # noqa: F401
except ModuleNotFoundError:
    python_multipart = types.ModuleType("python_multipart")
    python_multipart.__version__ = "0.0.20"
    sys.modules["python_multipart"] = python_multipart

try:
    import fcntl  # noqa: F401
except ModuleNotFoundError:
    fcntl = types.ModuleType("fcntl")
    fcntl.LOCK_EX = 1
    fcntl.LOCK_NB = 2
    fcntl.flock = lambda *_: None
    sys.modules["fcntl"] = fcntl

try:
    import plans
    import plan_source_sync
    from plan_source_common import PlanNameRules
except ModuleNotFoundError as exc:
    IMPORT_ERROR = str(exc)
else:
    IMPORT_ERROR = ""


@unittest.skipIf(bool(IMPORT_ERROR), IMPORT_ERROR)
class PlanArticleMirrorTest(unittest.TestCase):
    def test_mirror_keeps_order_and_only_adds_a_changed_full_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "plans.db"
            media = root / "media"
            current_content = {"https://source/1": b"one", "https://source/2": b"two"}

            def connect() -> sqlite3.Connection:
                conn = sqlite3.connect(database)
                conn.row_factory = sqlite3.Row
                return conn

            def prepare(contents: bytes) -> tuple[bytes, bytes, int, int]:
                return contents + b"-original", contents + b"-thumb", 800, 1200

            article = {
                "id": "395790",
                "title": "20260823 未识别甲乙合集",
                "publishtime": 1787414400,
            }
            rules = PlanNameRules.from_mapping({"allowAutoCreate": False})
            with (
                mock.patch.object(plans, "PLAN_DB_PATH", database),
                mock.patch.object(plans, "PLAN_MEDIA_DIR", media),
                mock.patch.object(plan_source_sync, "PLAN_MEDIA_DIR", media),
                mock.patch.object(plan_source_sync, "_connect", connect),
                mock.patch.object(
                    plan_source_sync,
                    "_article_archive",
                    return_value={"publishtime": 1787414400},
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_article_image_urls",
                    return_value=["https://source/1", "https://source/2"],
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_request",
                    side_effect=lambda url: current_content[url],
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_prepare_image",
                    side_effect=prepare,
                ),
            ):
                plans._init_store()
                plan_source_sync._init_sync_store()
                with closing(connect()) as conn:
                    conn.execute(
                        """
                        INSERT INTO plan_sync_articles(
                            source_name, source_article_id, source_title,
                            published_at, status, synced_at
                        ) VALUES ('hongxisaishi', '395789',
                                  '20260820 历史待确认合集', 1787155200,
                                  'pending_name', 1787155200)
                        """
                    )
                    conn.execute(
                        """
                        INSERT INTO plan_sync_articles(
                            source_name, source_article_id, source_title,
                            plan_id, update_id, published_at, status, synced_at
                        ) VALUES ('hongxisaishi', '395790',
                                  '20260823 未识别甲乙合集', 99, 88,
                                  1787414400, 'imported', 1787414400)
                        """
                    )
                    conn.commit()
                backlog = plan_source_sync._fetch_mirror_backlog()

                first = plan_source_sync._sync_article_mirror(article, rules)
                unchanged = plan_source_sync._sync_article_mirror(article, rules)
                current_content["https://source/2"] = b"two-changed"
                changed = plan_source_sync._sync_article_mirror(article, rules)

            self.assertEqual((first, unchanged, changed), ("imported", "duplicate", "imported"))
            self.assertIn("395789", backlog)
            with closing(connect()) as conn:
                article_count = conn.execute(
                    "SELECT COUNT(*) FROM plan_articles"
                ).fetchone()[0]
                versions = conn.execute(
                    """
                    SELECT id FROM plan_article_versions
                    ORDER BY id
                    """
                ).fetchall()
                latest_positions = conn.execute(
                    """
                    SELECT position, source_url
                    FROM plan_article_images
                    WHERE version_id = ?
                    ORDER BY position
                    """,
                    (versions[-1]["id"],),
                ).fetchall()
                sync_row = conn.execute(
                    """
                    SELECT status, plan_id, update_id
                    FROM plan_sync_articles
                    WHERE source_article_id = '395790'
                    """
                ).fetchone()
            self.assertEqual(article_count, 1)
            self.assertEqual(len(versions), 2)
            self.assertEqual(
                [(row["position"], row["source_url"]) for row in latest_positions],
                [(0, "https://source/1"), (1, "https://source/2")],
            )
            self.assertEqual(sync_row["status"], "mirrored")
            self.assertEqual((sync_row["plan_id"], sync_row["update_id"]), (99, 88))
            self.assertEqual(len(list(media.glob("*.jpg"))), 8)


if __name__ == "__main__":
    unittest.main()
