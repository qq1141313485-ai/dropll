import io
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import manage_api_env


class ManageApiEnvTest(unittest.TestCase):
    def test_init_generates_masked_token_and_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_path = Path(tmp) / "api.env"
            output = io.StringIO()

            with redirect_stdout(output):
                manage_api_env._init(env_path)

            text = env_path.read_text(encoding="utf-8")
            token_line = next(
                line for line in text.splitlines()
                if line.startswith("CAIMASTER_PLAN_ADMIN_TOKEN=")
            )
            token = token_line.split("=", 1)[1]
            self.assertNotIn(token, output.getvalue())
            self.assertIn("...", output.getvalue())
            self.assertIn("CAIMASTER_PLAN_SOURCE_ENABLED=0", text)
            self.assertEqual(
                stat.S_IMODE(os.stat(env_path).st_mode),
                stat.S_IRUSR | stat.S_IWUSR,
            )

    def test_set_token_rejects_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_path = Path(tmp) / "api.env"

            with self.assertRaises(SystemExit):
                manage_api_env._set_token(
                    env_path,
                    "replace-with-a-long-random-admin-token",
                )

    def test_show_masks_existing_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_path = Path(tmp) / "api.env"
            token = "abcdefghijklmnopqrstuvwxyz123456"
            env_path.write_text(
                f"CAIMASTER_PLAN_ADMIN_TOKEN={token}\n"
                "CAIMASTER_PLAN_SOURCE_ENABLED=1\n",
                encoding="utf-8",
            )
            output = io.StringIO()

            with redirect_stdout(output):
                manage_api_env._show(env_path)

            self.assertNotIn(token, output.getvalue())
            self.assertIn("abcd...3456", output.getvalue())
            self.assertIn("CAIMASTER_PLAN_SOURCE_ENABLED=1", output.getvalue())


if __name__ == "__main__":
    unittest.main()
