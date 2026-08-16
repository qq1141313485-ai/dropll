#!/usr/bin/env python3
"""Resolve explicitly mapped teams and cache their badges locally."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _json(url: str, attempts: int = 3) -> dict[str, Any]:
    last_error: Exception | None = None
    for attempt in range(attempts):
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/json",
                "User-Agent": "caimaster-sync/1",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except Exception as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(2**attempt)
    assert last_error is not None
    raise last_error


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        path.chmod(0o644)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _source_team(query: str, api_key: str, expected_id: str) -> dict[str, Any]:
    # The mapping is an approved source identity. Name search can return a
    # reserve or women's team with the same alias, so resolve the exact ID.
    del query
    parameters = urllib.parse.urlencode({"id": expected_id})
    url = (
        f"https://www.thesportsdb.com/api/v1/json/{api_key}/"
        f"lookupteam.php?{parameters}"
    )
    teams = [
        item
        for item in (_json(url).get("teams") or [])
        if isinstance(item, dict)
    ]
    exact = [item for item in teams if str(item.get("idTeam") or "") == expected_id]
    if len(exact) != 1:
        raise ValueError(
            f"expected source team {expected_id}, received "
            f"{[item.get('idTeam') for item in teams]}"
        )
    return exact[0]


def _badge_suffix(url: str) -> str:
    suffix = Path(urllib.parse.urlparse(url).path).suffix.lower()
    if suffix in {".png", ".jpg", ".jpeg", ".webp"}:
        return suffix
    content_type, _ = mimetypes.guess_type(url)
    return mimetypes.guess_extension(content_type or "") or ".img"


def _download_badge(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    command = [
        "curl",
        "-4",
        "-L",
        "--fail",
        "--silent",
        "--show-error",
        "--connect-timeout",
        "15",
        "--max-time",
        "45",
        "--output",
        str(temporary),
        url,
    ]
    try:
        subprocess.run(command, check=True)
        if temporary.stat().st_size < 256:
            raise ValueError("downloaded badge is unexpectedly small")
        os.replace(temporary, destination)
        destination.chmod(0o644)
    finally:
        temporary.unlink(missing_ok=True)


def sync(
    aliases_path: Path,
    output_dir: Path,
    api_key: str,
    delay: float,
    *,
    refresh_existing: bool = False,
    names: set[str] | None = None,
) -> dict[str, Any]:
    aliases = json.loads(aliases_path.read_text(encoding="utf-8"))
    if not isinstance(aliases, dict):
        raise ValueError("alias file must contain an object")
    badges_dir = output_dir / "badges"
    existing_teams: dict[str, Any] = {}
    manifest_path = output_dir / "manifest.json"
    try:
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        if isinstance(existing.get("teams"), dict):
            existing_teams = existing["teams"]
    except (FileNotFoundError, OSError, json.JSONDecodeError, AttributeError):
        pass
    # Incremental runs retain already-verified mappings not requested in this batch.
    manifest_items: dict[str, Any] = dict(existing_teams) if names is not None else {}
    errors: list[dict[str, str]] = []
    retained_count = 0
    cached_count = 0

    for index, (local_name, mapping) in enumerate(sorted(aliases.items())):
        if names is not None and local_name not in names:
            continue
        if index:
            time.sleep(max(0, delay))
        try:
            if not isinstance(mapping, dict):
                raise ValueError("mapping must be an object")
            expected_id = str(mapping.get("sourceTeamId") or "")
            expected_name = str(mapping.get("sourceName") or "")
            expected_country = str(mapping.get("country") or "")
            existing_item = existing_teams.get(local_name)
            existing_badge_file = (
                str(existing_item.get("badgeFile") or "")
                if isinstance(existing_item, dict)
                else ""
            )
            existing_badge_path = (output_dir / existing_badge_file).resolve()
            if (
                not refresh_existing
                and isinstance(existing_item, dict)
                and str(existing_item.get("sourceTeamId") or "") == expected_id
                and str(existing_item.get("sourceName") or "") == expected_name
                and str(existing_item.get("country") or "") == expected_country
                and existing_badge_file.startswith("badges/")
                and existing_badge_path.parent == badges_dir.resolve()
                and existing_badge_path.is_file()
            ):
                manifest_items[local_name] = existing_item
                cached_count += 1
                continue
            source = _source_team(
                str(mapping.get("query") or ""),
                api_key,
                expected_id,
            )
            source_name = str(source.get("strTeam") or "")
            if source_name != expected_name:
                raise ValueError(
                    f"source name changed: expected {expected_name}, got {source_name}"
                )
            if str(source.get("strSport") or "") != "Soccer":
                raise ValueError("source team is not a soccer team")
            source_country = str(source.get("strCountry") or "")
            if expected_country and source_country != expected_country:
                raise ValueError(
                    f"source country changed: expected {expected_country}, got {source_country}"
                )
            badge_url = str(source.get("strBadge") or "")
            if not badge_url.startswith("https://"):
                raise ValueError("source badge URL is missing or not HTTPS")
            badge_name = f"{expected_id}{_badge_suffix(badge_url)}"
            badge_path = badges_dir / badge_name
            if not badge_path.exists():
                _download_badge(badge_url, badge_path)
            digest = hashlib.sha256(badge_path.read_bytes()).hexdigest()
            manifest_items[local_name] = {
                "provider": "thesportsdb",
                "sourceTeamId": expected_id,
                "sourceName": source_name,
                "sourceLeagueId": str(source.get("idLeague") or ""),
                "league": str(source.get("strLeague") or ""),
                "country": str(source.get("strCountry") or ""),
                "badgeFile": f"badges/{badge_name}",
                "badgeSha256": digest,
                "badgeBytes": badge_path.stat().st_size,
            }
        except Exception as error:
            errors.append({"team": local_name, "error": str(error)})
            existing_item = existing_teams.get(local_name)
            if isinstance(existing_item, dict):
                badge_file = str(existing_item.get("badgeFile") or "")
                badge_path = (output_dir / badge_file).resolve()
                if (
                    str(existing_item.get("sourceTeamId") or "")
                    == str(mapping.get("sourceTeamId") or "")
                    and badge_file.startswith("badges/")
                    and badge_path.parent == badges_dir.resolve()
                    and badge_path.is_file()
                ):
                    manifest_items[local_name] = existing_item
                    retained_count += 1

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "provider": "thesportsdb",
        "teamCount": len(manifest_items),
        "errorCount": len(errors),
        "retainedCount": retained_count,
        "cachedCount": cached_count,
        "teams": manifest_items,
        "errors": errors,
    }
    _write_json(manifest_path, manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aliases", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--api-key", default=os.environ.get("THESPORTSDB_API_KEY", "123"))
    parser.add_argument("--delay", type=float, default=2.1)
    parser.add_argument(
        "--refresh-existing",
        action="store_true",
        help="revalidate and redownload every mapped team instead of reusing valid cache",
    )
    parser.add_argument(
        "--names",
        help="comma-separated local team names for a cache-preserving incremental run",
    )
    args = parser.parse_args()
    result = sync(
        args.aliases,
        args.output_dir,
        args.api_key,
        args.delay,
        refresh_existing=args.refresh_existing,
        names={name.strip() for name in args.names.split(",") if name.strip()}
        if args.names
        else None,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["errorCount"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
