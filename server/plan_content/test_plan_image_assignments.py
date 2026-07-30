import unittest
import sqlite3
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from plan_source_common import PlanNameRules, SourceError

try:
    import plan_source_sync
    from plan_source_sync import _image_plan_names
except ModuleNotFoundError as exc:
    plan_source_sync = None
    _image_plan_names = None
    IMPORT_ERROR = str(exc)
else:
    IMPORT_ERROR = ""


@unittest.skipIf(bool(IMPORT_ERROR), IMPORT_ERROR)
class PlanImageAssignmentTest(unittest.TestCase):
    def test_regular_plan_repeats_one_target_for_all_images(self) -> None:
        parsed = SimpleNamespace(
            name="平哥",
            raw_name="平哥早",
            image_plan_names=(),
        )

        self.assertEqual(
            _image_plan_names(parsed, ["one", "two"]),
            ["平哥", "平哥"],
        )

    def test_split_plan_requires_exact_image_count(self) -> None:
        parsed = SimpleNamespace(
            name="辉哥",
            raw_name="扫地僧，辉哥中赔",
            image_plan_names=("辉哥", "扫地僧"),
        )

        with self.assertRaisesRegex(
            SourceError,
            "expected 2 images, got 1",
        ):
            _image_plan_names(parsed, ["one"])

    def test_split_plan_preserves_configured_order(self) -> None:
        parsed = SimpleNamespace(
            name="辉哥",
            raw_name="扫地僧，辉哥中赔",
            image_plan_names=("辉哥", "扫地僧"),
        )

        self.assertEqual(
            _image_plan_names(parsed, ["one", "two"]),
            ["辉哥", "扫地僧"],
        )

    def test_sync_creates_one_update_per_assigned_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "plans.db"
            media = root / "media"
            media.mkdir()

            def connect() -> sqlite3.Connection:
                conn = sqlite3.connect(database)
                conn.row_factory = sqlite3.Row
                return conn

            with connect() as conn:
                conn.executescript(
                    """
                    CREATE TABLE plans (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        slug TEXT NOT NULL,
                        name TEXT NOT NULL,
                        uploader_name TEXT NOT NULL,
                        is_active INTEGER NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL
                    );
                    CREATE TABLE plan_aliases (
                        alias_plan_id INTEGER PRIMARY KEY,
                        canonical_plan_id INTEGER NOT NULL
                    );
                    CREATE TABLE plan_updates (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        plan_id INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        published_at INTEGER NOT NULL,
                        is_active INTEGER NOT NULL,
                        created_at INTEGER NOT NULL
                    );
                    CREATE TABLE plan_images (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        update_id INTEGER NOT NULL,
                        filename TEXT NOT NULL,
                        thumbnail_filename TEXT NOT NULL,
                        position INTEGER NOT NULL,
                        width INTEGER NOT NULL,
                        height INTEGER NOT NULL,
                        is_active INTEGER NOT NULL,
                        created_at INTEGER NOT NULL
                    );
                    CREATE TABLE plan_sync_images (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        source_name TEXT NOT NULL,
                        source_article_id TEXT NOT NULL,
                        source_url TEXT NOT NULL,
                        content_sha256 TEXT NOT NULL,
                        image_id INTEGER NOT NULL,
                        synced_at INTEGER NOT NULL,
                        UNIQUE(source_name, source_url),
                        UNIQUE(source_name, content_sha256)
                    );
                    CREATE TABLE plan_sync_article_updates (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        source_name TEXT NOT NULL,
                        source_article_id TEXT NOT NULL,
                        plan_name TEXT NOT NULL,
                        plan_id INTEGER NOT NULL,
                        update_id INTEGER NOT NULL,
                        created_at INTEGER NOT NULL,
                        UNIQUE(source_name, source_article_id, update_id)
                    );
                    CREATE TABLE plan_sync_articles (
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
                        synced_at INTEGER NOT NULL,
                        UNIQUE(source_name, source_article_id)
                    );
                    """
                )

            rules = PlanNameRules.from_mapping(
                {
                    "allowAutoCreate": False,
                    "imageAssignments": {
                        "扫地僧，辉哥中赔": [
                            "辉哥",
                            "__IGNORE__",
                            "扫地僧",
                        ],
                    },
                }
            )
            article = {
                "id": "395790",
                "title": "20260726扫地僧，辉哥中赔",
                "publishtime": 1785060000,
            }

            with (
                mock.patch.object(plan_source_sync, "_connect", connect),
                mock.patch.object(
                    plan_source_sync,
                    "PLAN_MEDIA_DIR",
                    media,
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_article_archive",
                    return_value={"publishtime": 1785060000},
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_article_image_urls",
                    return_value=[
                        "https://one",
                        "https://ignored",
                        "https://two",
                    ],
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_new_image_urls",
                    return_value=["https://one", "https://two"],
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_request",
                    side_effect=[b"one", b"two"],
                ),
                mock.patch.object(
                    plan_source_sync,
                    "_prepare_image",
                    side_effect=[
                        (b"one-original", b"one-thumb", 100, 200),
                        (b"two-original", b"two-thumb", 120, 220),
                    ],
                ),
            ):
                outcome = plan_source_sync._sync_article(article, rules)

            self.assertEqual(outcome, "imported")
            with connect() as conn:
                plans = conn.execute(
                    "SELECT name FROM plans ORDER BY id"
                ).fetchall()
                updates = conn.execute(
                    "SELECT plan_name FROM plan_sync_article_updates ORDER BY id"
                ).fetchall()
                images = conn.execute(
                    """
                    SELECT p.name, i.position
                    FROM plan_images i
                    JOIN plan_updates u ON u.id = i.update_id
                    JOIN plans p ON p.id = u.plan_id
                    ORDER BY p.id, i.position
                    """
                ).fetchall()
            self.assertEqual(
                [row["name"] for row in plans],
                ["辉哥", "扫地僧"],
            )
            self.assertEqual(
                [row["plan_name"] for row in updates],
                ["辉哥", "扫地僧"],
            )
            self.assertEqual(
                [(row["name"], row["position"]) for row in images],
                [("辉哥", 0), ("扫地僧", 0)],
            )
            self.assertEqual(len(list(media.glob("*.jpg"))), 4)


if __name__ == "__main__":
    unittest.main()
