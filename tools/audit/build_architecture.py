"""Rebuild the Schema page from the Explorer's live catalog snapshot.

The page had a nine-section body but a six-row summary and rows copied from an
older load, so it disagreed with the Explorer and the estate. Both now come from
the same catalog extraction.

Run after tools/audit/build_explorer.py: python tools/audit/build_architecture.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARCH = ROOT / "site" / "architecture.html"
EXPLORER = ROOT / "site" / "explorer.html"

SLUGS = {
    "AFS_CoreBanking": ("corebanking", "CoreBanking", "Accounts, double-entry ledger, transfers and the customer record. The transfer procedure writes debit, credit, ledger event and audit row in one transaction."),
    "AFS_Payments": ("payments", "Payments", "Payment instruction, method, status and settlement batching, with its own audit trail."),
    "AFS_Fraud": ("fraud", "Fraud", "Rules, alerts and investigator cases raised against suspicious transfer activity."),
    "AFS_Audit": ("audit", "Audit", "The central audit record, administrative actions, security events and operational history."),
    "AFS_CustomerService": ("customerservice", "CustomerService", "Support cases, categories, notes, service requests and the escalation path."),
    "AFS_Reporting": ("reporting", "Reporting", "Staging, dimensional warehouse and reporting outputs, deliberately separate from the operational core."),
    "AFS_Identity": ("identity", "Identity", "Principals, roles, grants, access reviews and session history: identity governance as data."),
    "AFS_Compliance": ("compliance", "Compliance", "Obligations, controls, tests, findings, remediation and key-custody records."),
    "AFS_Archive": ("archive", "Archive", "Retention policy, legal hold, archived records with a SHA-256 chain, and the plant historian."),
}


def data() -> dict:
    text = EXPLORER.read_text(encoding="utf-8")
    match = re.search(r"<script>window\.AFS_DATA = (.*?);</script>", text, re.S)
    if not match:
        raise SystemExit("no AFS_DATA in explorer.html")
    return json.loads(match.group(1))


def main() -> int:
    d = data()
    html = ARCH.read_text(encoding="utf-8")
    totals = d["totals"]

    versions = dict(re.findall(r"assets/erds/(AFS_[A-Za-z]+)\.svg\?v=([0-9a-f]+)", html))

    summary = "".join(
        f'<tr><td data-label="Database"><span class="mono">{db["name"]}</span></td>'
        f'<td class="num" data-label="Tables">{db["counts"]["tables"]}</td>'
        f'<td class="num" data-label="Views">{db["counts"]["views"]}</td>'
        f'<td class="num" data-label="Procedures">{db["counts"]["procedures"]}</td>'
        f'<td class="num" data-label="Functions">{db["counts"]["functions"]}</td>'
        f'<td class="num" data-label="Foreign keys">{db["counts"]["foreignKeys"]}</td>'
        f'<td class="num" data-label="Rows">{db["counts"]["rows"]:,}</td></tr>'
        for db in d["databases"]
    )
    summary_block = (
        '<div class="table-wrap"><table class="data"><thead><tr><th>Database</th><th>Tables</th>'
        '<th>Views</th><th>Procedures</th><th>Functions</th><th>Foreign keys</th><th>Rows</th>'
        f'</tr></thead><tbody>{summary}</tbody></table></div>'
    )
    first_table = re.search(r'<div class="table-wrap"><table class="data">.*?</table></div>', html, re.S)
    if not first_table:
        raise SystemExit("summary table not found")
    html = html.replace(first_table.group(0), summary_block, 1)

    sections = []
    for db in d["databases"]:
        slug, label, blurb = SLUGS.get(db["name"], (db["short"].lower(), db["short"], ""))
        table_rows = "".join(
            f'<tr><td data-label="Schema"><span class="mono">{t["schema"]}</span></td>'
            f'<td data-label="Table"><span class="mono">{t["name"]}</span></td>'
            f'<td class="num" data-label="Rows">{t["rows"]:,}</td>'
            f'<td class="num" data-label="Columns">{len(t["columns"])}</td>'
            f'<td class="num" data-label="Indexes">{len(t["indexes"])}</td></tr>'
            for t in db["tables"]
        )
        v = versions.get(db["name"], "")
        sections.append(f'''    <section data-reveal class="wrap section" id="{slug}">
      <div class="section-head">
        <div class="kicker">{label}</div>
        <h2 class="mono">{db["name"]}</h2>
        <p>{db["counts"]["tables"]} tables &middot; {db["counts"]["views"]} views &middot; {db["counts"]["procedures"]} procedures &middot;
        {db["counts"]["foreignKeys"]} foreign keys &middot; {db["counts"]["rows"]:,} rows</p>
      </div>
      <p class="muted">{blurb}</p>
      <div class="table-wrap"><table class="data"><thead><tr><th>Schema</th><th>Table</th><th>Rows</th><th>Columns</th><th>Indexes</th></tr></thead><tbody>{table_rows}</tbody></table></div>
      <figure class="erd">
        <img src="assets/erds/{db["name"]}.svg?v={v}" alt="Entity relationship diagram for {db["name"]}, generated from the live catalog" loading="lazy">
        <figcaption>Generated from the catalog export; every line is a declared foreign key.
          <a href="assets/erds/{db["name"]}.html">Open the diagram on its own page</a>.</figcaption>
      </figure>
    </section>
''')

    start = html.index('    <section data-reveal class="wrap section" id="corebanking">')
    end = html.index("\n</main>", start)
    html = html[:start] + "".join(sections) + html[end:]

    html = html.replace(
        "<span class=\"badge\">46 foreign keys</span><span class=\"badge\">11 views</span>",
        f"<span class=\"badge\">{totals['foreignKeys']} foreign keys</span><span class=\"badge\">{totals['views']} views</span>",
    )
    html = html.replace(
        "The raw catalog also holds one SSMS diagram-support table and seven\n      diagram procedures in AFS_Audit; they are excluded from every count on this site and explained in\n      <a href=\"verification.html\">Evidence</a>.",
        "The raw catalog also holds a diagram-support table (six databases) and seven\n      diagram procedures per database; they are excluded from every count on this site. The counting rules\n      are printed on <a href=\"verification.html\">Evidence</a>.",
    )
    html = re.sub(r"Catalog and operational figures captured 2026-11-24\.", "Catalog and operational figures captured 2026-11-25.", html)
    ARCH.write_text(html, encoding="utf-8")
    print(f"architecture rebuilt: {len(d['databases'])} databases, {totals['tables']} tables, {totals['rows']:,} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
