import unittest

from patch_api_app import PatchError, patch_text


class PatchApiAppTest(unittest.TestCase):
    def test_patches_fastapi_app_once(self):
        source = "from fastapi import FastAPI\n\napp = FastAPI(title='Cai')\n"
        updated, changed = patch_text(source)
        self.assertTrue(changed)
        self.assertIn("from market_odds import install_market_odds_routes", updated)
        self.assertIn("install_market_odds_routes(app)", updated)
        second, changed_again = patch_text(updated)
        self.assertFalse(changed_again)
        self.assertEqual(second, updated)

    def test_requires_fastapi_assignment(self):
        with self.assertRaises(PatchError):
            patch_text("print('no app')\n")

    def test_import_is_not_inserted_after_local_import(self):
        source = (
            "from fastapi import FastAPI\n\n"
            "app = FastAPI()\n\n"
            "def later():\n"
            "    from pathlib import Path\n"
        )
        updated, _ = patch_text(source)
        self.assertLess(
            updated.index("from market_odds import install_market_odds_routes"),
            updated.index("app = FastAPI()"),
        )


if __name__ == "__main__":
    unittest.main()
