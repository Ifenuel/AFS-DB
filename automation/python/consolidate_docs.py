#!/usr/bin/env python3
"""One-off: consolidate every Markdown file under docs/ and rewrite relative links.

Run once from the repository root. Idempotent: files already under docs/ are left
alone, and links that already resolve are not rewritten.

Mapping rules:
  docs/**                       -> unchanged (already consolidated)
  <root>.md                     -> docs/<name>.md  (README.md -> docs/OVERVIEW.md)
  change-requests/x.md          -> docs/change-requests/x.md
  incidents/x.md                -> docs/incidents/x.md
  reports/x.md                  -> docs/reports/x.md
  diagrams/x.md                 -> docs/platform/diagrams/x.md
  mysql/x.md                    -> docs/platform/mysql/x.md
  oracle/x.md                   -> docs/platform/oracle/x.md
  test-data/x.md                -> docs/platform/test-data/x.md
  tests/x.md                    -> docs/platform/tests/x.md
  evidence/x.md                 -> docs/evidence/x.md
"""
from __future__ import annotations

import os
import posixpath
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

AREA_PREFIX = {
    "change-requests": "docs/change-requests",
    "incidents": "docs/incidents",
    "reports": "docs/reports",
    "diagrams": "docs/platform/diagrams",
    "mysql": "docs/platform/mysql",
    "oracle": "docs/platform/oracle",
    "test-data": "docs/platform/test-data",
    "tests": "docs/platform/tests",
    "evidence": "docs/evidence",
}

LINK_RE = re.compile(r"(!?\[[^\]]*\]\()(?P<target>[^)>\s]+)((?:>[^)]*)?\))")


def target_for(old: str) -> str:
    if old.startswith("docs/"):
        return old
    head, _, tail = old.partition("/")
    if head in AREA_PREFIX:
        return f"{AREA_PREFIX[head]}/{tail}"
    if old == "README.md":
        return "docs/OVERVIEW.md"
    return f"docs/{old}"


def main() -> int:
    md_files = sorted(
        p.relative_to(ROOT).as_posix()
        for p in ROOT.rglob("*.md")
        if ".git" not in p.parts and "node_modules" not in p.parts
    )
    mapping = {old: target_for(old) for old in md_files}
    texts = {old: (ROOT / old).read_text(encoding="utf-8") for old in md_files}

    moved = 0
    rewritten = 0
    unresolved: list[str] = []

    for old, new in mapping.items():
        if old == new:
            continue
        new_dir = posixpath.dirname(new)
        text = texts[old]
        old_dir = posixpath.dirname(old)

        def replace(match: re.Match[str]) -> str:
            nonlocal rewritten
            target = match.group("target")
            if target.startswith(("http://", "https://", "mailto:", "#", "{{")):
                return match.group(0)
            clean = target.split("#", 1)[0]
            for prefix in ("./", "../"):
                newclean = clean
                break
            old_resolved = posixpath.normpath(posixpath.join(old_dir, clean))
            if old_resolved in mapping:
                new_target = posixpath.relpath(mapping[old_resolved], new_dir)
            elif (ROOT / old_resolved).exists():
                new_target = posixpath.relpath(old_resolved, new_dir)
            else:
                unresolved.append(f"{old}: {target}")
                return match.group(0)
            if not new_target.startswith("."):
                new_target = new_target
            if target.endswith("/") and not new_target.endswith("/"):
                new_target += "/"
            if new_target != clean:
                rewritten += 1
            return f"{match.group(1)}{new_target}{match.group(3)}"

        text = LINK_RE.sub(replace, text)
        destination = ROOT / new
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding="utf-8")
        (ROOT / old).unlink()
        moved += 1

    for area in ("incidents", "change-requests", "reports", "tests"):
        directory = ROOT / area
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()

    print(f"moved={moved} links_rewritten={rewritten} unresolved={len(unresolved)}")
    for item in unresolved[:40]:
        print("  UNRESOLVED", item)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
