from __future__ import annotations

import html.parser
import re
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from typing import Any


CHINA_TZ = timezone(timedelta(hours=8))
EXCLUDED_TITLE_WORDS = (
    "二维码",
    "下载",
    "访问通知",
    "推广",
    "禁止",
    "公告",
)
IGNORE_IMAGE_ASSIGNMENT = "__IGNORE__"


class SourceError(RuntimeError):
    pass


@dataclass(frozen=True)
class PlanNameRules:
    aliases: dict[str, str]
    image_assignments: dict[str, tuple[str, ...]]
    allowed_names: frozenset[str]
    ignored_names: frozenset[str]
    excluded_title_words: tuple[str, ...]
    allow_auto_create: bool

    @classmethod
    def from_mapping(cls, value: Any) -> "PlanNameRules":
        if not isinstance(value, dict):
            raise SourceError("plan source mapping must be a JSON object")
        if any(
            key in value
            for key in (
                "aliases",
                "imageAssignments",
                "allowedNames",
                "ignoredNames",
                "excludedTitleWords",
                "allowAutoCreate",
            )
        ):
            raw_aliases = value.get("aliases") or {}
            if not isinstance(raw_aliases, dict):
                raise SourceError("aliases must be a JSON object")
            aliases = _normalized_mapping(raw_aliases)
            image_assignments = _normalized_image_assignments(
                value.get("imageAssignments") or {}
            )
            allowed_names = _normalized_set(value.get("allowedNames") or [])
            ignored_names = _normalized_set(value.get("ignoredNames") or [])
            extra_words = tuple(
                str(word).strip()
                for word in (value.get("excludedTitleWords") or [])
                if str(word).strip()
            )
            return cls(
                aliases=aliases,
                image_assignments=image_assignments,
                allowed_names=frozenset(
                    allowed_names
                    | set(aliases.values())
                    | {
                        name
                        for names in image_assignments.values()
                        for name in names
                        if name != IGNORE_IMAGE_ASSIGNMENT
                    }
                ),
                ignored_names=frozenset(ignored_names),
                excluded_title_words=EXCLUDED_TITLE_WORDS + extra_words,
                allow_auto_create=bool(value.get("allowAutoCreate", False)),
            )

        aliases = _normalized_mapping(value)
        return cls(
            aliases=aliases,
            image_assignments={},
            allowed_names=frozenset(aliases.values()),
            ignored_names=frozenset(),
            excluded_title_words=EXCLUDED_TITLE_WORDS,
            allow_auto_create=True,
        )


@dataclass(frozen=True)
class ParsedPlanTitle:
    name: str
    raw_name: str
    published_date: datetime
    needs_review: bool = False
    image_plan_names: tuple[str, ...] = ()


class _ImageParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.urls: list[str] = []

    def handle_starttag(
        self,
        tag: str,
        attrs: list[tuple[str, str | None]],
    ) -> None:
        if tag.lower() != "img":
            return
        source = dict(attrs).get("src")
        if source:
            self.urls.append(source.strip())


def normalize_plan_name(value: Any) -> str:
    text = " ".join(str(value or "").strip().split())
    return text.strip(" -_—:：·,，|/")[:60]


def _normalized_mapping(value: dict[Any, Any]) -> dict[str, str]:
    return {
        normalize_plan_name(key): normalize_plan_name(mapped)
        for key, mapped in value.items()
        if normalize_plan_name(key) and normalize_plan_name(mapped)
    }


def _normalized_image_assignments(
    value: Any,
) -> dict[str, tuple[str, ...]]:
    if not isinstance(value, dict):
        raise SourceError("imageAssignments must be a JSON object")
    assignments: dict[str, tuple[str, ...]] = {}
    for raw_name, raw_targets in value.items():
        name = normalize_plan_name(raw_name)
        if not name:
            continue
        if not isinstance(raw_targets, list):
            raise SourceError(
                f"image assignment for {name} must be a JSON array"
            )
        targets = tuple(
            IGNORE_IMAGE_ASSIGNMENT
            if str(item or "").strip().upper() == IGNORE_IMAGE_ASSIGNMENT
            else normalize_plan_name(item)
            for item in raw_targets
        )
        if any(not target for target in targets):
            raise SourceError(
                f"image assignment for {name} contains an empty target"
            )
        if not targets or all(
            target == IGNORE_IMAGE_ASSIGNMENT for target in targets
        ):
            raise SourceError(
                f"image assignment for {name} has no plan names"
            )
        assignments[name] = targets
    return assignments


def _normalized_set(value: Any) -> set[str]:
    if not isinstance(value, list):
        raise SourceError("name rule lists must be JSON arrays")
    return {
        normalize_plan_name(item)
        for item in value
        if normalize_plan_name(item)
    }


_DATED_TITLE = re.compile(
    r"^\s*(20\d{2})[-/.年]?"
    r"(0[1-9]|1[0-2])[-/.月]?"
    r"(0[1-9]|[12]\d|3[01])日?"
    r"\s*[-_—:：·,，|/]*\s*(.+?)\s*$"
)

_SESSION_SUFFIXES = (
    "上午场",
    "下午场",
    "早场",
    "晚场",
    "早单",
    "晚单",
    "夜场",
    "早",
    "晚",
)


def _allowed_session_base(
    name: str,
    allowed_names: frozenset[str],
) -> str | None:
    for suffix in _SESSION_SUFFIXES:
        if not name.endswith(suffix):
            continue
        base = normalize_plan_name(name[: -len(suffix)])
        if base and base in allowed_names:
            return base
    return None


def parse_plan_title_info(
    title: Any,
    rules: PlanNameRules | dict[str, str],
) -> ParsedPlanTitle:
    if isinstance(rules, dict):
        rules = PlanNameRules.from_mapping(rules)
    source_title = " ".join(str(title or "").strip().split())
    if any(word in source_title for word in rules.excluded_title_words):
        raise SourceError("excluded non-plan article")
    matched = _DATED_TITLE.match(source_title)
    if matched is None:
        raise SourceError("title has no supported date prefix")
    year, month, day, raw_name = matched.groups()
    try:
        published_date = datetime(
            int(year),
            int(month),
            int(day),
            tzinfo=CHINA_TZ,
        )
    except ValueError as exc:
        raise SourceError("title contains an invalid date") from exc
    raw_plan_name = normalize_plan_name(raw_name)
    if not raw_plan_name:
        raise SourceError("title has no plan name")
    if raw_plan_name in rules.ignored_names:
        raise SourceError("ignored plan name")
    image_plan_names = rules.image_assignments.get(raw_plan_name, ())
    if image_plan_names:
        primary_name = next(
            name
            for name in image_plan_names
            if name != IGNORE_IMAGE_ASSIGNMENT
        )
        return ParsedPlanTitle(
            name=primary_name,
            raw_name=raw_plan_name,
            published_date=published_date,
            needs_review=False,
            image_plan_names=image_plan_names,
        )
    name = rules.aliases.get(raw_plan_name, raw_plan_name)
    if name == raw_plan_name and name not in rules.allowed_names:
        name = _allowed_session_base(name, rules.allowed_names) or name
    allowed = (
        name in rules.allowed_names
        if rules.allowed_names
        else rules.allow_auto_create
    )
    if not allowed and not rules.allow_auto_create:
        raise SourceError(f"plan name awaits mapping: {raw_plan_name}")
    return ParsedPlanTitle(
        name=name,
        raw_name=raw_plan_name,
        published_date=published_date,
        needs_review=rules.allow_auto_create and not allowed,
    )


def parse_plan_title(
    title: Any,
    mapping: PlanNameRules | dict[str, str],
) -> tuple[str, datetime]:
    parsed = parse_plan_title_info(title, mapping)
    return parsed.name, parsed.published_date


def extract_image_urls(content: Any, api_base_url: str) -> list[str]:
    parser = _ImageParser()
    parser.feed(str(content or ""))
    unique: list[str] = []
    for url in parser.urls:
        absolute = urllib.parse.urljoin(f"{api_base_url.rstrip('/')}/", url)
        if absolute.startswith("https://") and absolute not in unique:
            unique.append(absolute)
    return unique
