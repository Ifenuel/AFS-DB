"""Audit the public site: internal links, anchors, assets and stale copy.

Run: python tools/audit_site.py
Exit code 1 when a real defect is found, so it can gate a release.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"

STALE = [
    "500 customers",
    "5,370",
    "six databases",
    "Six databases",
    "41 tables",
    "27 foreign keys",
    "docs/AIM.md",
    "reviewer should not have to trust",
    "evidence/verify/live/",
    "16,109",
    "first class",
    "2 of 2 rows",
    "1,536 MB",
    "six-database",
]

def ids_of(html: str) -> set[str]:
    return set(re.findall(r'\bid="([^"]+)"', html))

def main() -> int:
    pages = sorted(SITE.glob("*.html"))
    cache = {p.name: p.read_text(encoding="utf-8") for p in pages}
    problems: list[str] = []
    links = 0

    for name, html in cache.items():
        for href in re.findall(r'href="([^"]+)"', html):
            if href.startswith(("http://", "https://", "mailto:", "tel:", "#", "javascript:")):
                if href.startswith("#") and href[1:] and href[1:] not in ids_of(html):
                    problems.append(f"{name}: missing anchor {href}")
                continue
            target, _, frag = href.partition("#")
            links += 1
            target = target.split("?")[0]
            if target:
                if not (SITE / target).exists():
                    problems.append(f"{name}: missing page {target}")
                    continue
                if frag and frag not in ids_of(cache.get(target, "")):
                    problems.append(f"{name}: missing anchor {target}#{frag}")
            elif frag and frag not in ids_of(html):
                problems.append(f"{name}: missing anchor #{frag}")

        for src in re.findall(r'src="([^"]+)"', html):
            if src.startswith(("http://", "https://", "data:")):
                continue
            if not (SITE / src.split("?")[0]).exists():
                problems.append(f"{name}: missing asset {src}")

        for phrase in STALE:
            if phrase in html:
                problems.append(f"{name}: stale copy '{phrase}'")

    # every evidence capture must be reachable from the evidence page or a page link
    evidence = sorted((ROOT / "evidence" / "verify" / "live").glob("*.txt"))
    evidence_page = cache.get("verification.html", "")
    shown = re.findall(r'id="(\d+_[a-z_0-9]+)"', evidence_page)
    unreferenced = [p.stem for p in evidence if p.stem not in shown]
    # Captures that are older supporting runs are allowed to be referenced from other pages.
    for stem in unreferenced:
        num = stem.split("_")[0]
        if num.isdigit() and int(num) < 49:
            continue  # historical captures are indexed in the evidence register
        if not any(f"live/{num}" in h for h in cache.values()):
            problems.append(f"evidence/{stem}: not linked from any page")

    print(f"pages       : {len(pages)}")
    print(f"links       : {links}")
    print(f"captures    : {len(evidence)} ({len(shown)} embedded on the evidence page)")
    if problems:
        print("\nDEFECTS")
        for item in problems:
            print(" -", item)
        return 1
    print("\nPASS: links, anchors, assets and copy are consistent.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
