import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import deploy_check


def _write_rules(path: Path) -> None:
    path.write_text(
        json.dumps(
            {
                "allowAutoCreate": False,
                "allowedNames": ["公牛"],
                "aliases": {"牛哥": "公牛"},
                "ignoredNames": ["测试"],
                "excludedTitleWords": [],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )


def _create_db(path: Path) -> None:
    with sqlite3.connect(path) as conn:
        conn.executescript(
            """
            CREATE TABLE plans(id INTEGER);
            CREATE TABLE plan_updates(id INTEGER);
            CREATE TABLE plan_images(id INTEGER);
            CREATE TABLE plan_sync_articles(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                status TEXT NOT NULL
            );
            CREATE TABLE plan_sync_images(id INTEGER);
            CREATE TABLE plan_sync_runs(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at INTEGER,
                finished_at INTEGER,
                status TEXT,
                candidates INTEGER,
                counts_json TEXT,
                error TEXT
            );
            INSERT INTO plan_sync_articles(status)
            VALUES ('pending_name'), ('name_configured'), ('failed'), ('retry_queued');
            INSERT INTO plan_sync_runs(started_at, finished_at, status, candidates, counts_json, error)
            VALUES (1, 2, 'ok', 4, '{"failed": 1, "pending_name": 2}', '');
            """
        )


class DeployCheckTest(unittest.TestCase):
    def test_placeholder_admin_token_is_error(self) -> None:
        checks: list[deploy_check.Check] = []
        with patch.dict(
            os.environ,
            {
                "CAIMASTER_PLAN_ADMIN_TOKEN": "replace-with-a-long-random-admin-token",
                "CAIMASTER_PLAN_SOURCE_ENABLED": "1",
            },
            clear=True,
        ):
            deploy_check._check_environment(checks)

        token_check = next(
            check for check in checks if check.name == "CAIMASTER_PLAN_ADMIN_TOKEN"
        )
        self.assertEqual(token_check.level, "error")
        self.assertIn("placeholder", token_check.detail)

    def test_valid_rules_are_summarized(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rules_path = Path(tmp) / "plan_source_map.json"
            _write_rules(rules_path)
            checks: list[deploy_check.Check] = []

            with patch.object(deploy_check, "PLAN_SOURCE_MAP", rules_path):
                deploy_check._check_source_rules(checks)

        self.assertEqual(checks[0].level, "ok")
        self.assertIn("aliases=1", checks[0].detail)
        self.assertIn("allowed=1", checks[0].detail)

    def test_database_check_reports_sync_backlog(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "plans.db"
            _create_db(db_path)
            checks: list[deploy_check.Check] = []

            with patch.object(deploy_check, "PLAN_DB_PATH", db_path):
                deploy_check._check_database(checks)

        by_name = {check.name: check for check in checks}
        self.assertEqual(by_name["plan database"].level, "ok")
        self.assertEqual(by_name["sync database"].level, "ok")
        self.assertEqual(by_name["pending names"].level, "warn")
        self.assertEqual(by_name["pending names"].detail, "2")
        self.assertEqual(by_name["failed articles"].level, "warn")
        self.assertEqual(by_name["failed articles"].detail, "1")
        self.assertEqual(by_name["retry queued"].detail, "1")
        self.assertIn("status=ok", by_name["latest sync run"].detail)

    def test_api_app_must_install_plan_routes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_path = root / "app.py"
            admin_html = root / "plan_admin.html"
            media_dir = root / "media"
            app_path.write_text("from fastapi import FastAPI\napp = FastAPI()\n")
            admin_html.write_text("<html></html>", encoding="utf-8")
            media_dir.mkdir()
            checks: list[deploy_check.Check] = []

            with patch.object(deploy_check, "API_APP_PATH", app_path), \
                    patch.object(deploy_check, "PLAN_ADMIN_HTML", admin_html), \
                    patch.object(deploy_check, "PLAN_MEDIA_DIR", media_dir), \
                    patch.object(deploy_check, "SERVICE_PATH", root / "sync.service"), \
                    patch.object(deploy_check, "TIMER_PATH", root / "sync.timer"):
                deploy_check._check_paths(checks)

        app_check = next(check for check in checks if check.name == "api app.py")
        self.assertEqual(app_check.level, "error")
        self.assertIn("install_plan_routes", app_check.detail)

    def test_api_app_route_installation_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_path = root / "app.py"
            admin_html = root / "plan_admin.html"
            media_dir = root / "media"
            app_path.write_text(
                "from plans import install_plan_routes\ninstall_plan_routes(app)\n",
                encoding="utf-8",
            )
            admin_html.write_text("<html></html>", encoding="utf-8")
            media_dir.mkdir()
            checks: list[deploy_check.Check] = []

            with patch.object(deploy_check, "API_APP_PATH", app_path), \
                    patch.object(deploy_check, "PLAN_ADMIN_HTML", admin_html), \
                    patch.object(deploy_check, "PLAN_MEDIA_DIR", media_dir), \
                    patch.object(deploy_check, "SERVICE_PATH", root / "sync.service"), \
                    patch.object(deploy_check, "TIMER_PATH", root / "sync.timer"):
                deploy_check._check_paths(checks)

        app_check = next(check for check in checks if check.name == "api app.py")
        self.assertEqual(app_check.level, "ok")


if __name__ == "__main__":
    unittest.main()
