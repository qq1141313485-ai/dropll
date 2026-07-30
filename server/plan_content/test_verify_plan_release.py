import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import verify_plan_release


class VerifyPlanReleaseTest(unittest.TestCase):
    def test_load_env_file_ignores_comments_and_unquotes_values(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env_path = Path(tmp) / "api.env"
            env_path.write_text(
                "# comment\n"
                "CAIMASTER_PLAN_ADMIN_TOKEN='secret-token'\n"
                "CAIMASTER_PLAN_SOURCE_ENABLED=1\n"
                "invalid\n",
                encoding="utf-8",
            )

            values = verify_plan_release._load_env_file(env_path)

        self.assertEqual(values["CAIMASTER_PLAN_ADMIN_TOKEN"], "secret-token")
        self.assertEqual(values["CAIMASTER_PLAN_SOURCE_ENABLED"], "1")
        self.assertNotIn("invalid", values)

    def test_verify_runs_expected_steps_with_env(self) -> None:
        calls = []

        def fake_runner(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env_path = root / "api.env"
            env_path.write_text(
                "CAIMASTER_PLAN_ADMIN_TOKEN=server-token\n",
                encoding="utf-8",
            )

            with patch.dict(os.environ, {}, clear=True):
                ok, results = verify_plan_release.verify(
                    root=root,
                    python_bin="/usr/bin/python3",
                    env_path=env_path,
                    base_url="https://api.cclloo.com",
                    runner=fake_runner,
                )

        self.assertTrue(ok)
        self.assertEqual([result.name for result in results], [
            "deploy check",
            "source sync dry-run",
            "app public API smoke",
        ])
        self.assertEqual(calls[0][1]["env"]["CAIMASTER_PLAN_ADMIN_TOKEN"], "server-token")
        self.assertEqual(calls[0][1]["env"]["CAIMASTER_API_APP"], str(root / "app.py"))
        self.assertEqual(calls[1][1]["env"]["CAIMASTER_PLAN_SOURCE_DRY_RUN"], "1")
        self.assertEqual(calls[2][0], [
            "/usr/bin/python3",
            "app_plan_smoke.py",
            "--base-url",
            "https://api.cclloo.com",
        ])

    def test_root_replaces_example_opt_paths_from_env_file(self) -> None:
        calls = []

        def fake_runner(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env_path = root / "api.env"
            env_path.write_text(
                "CAIMASTER_PLAN_DB=/opt/caimaster-api/plans.db\n"
                "CAIMASTER_PLAN_MEDIA=/opt/caimaster-api/plan-media\n",
                encoding="utf-8",
            )

            verify_plan_release.verify(
                root=root,
                python_bin="/usr/bin/python3",
                env_path=env_path,
                base_url="https://api.cclloo.com",
                skip_sync=True,
                skip_public=True,
                runner=fake_runner,
            )

        self.assertEqual(calls[0][1]["env"]["CAIMASTER_PLAN_DB"], str(root / "plans.db"))
        self.assertEqual(calls[0][1]["env"]["CAIMASTER_PLAN_MEDIA"], str(root / "plan-media"))

    def test_require_data_adds_strict_app_smoke(self) -> None:
        commands = []

        def fake_runner(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as tmp:
            ok, results = verify_plan_release.verify(
                root=Path(tmp),
                python_bin="/usr/bin/python3",
                env_path=Path(tmp) / "missing.env",
                base_url="https://api.cclloo.com",
                require_data=True,
                skip_sync=True,
                runner=fake_runner,
            )

        self.assertTrue(ok)
        self.assertEqual(results[-1].name, "app required-data smoke")
        self.assertIn("--require-data", commands[-1])

    def test_failed_step_makes_release_verification_fail(self) -> None:
        def fake_runner(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="bad")

        with tempfile.TemporaryDirectory() as tmp:
            ok, results = verify_plan_release.verify(
                root=Path(tmp),
                python_bin="/usr/bin/python3",
                env_path=Path(tmp) / "missing.env",
                base_url="https://api.cclloo.com",
                skip_sync=True,
                skip_public=True,
                runner=fake_runner,
            )

        self.assertFalse(ok)
        self.assertEqual(results[0].returncode, 1)
        self.assertEqual(results[0].stderr_tail, "bad")


if __name__ == "__main__":
    unittest.main()
