import tempfile
import unittest
from pathlib import Path

import patch_api_app


class PatchApiAppTest(unittest.TestCase):
    def test_patch_inserts_import_and_route_call(self) -> None:
        source = (
            "from fastapi import FastAPI\n\n"
            "app = FastAPI(title='Caimaster')\n\n"
            "@app.get('/health')\n"
            "def health():\n"
            "    return {'ok': True}\n"
        )

        updated, changed = patch_api_app.patch_text(source)

        self.assertTrue(changed)
        self.assertIn("from plans import install_plan_routes", updated)
        self.assertIn("install_plan_routes(app)", updated)
        self.assertLess(
            updated.index("install_plan_routes(app)"),
            updated.index("@app.get('/health')"),
        )

    def test_patch_supports_multiline_fastapi_constructor(self) -> None:
        source = (
            "from fastapi import FastAPI\n\n"
            "app = FastAPI(\n"
            "    title='Caimaster',\n"
            "    version='1.0.0',\n"
            ")\n\n"
            "@app.get('/health')\n"
            "def health():\n"
            "    return {'ok': True}\n"
        )

        updated, changed = patch_api_app.patch_text(source)

        self.assertTrue(changed)
        self.assertIn("install_plan_routes(app)\n\n@app.get", updated)

    def test_patch_uses_detected_fastapi_variable_name(self) -> None:
        source = (
            "from fastapi import FastAPI\n\n"
            "application = FastAPI()\n"
        )

        updated, changed = patch_api_app.patch_text(source)

        self.assertTrue(changed)
        self.assertIn("install_plan_routes(application)", updated)
        self.assertNotIn("install_plan_routes(app)", updated)

    def test_patch_is_idempotent(self) -> None:
        source = (
            "from fastapi import FastAPI\n"
            "from plans import install_plan_routes\n\n"
            "app = FastAPI()\n"
            "install_plan_routes(app)\n"
        )

        updated, changed = patch_api_app.patch_text(source)

        self.assertFalse(changed)
        self.assertEqual(updated, source)

    def test_patch_file_creates_backup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app_path = Path(tmp) / "app.py"
            app_path.write_text(
                "from fastapi import FastAPI\napp = FastAPI()\n",
                encoding="utf-8",
            )

            changed = patch_api_app.patch_file(app_path)

            self.assertTrue(changed)
            self.assertIn("install_plan_routes(app)", app_path.read_text(encoding="utf-8"))
            backups = list(Path(tmp).glob("app.py.bak-plan-routes-*"))
            self.assertEqual(len(backups), 1)


if __name__ == "__main__":
    unittest.main()
