from __future__ import annotations

import argparse
import os
import secrets
import stat
import sys
from pathlib import Path


DEFAULT_ENV_PATH = Path(os.environ.get("CAIMASTER_API_ENV", "/opt/caimaster-api/api.env"))
DEFAULTS = {
    "CAIMASTER_PLAN_DB": "/opt/caimaster-api/plans.db",
    "CAIMASTER_PLAN_MEDIA": "/opt/caimaster-api/plan-media",
    "CAIMASTER_PLAN_ADMIN_HTML": "/opt/caimaster-api/plan_admin.html",
    "CAIMASTER_PLAN_SOURCE_ENABLED": "0",
    "CAIMASTER_PLAN_SOURCE_API": "https://api.tchongxi.com",
    "CAIMASTER_PLAN_SOURCE_MAX_PAGES": "30",
    "CAIMASTER_PLAN_SOURCE_LOOKBACK_DAYS": "2",
    "CAIMASTER_PLAN_SOURCE_QUEUED_RETRY_LIMIT": "100",
    "CAIMASTER_PLAN_SOURCE_DRY_RUN": "0",
    "CAIMASTER_PLAN_SOURCE_MAP": "/opt/caimaster-api/plan_source_map.json",
    "CAIMASTER_PLAN_SOURCE_LOCK": "/tmp/caimaster-plan-source-sync.lock",
    "CAIMASTER_PLAN_SOURCE_TIMEOUT_SECONDS": "20",
    "CAIMASTER_PLAN_SOURCE_LOG_LEVEL": "INFO",
}


def _read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def _write_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered_keys = ["CAIMASTER_PLAN_ADMIN_TOKEN", *DEFAULTS.keys()]
    lines = []
    emitted = set()
    for key in ordered_keys:
        if key in values:
            lines.append(f"{key}={values[key]}")
            emitted.add(key)
            if key == "CAIMASTER_PLAN_ADMIN_TOKEN":
                lines.append("")
    for key in sorted(set(values) - emitted):
        lines.append(f"{key}={values[key]}")
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    temporary.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    os.replace(temporary, path)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def _mask(value: str) -> str:
    if not value:
        return "(empty)"
    if value.startswith("replace-with-"):
        return "(placeholder)"
    if len(value) <= 8:
        return "****"
    return f"{value[:4]}...{value[-4:]} (length {len(value)})"


def _generate_token() -> str:
    return secrets.token_urlsafe(32)


def _init(path: Path, *, rotate_token: bool = False) -> None:
    values = _read_env(path)
    for key, value in DEFAULTS.items():
        values.setdefault(key, value)
    token = values.get("CAIMASTER_PLAN_ADMIN_TOKEN", "")
    if rotate_token or not token or token.startswith("replace-with-"):
        values["CAIMASTER_PLAN_ADMIN_TOKEN"] = _generate_token()
    _write_env(path, values)
    print(f"Updated {path}")
    print(f"CAIMASTER_PLAN_ADMIN_TOKEN={_mask(values['CAIMASTER_PLAN_ADMIN_TOKEN'])}")


def _set_token(path: Path, token: str | None) -> None:
    values = _read_env(path)
    for key, value in DEFAULTS.items():
        values.setdefault(key, value)
    values["CAIMASTER_PLAN_ADMIN_TOKEN"] = token.strip() if token else _generate_token()
    if values["CAIMASTER_PLAN_ADMIN_TOKEN"].startswith("replace-with-"):
        raise SystemExit("Refusing to set placeholder admin token.")
    _write_env(path, values)
    print(f"Updated {path}")
    print(f"CAIMASTER_PLAN_ADMIN_TOKEN={_mask(values['CAIMASTER_PLAN_ADMIN_TOKEN'])}")


def _show(path: Path) -> None:
    values = _read_env(path)
    if not values:
        print(f"{path} does not exist or has no variables")
        return
    for key in ["CAIMASTER_PLAN_ADMIN_TOKEN", *DEFAULTS.keys()]:
        if key not in values:
            continue
        value = _mask(values[key]) if key == "CAIMASTER_PLAN_ADMIN_TOKEN" else values[key]
        print(f"{key}={value}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage /opt/caimaster-api/api.env safely.")
    parser.add_argument("--env", default=str(DEFAULT_ENV_PATH), help="Path to api.env")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init", help="Create or fill missing plan env values")
    init_parser.add_argument("--rotate-token", action="store_true")

    token_parser = subparsers.add_parser("set-token", help="Set or generate admin token")
    token_parser.add_argument("--token", default=None, help="Use a provided token instead of generating one")

    subparsers.add_parser("show", help="Show env values with token masked")

    args = parser.parse_args()
    path = Path(args.env)
    if args.command == "init":
        _init(path, rotate_token=args.rotate_token)
    elif args.command == "set-token":
        _set_token(path, args.token)
    elif args.command == "show":
        _show(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
