"""Render the four research case studies as first-class site pages.

The Markdown in docs/research/cases/ is the source of record; this module only
converts it. Nothing is summarised away, so the published page and the document
cannot drift apart.
"""
from __future__ import annotations

import html
import json
import re
from pathlib import Path

from build_site_pages import SITE, shell

CASES = [
    ("P-01", "P-01_payment_integrity.md", "Payment integrity",
     "Credits without debits: a dry posting, duplicate requests and a concurrent spend reproduced, then closed with one transaction, idempotency and a guarded update."),
    ("P-02", "P-02_telemetry_quality.md", "Telemetry data quality",
     "Missing, late, duplicate, out-of-order and unit-faulted readings staged, quarantined, corrected and scored against the cadence the PLC actually ran at."),
    ("P-03", "P-03_change_recovery.md", "Change and recovery",
     "A mass update that drifts balances, a guarded migration, blocking measured with and without RCSI, and a point-in-time restore compared row for row."),
    ("P-04", "P-04_security_audit.md", "Privileged access and audit",
     "An application holding CONTROL and erasing its own trail, then least privilege, denied direct writes and an audit trigger that names the caller."),
]


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    stash: list[str] = []

    def keep(fragment: str) -> str:
        stash.append(fragment)
        return f"\x00{len(stash) - 1}\x00"

    text = re.sub(r"`([^`]+)`", lambda m: keep(f"<code>{m.group(1)}</code>"), text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
                  lambda m: keep(f'<a href="{m.group(2)}">{m.group(1)}</a>'), text)
    for index, fragment in enumerate(stash):
        text = text.replace(f"\x00{index}\x00", fragment)
    return text


def _table(lines: list[str]) -> str:
    rows = [[cell.strip() for cell in line.strip().strip("|").split("|")] for line in lines]
    head, body = rows[0], rows[2:]
    out = ["<table>", "<thead><tr>"]
    out += [f"<th>{inline(cell)}</th>" for cell in head]
    out.append("</tr></thead><tbody>")
    for row in body:
        out.append("<tr>" + "".join(f"<td>{inline(cell)}</td>" for cell in row) + "</tr>")
    out.append("</tbody></table>")
    return '<div class="table-scroll">' + "".join(out) + "</div>"


def markdown(text: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    paragraph: list[str] = []
    i = 0

    def flush() -> None:
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("```"):
            flush()
            lang = stripped[3:].strip()
            block: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1
            cls = f' class="language-{lang}"' if lang else ""
            out.append(f"<pre><code{cls}>{html.escape(chr(10).join(block))}</code></pre>")
            continue

        if not stripped:
            flush()
            i += 1
            continue

        heading = re.match(r"^(#{2,4})\s+(.*)$", stripped)
        if heading:
            flush()
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            i += 1
            continue

        if re.match(r"^(-{3,}|\*{3,})$", stripped):
            flush()
            out.append("<hr>")
            i += 1
            continue

        if stripped.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|$", lines[i + 1].strip()):
            flush()
            block = [stripped]
            i += 1
            while i < len(lines) and lines[i].strip().startswith("|"):
                block.append(lines[i].strip())
                i += 1
            out.append(_table(block))
            continue

        bullet = re.match(r"^([-*])\s+(.*)$", stripped)
        numbered = re.match(r"^(\d+)\.\s+(.*)$", stripped)
        if bullet or numbered:
            flush()
            ordered = bool(numbered)
            tag = "ol" if ordered else "ul"
            items: list[str] = []
            while i < len(lines):
                current = lines[i].strip()
                match = re.match(r"^(\d+)\.\s+(.*)$", current) if ordered else re.match(r"^[-*]\s+(.*)$", current)
                if not match:
                    break
                items.append(match.group(2) if ordered else match.group(1))
                i += 1
                while i < len(lines) and lines[i].startswith("  ") and lines[i].strip() and not re.match(r"^([-*]|\d+\.)\s", lines[i].strip()):
                    items[-1] += " " + lines[i].strip()
                    i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{inline(item)}</li>" for item in items) + f"</{tag}>")
            continue

        if stripped.startswith(">"):
            flush()
            quote: list[str] = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip().lstrip(">").strip())
                i += 1
            out.append(f"<blockquote><p>{inline(' '.join(quote))}</p></blockquote>")
            continue

        paragraph.append(stripped)
        i += 1

    flush()
    return "\n".join(out)


def build_case_page(case_id: str, filename: str, short: str, description: str,
                    prev_link: str, next_link: str) -> None:
    source = (SITE.parent / "docs" / "research" / "cases" / filename).read_text(encoding="utf-8")
    evidence = SITE.parent / "evidence" / "research" / case_id / f"{case_id.lower().replace('-', '')}-latest.json"
    try:
        data = json.loads(evidence.read_text(encoding="utf-8"))
    except Exception:
        data = {}
    summary = data.get("summary", {})
    figures = []
    if summary.get("total"):
        figures.append(("Assertions", f"{summary.get('passed', 0)}/{summary.get('total')} executed"))
    if summary.get("status"):
        figures.append(("Status", str(summary["status"])))
    if data.get("generated_at_utc"):
        figures.append(("Latest run", str(data["generated_at_utc"]).replace("T", " ").replace("Z", " UTC")))
    figures.append(("Evidence", f"evidence/research/{case_id}/"))
    figure_block = ('<dl class="case-figures">' + "".join(
        f"<div><dt>{html.escape(k)}</dt><dd>{html.escape(v)}</dd></div>" for k, v in figures
    ) + "</dl>") if figures else ""
    title = source.splitlines()[0].lstrip("# ").strip()
    body = source.split("\n", 1)[1]
    slug = f"case-{case_id.lower().replace('-', '')}.html"

    main = f"""
  <div class="wrap page-head case-head">
    <div class="kicker">Investigation {case_id} &middot; {short}</div>
    <h1>{html.escape(title.split('—', 1)[-1].strip() if '—' in title else title)}</h1>
    <p class="lede">{description}</p>
    {figure_block}
    <div class="badges"><a class="badge badge-link" href="investigations.html">All investigations</a>
      <span class="badge">Executed scripts, not descriptions</span>
      <span class="badge">Laboratory reproduction</span></div>
  </div>
  <div class="wrap band" style="border-top:0;padding-top:10px">
    <article class="case-body">
{markdown(body)}
    </article>
    <nav class="case-nav" aria-label="Case navigation">
      <a href="{prev_link}">&larr; Previous investigation</a>
      <a href="{next_link}">Next investigation &rarr;</a>
    </nav>
  </div>
"""

    (SITE / slug).write_text(
        shell("investigations.html",
              f"{case_id} {short} - Apex Financial Services",
              description.replace('"', "'"),
              main),
        encoding="utf-8")
    print(f"wrote site/{slug}")


def build_case_pages() -> None:
    slugs = [f"case-{cid.lower().replace('-', '')}.html" for cid, *_ in CASES]
    for index, (case_id, filename, short, description) in enumerate(CASES):
        build_case_page(
            case_id, filename, short, description,
            prev_link=slugs[index - 1] if index else "investigations.html",
            next_link=slugs[index + 1] if index + 1 < len(slugs) else "investigations.html",
        )


if __name__ == "__main__":
    build_case_pages()
