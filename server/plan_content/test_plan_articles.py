import tempfile
import unittest
import sys
import types
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

# The production requirements include python-multipart. The lightweight local
# test runtime may omit it; these tests never call the upload routes, so a tiny
# import-compatible stub is enough for FastAPI's route registration check.
try:
    import python_multipart  # noqa: F401
except ModuleNotFoundError:
    python_multipart = types.ModuleType("python_multipart")
    python_multipart.__version__ = "0.0.20"
    sys.modules["python_multipart"] = python_multipart

try:
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    import plans
except ModuleNotFoundError as exc:
    IMPORT_ERROR = str(exc)
else:
    IMPORT_ERROR = ""


@unittest.skipIf(bool(IMPORT_ERROR), IMPORT_ERROR)
class PlanArticleApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.db_patch = patch.object(plans, "PLAN_DB_PATH", root / "plans.db")
        self.media_patch = patch.object(plans, "PLAN_MEDIA_DIR", root / "media")
        self.db_patch.start()
        self.media_patch.start()
        plans._init_store()
        with closing(plans._connect()) as conn:
            conn.execute(
                """
                INSERT INTO plan_articles(
                    id, source_name, source_article_id, title, published_at,
                    is_active, created_at, updated_at
                ) VALUES (1, 'source', '100', '20260823 原文合集',
                          1787414400, 1, 1787414400, 1787418000)
                """
            )
            conn.executemany(
                """
                INSERT INTO plan_article_versions(
                    id, article_id, content_sha256, title, published_at,
                    captured_at, is_active
                ) VALUES (?, 1, ?, ?, 1787414400, ?, 1)
                """,
                [
                    (10, "old", "旧版本", 1787415000),
                    (11, "new", "20260823 原文合集", 1787418000),
                ],
            )
            conn.executemany(
                """
                INSERT INTO plan_article_images(
                    version_id, filename, thumbnail_filename, source_url,
                    content_sha256, position, width, height, is_active,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, 800, 1200, 1, 1787418000)
                """,
                [
                    (10, "old.jpg", "old_t.jpg", "https://source/old", "a", 0),
                    (11, "new_2.jpg", "new_2_t.jpg", "https://source/2", "b", 1),
                    (11, "new_1.jpg", "new_1_t.jpg", "https://source/1", "c", 0),
                ],
            )
            conn.commit()
        app = FastAPI()
        plans.install_plan_routes(app)
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.client.close()
        self.media_patch.stop()
        self.db_patch.stop()
        self.temporary.cleanup()

    def test_article_summary_uses_latest_complete_version(self) -> None:
        response = self.client.get("/v1/plan-articles/recent?limit=6")

        self.assertEqual(response.status_code, 200)
        item = response.json()["items"][0]
        self.assertEqual(item["contentType"], "article")
        self.assertEqual(item["name"], "20260823 原文合集")
        self.assertEqual(item["latestVersionId"], "11")
        self.assertEqual(item["latestImageCount"], 2)
        self.assertTrue(item["latestThumbnailUrl"].endswith("/new_1_t.jpg"))

    def test_article_search_and_version_image_order(self) -> None:
        search = self.client.get("/v1/plan-articles?q=原文合集")
        missing = self.client.get("/v1/plan-articles?q=不存在")
        versions = self.client.get("/v1/plan-articles/1/versions")

        self.assertEqual(search.status_code, 200)
        self.assertEqual(search.json()["count"], 1)
        self.assertEqual(missing.json()["count"], 0)
        self.assertEqual(versions.status_code, 200)
        items = versions.json()["items"]
        self.assertEqual([item["id"] for item in items], ["11", "10"])
        self.assertEqual(
            [image["position"] for image in items[0]["images"]],
            [0, 1],
        )


if __name__ == "__main__":
    unittest.main()
