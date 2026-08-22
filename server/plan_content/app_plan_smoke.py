from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_BASE_URL = os.environ.get(
    "CAIMASTER_API_BASE_URL",
    os.environ.get("API_BASE_URL", "https://api.cclloo.com"),
).rstrip("/")
REQUEST_TIMEOUT = float(os.environ.get("CAIMASTER_PLAN_SMOKE_TIMEOUT", "12"))


@dataclass
class Check:
    level: str
    name: str
    detail: str


class SmokeError(RuntimeError):
    pass


def _request_json(base_url: str, path: str, query: dict[str, str] | None = None) -> dict[str, Any]:
    query_params = {
        **(query or {}),
        "_ts": str(int(time.time() * 1000)),
    }
    url = f"{base_url}{path}?{urllib.parse.urlencode(query_params)}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "CaimasterPlanAppSmoke/1.0",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            if response.status != 200:
                raise SmokeError(f"HTTP {response.status}: {url}")
            raw = response.read(1024 * 1024)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise SmokeError(f"request failed: {url}: {exc}") from exc
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SmokeError(f"invalid JSON: {url}") from exc
    if not isinstance(decoded, dict):
        raise SmokeError(f"response is not an object: {url}")
    return decoded


def _items(body: dict[str, Any]) -> list[dict[str, Any]]:
    raw_items = body.get("items") or []
    if not isinstance(raw_items, list):
        raise SmokeError("items must be an array")
    return [item for item in raw_items if isinstance(item, dict)]


def _require_fields(item: dict[str, Any], fields: tuple[str, ...], label: str) -> None:
    missing = [field for field in fields if field not in item]
    if missing:
        raise SmokeError(f"{label} missing fields: {', '.join(missing)}")


def _check_url(value: Any, field: str) -> None:
    if value is None:
        return
    text = str(value)
    if not text.startswith("https://"):
        raise SmokeError(f"{field} must be https URL")


def _validate_plan_summary(item: dict[str, Any]) -> None:
    _require_fields(
        item,
        (
            "id",
            "slug",
            "name",
            "uploaderName",
            "latestUpdatedAt",
            "updatedToday",
            "latestImageCount",
            "latestThumbnailUrl",
        ),
        "plan summary",
    )
    if not str(item.get("id") or ""):
        raise SmokeError("plan summary id is empty")
    if not str(item.get("name") or ""):
        raise SmokeError("plan summary name is empty")
    if int(item.get("latestImageCount") or 0) <= 0:
        raise SmokeError("plan summary latestImageCount must be positive")
    _check_url(item.get("latestThumbnailUrl"), "latestThumbnailUrl")


def _validate_update(item: dict[str, Any]) -> None:
    _require_fields(item, ("id", "title", "publishedAt", "images"), "plan update")
    images = item.get("images")
    if not isinstance(images, list) or not images:
        raise SmokeError("plan update images must be a non-empty array")
    for image in images:
        if not isinstance(image, dict):
            raise SmokeError("plan image must be an object")
        _require_fields(
            image,
            ("id", "imageUrl", "thumbnailUrl", "width", "height", "position"),
            "plan image",
        )
        _check_url(image.get("imageUrl"), "imageUrl")
        _check_url(image.get("thumbnailUrl"), "thumbnailUrl")
        if int(image.get("width") or 0) <= 0 or int(image.get("height") or 0) <= 0:
            raise SmokeError("plan image dimensions must be positive")


def run(base_url: str, *, require_data: bool = False) -> tuple[bool, list[Check]]:
    checks: list[Check] = []
    ok = True

    try:
        recent_body = _request_json(base_url, "/v1/plans/recent", {"limit": "6"})
        recent_items = _items(recent_body)
        if not recent_items:
            level = "error" if require_data else "warn"
            ok = ok and not require_data
            checks.append(Check(level, "recent plans", "no items"))
            return ok, checks
        for item in recent_items:
            _validate_plan_summary(item)
        checks.append(Check("ok", "recent plans", f"{len(recent_items)} items"))
    except SmokeError as exc:
        checks.append(Check("error", "recent plans", str(exc)))
        return False, checks

    first_plan = recent_items[0]
    plan_id = str(first_plan["id"])

    try:
        list_body = _request_json(base_url, "/v1/plans", {"limit": "20", "offset": "0"})
        list_items = _items(list_body)
        if require_data and not list_items:
            raise SmokeError("no items")
        for item in list_items:
            _validate_plan_summary(item)
        checks.append(Check("ok", "all plans", f"{len(list_items)} items"))
    except SmokeError as exc:
        checks.append(Check("error", "all plans", str(exc)))
        ok = False

    try:
        keyword = str(first_plan.get("name") or "").strip()
        matched_items = _items(
            _request_json(
                base_url,
                "/v1/plans",
                {
                    "q": keyword,
                    "activity": "all",
                    "limit": "20",
                    "offset": "0",
                },
            )
        )
        if not matched_items:
            raise SmokeError(f"known name returned no items: {keyword}")
        if any(
            keyword not in str(item.get("name") or "")
            for item in matched_items
        ):
            raise SmokeError("name query returned unrelated items")
        missing_items = _items(
            _request_json(
                base_url,
                "/v1/plans",
                {
                    "q": "__NO_SUCH_PLAN_987654__",
                    "activity": "all",
                    "limit": "20",
                    "offset": "0",
                },
            )
        )
        if missing_items:
            raise SmokeError("missing-name query returned items")
        checks.append(Check("ok", "plan name search", f"matched {keyword}"))
    except SmokeError as exc:
        checks.append(Check("error", "plan name search", str(exc)))
        ok = False

    try:
        updates_body = _request_json(
            base_url,
            f"/v1/plans/{urllib.parse.quote(plan_id)}/updates",
            {"limit": "10", "offset": "0", "days": "3650"},
        )
        _require_fields(updates_body, ("plan", "items", "count", "hasMore"), "updates body")
        update_items = _items(updates_body)
        if require_data and not update_items:
            raise SmokeError("no update items")
        for item in update_items:
            _validate_update(item)
        checks.append(Check("ok", "plan updates", f"plan={plan_id} updates={len(update_items)}"))
    except SmokeError as exc:
        checks.append(Check("error", "plan updates", str(exc)))
        ok = False

    return ok, checks


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke test plan APIs used by the app.")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--require-data", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    ok, checks = run(args.base_url.rstrip("/"), require_data=args.require_data)
    if args.json:
        print(
            json.dumps(
                {
                    "ok": ok,
                    "baseUrl": args.base_url.rstrip("/"),
                    "checks": [check.__dict__ for check in checks],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        for check in checks:
            print(f"[{check.level.upper()}] {check.name}: {check.detail}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
