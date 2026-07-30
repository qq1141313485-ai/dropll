import tempfile
import unittest
from pathlib import Path

from patch_api_app import PatchError, patch_file, patch_text


class PatchApiAppTests(unittest.TestCase):
    def test_patches_multiline_fastapi_assignment(self):
        source = (
            "from fastapi import FastAPI\n\n"
            "app = FastAPI(\n"
            "    title='Caimaster',\n"
            ")\n\n"
            "@app.get('/health')\n"
            "def health():\n"
            "    return {'ok': True}\n"
        )

        updated, changed = patch_text(source)

        self.assertTrue(changed)
        self.assertIn(
            "from match_analysis import install_match_analysis_routes", updated
        )
        self.assertIn("install_match_analysis_routes(app)", updated)
        self.assertLess(
            updated.index("install_match_analysis_routes(app)"),
            updated.index("@app.get('/health')"),
        )

    def test_patch_is_idempotent(self):
        source = (
            "from fastapi import FastAPI\n"
            "from match_analysis import install_match_analysis_routes\n"
            "app = FastAPI()\n"
            "install_match_analysis_routes(app)\n"
        )

        updated, changed = patch_text(source)

        self.assertFalse(changed)
        self.assertEqual(updated, source)

    def test_patch_file_requires_fastapi_app(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.py"
            path.write_text("print('hello')\n", encoding="utf-8")
            with self.assertRaises(PatchError):
                patch_file(path)


if __name__ == "__main__":
    unittest.main()
