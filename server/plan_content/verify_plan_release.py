from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


DEFAULT_BASE_URL = os.environ.get(
    "CAIMASTER_API_BASE_URL",
    os.environ.get("API_BASE_URL", "https://api.cclloo.com"),
).rstrip("/")
DEFAULT_ROOT = Path(__file__).resolve().parent
DEFAULT_ENV_PATH = DEFAULT_ROOT / "api.env"


@dataclass
class StepResult:
    name: str
    command: list[str]
    returncode: int
    skipped: bool = False
    stdout_tail: str = ""
    stderr_tail: str = ""

    @property
    def ok(self) -> bool:
        return self.skipped or self.returncode == 0


Runner = Callable[..., subprocess.CompletedProcess[str]]


def _load_env_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'\"")
        if key:
            values[key] = value
    return values


def _tail(value: str, *, limit: int = 2400) -> str:
    value = value.strip()
    if len(value) <= limit:
        return value
    return value[-limit:]


def _set_root_path_default(env: dict[str, str], key: str, root_path: Path) -> None:
    current = env.get(key, "")
    if not current or current.startswith("/opt/caimaster-api/"):
        env[key] = str(root_path)


def _run_step(
    name: str,
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    runner: Runner,
    timeout: int,
) -> StepResult:
    try:
        completed = runner(
            command,
            cwd=str(cwd),
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return StepResult(
            name=name,
            command=command,
            returncode=124,
            stdout_tail=_tail(stdout),
            stderr_tail=_tail(stderr or f"timeout after {timeout}s"),
        )
    return StepResult(
        name=name,
        command=command,
        returncode=completed.returncode,
        stdout_tail=_tail(completed.stdout),
        stderr_tail=_tail(completed.stderr),
    )


def verify(
    *,
    root: Path = DEFAULT_ROOT,
    python_bin: str = sys.executable,
    env_path: Path = DEFAULT_ENV_PATH,
    base_url: str = DEFAULT_BASE_URL,
    require_data: bool = False,
    skip_sync: bool = False,
    skip_public: bool = False,
    timeout: int = 180,
    runner: Runner = subprocess.run,
) -> tuple[bool, list[StepResult]]:
    env = {
        **os.environ,
        **_load_env_file(env_path),
        "CAIMASTER_API_BASE_URL": base_url.rstrip("/"),
    }
    _set_root_path_default(env, "CAIMASTER_API_APP", root / "app.py")
    _set_root_path_default(env, "CAIMASTER_PLAN_ADMIN_HTML", root / "plan_admin.html")
    _set_root_path_default(env, "CAIMASTER_PLAN_DB", root / "plans.db")
    _set_root_path_default(env, "CAIMASTER_PLAN_MEDIA", root / "plan-media")
    _set_root_path_default(env, "CAIMASTER_PLAN_SOURCE_MAP", root / "plan_source_map.json")
    results: list[StepResult] = []

    results.append(
        _run_step(
            "deploy check",
            [python_bin, "deploy_check.py"],
            cwd=root,
            env=env,
            runner=runner,
            timeout=timeout,
        )
    )

    if skip_sync:
        results.append(
            StepResult("source sync dry-run", [python_bin, "plan_source_sync.py"], 0, skipped=True)
        )
    else:
        sync_env = {**env, "CAIMASTER_PLAN_SOURCE_DRY_RUN": "1"}
        results.append(
            _run_step(
                "source sync dry-run",
                [python_bin, "plan_source_sync.py"],
                cwd=root,
                env=sync_env,
                runner=runner,
                timeout=timeout,
            )
        )

    if skip_public:
        results.append(
            StepResult("app public API smoke", [python_bin, "app_plan_smoke.py"], 0, skipped=True)
        )
    else:
        smoke_command = [
            python_bin,
            "app_plan_smoke.py",
            "--base-url",
            base_url.rstrip("/"),
        ]
        results.append(
            _run_step(
                "app public API smoke",
                smoke_command,
                cwd=root,
                env=env,
                runner=runner,
                timeout=timeout,
            )
        )

    if require_data:
        results.append(
            _run_step(
                "app required-data smoke",
                [
                    python_bin,
                    "app_plan_smoke.py",
                    "--base-url",
                    base_url.rstrip("/"),
                    "--require-data",
                ],
                cwd=root,
                env=env,
                runner=runner,
                timeout=timeout,
            )
        )

    ok = all(result.ok for result in results)
    return ok, results


def _print_text(results: list[StepResult]) -> None:
    for result in results:
        level = "SKIP" if result.skipped else ("OK" if result.ok else "ERROR")
        print(f"[{level}] {result.name}: {' '.join(result.command)}")
        if result.stdout_tail:
            print(result.stdout_tail)
        if result.stderr_tail:
            print(result.stderr_tail, file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run plan-content release verification.")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="Directory containing plan scripts")
    parser.add_argument("--python", default=sys.executable, help="Python executable for checks")
    parser.add_argument("--env", default=str(DEFAULT_ENV_PATH), help="api.env path to load")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--require-data", action="store_true")
    parser.add_argument("--skip-sync", action="store_true")
    parser.add_argument("--skip-public", action="store_true")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    ok, results = verify(
        root=Path(args.root),
        python_bin=args.python,
        env_path=Path(args.env),
        base_url=args.base_url.rstrip("/"),
        require_data=args.require_data,
        skip_sync=args.skip_sync,
        skip_public=args.skip_public,
        timeout=args.timeout,
    )

    if args.json:
        print(
            json.dumps(
                {
                    "ok": ok,
                    "baseUrl": args.base_url.rstrip("/"),
                    "results": [
                        {
                            "name": result.name,
                            "command": result.command,
                            "returncode": result.returncode,
                            "skipped": result.skipped,
                            "stdoutTail": result.stdout_tail,
                            "stderrTail": result.stderr_tail,
                        }
                        for result in results
                    ],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        _print_text(results)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
