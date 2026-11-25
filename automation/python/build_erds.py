"""Build entity-relationship diagrams for the AFS SQL Server databases.

Metadata comes from the live catalog (sys.tables / sys.columns / sys.foreign_keys),
never from hand-written lists. The output is one self-contained HTML file with a
diagram per database, plus the raw extraction in diagrams/data.

Run:  python automation/python/build_erds.py
"""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_HTML = ROOT / "diagrams" / "erd.html"
OUT_DATA = ROOT / "diagrams" / "data"

DATABASES = [
    "AFS_CoreBanking",
    "AFS_Payments",
    "AFS_Fraud",
    "AFS_CustomerService",
    "AFS_Audit",
    "AFS_Reporting",
    "AFS_Identity",
    "AFS_Compliance",
    "AFS_Archive",
]

EXTRACT_SQL = """
SET NOCOUNT ON;
SELECT 'T|' + SCHEMA_NAME(t.schema_id) + '.' + t.name
FROM sys.tables t
WHERE t.is_ms_shipped = 0 AND t.name <> 'sysdiagrams'
UNION ALL
SELECT 'C|' + SCHEMA_NAME(t.schema_id) + '.' + t.name
     + '|' + c.name + '|' + ty.name
     + '|' + CAST(c.max_length AS VARCHAR(10))
     + '|' + CAST(c.precision AS VARCHAR(5)) + '|' + CAST(c.scale AS VARCHAR(5))
     + '|' + CAST(c.is_nullable AS VARCHAR(1))
     + '|' + CAST(ISNULL(COLUMNPROPERTY(c.object_id, c.name, 'IsIdentity'), 0) AS VARCHAR(1))
     + '|' + CASE WHEN EXISTS (
                 SELECT 1 FROM sys.indexes i
                 JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                 WHERE i.is_primary_key = 1 AND i.object_id = t.object_id AND ic.column_id = c.column_id)
            THEN '1' ELSE '0' END
     + '|' + CASE WHEN EXISTS (
                 SELECT 1 FROM sys.foreign_key_columns fkc
                 WHERE fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id)
            THEN '1' ELSE '0' END
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0 AND t.name <> 'sysdiagrams'
UNION ALL
SELECT 'F|' + fk.name
     + '|' + SCHEMA_NAME(ct.schema_id) + '.' + ct.name + '.' + cc.name
     + '|' + SCHEMA_NAME(pt.schema_id) + '.' + pt.name + '.' + pc.name
     + '|' + CAST(fkc.constraint_column_id AS VARCHAR(3))
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables ct ON ct.object_id = fkc.parent_object_id
JOIN sys.columns cc ON cc.object_id = ct.object_id AND cc.column_id = fkc.parent_column_id
JOIN sys.tables pt ON pt.object_id = fkc.referenced_object_id
JOIN sys.columns pc ON pc.object_id = pt.object_id AND pc.column_id = fkc.referenced_column_id
ORDER BY 1;
"""


def extract(database: str) -> str:
    """Run the catalog query against one database and return its raw rows."""
    with tempfile.TemporaryDirectory() as tmp:
        sql_file = Path(tmp) / "extract.sql"
        out_file = Path(tmp) / "extract.out"
        sql_file.write_text(EXTRACT_SQL, encoding="utf-8")
        subprocess.run(
            [
                "sqlcmd", "-S", ".", "-E", "-d", database, "-i", str(sql_file),
                "-o", str(out_file), "-W", "-s", "\t", "-y", "0", "-h", "-1",
            ],
            check=True,
            capture_output=True,
        )
        return out_file.read_text(encoding="utf-8", errors="replace")


def display_type(name: str, max_length: int, precision: int, scale: int) -> str:
    if name in ("varchar", "char", "varbinary", "binary"):
        return f"{name}({max_length if max_length > 0 else 'max'})"
    if name in ("nvarchar", "nchar"):
        return f"{name}({max_length // 2 if max_length > 0 else 'max'})"
    if name in ("decimal", "numeric"):
        return f"{name}({precision},{scale})"
    if name in ("datetime2", "time", "datetimeoffset"):
        return f"{name}({scale})"
    return name


def parse(database: str, raw: str) -> dict:
    tables: dict[str, dict] = {}
    edges: dict[str, dict] = {}

    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        kind = parts[0]
        if kind == "T" and len(parts) == 2:
            tables.setdefault(parts[1], {"name": parts[1], "columns": []})
        elif kind == "C" and len(parts) == 11:
            _, table, col, ty, maxlen, prec, scale, nullable, ident, pk, fk = parts
            if table not in tables:
                tables[table] = {"name": table, "columns": []}
            tables[table]["columns"].append(
                {
                    "name": col,
                    "type": display_type(ty, int(maxlen), int(prec), int(scale)),
                    "nullable": nullable == "1",
                    "identity": ident == "1",
                    "pk": pk == "1",
                    "fk": fk == "1",
                }
            )
        elif kind == "F" and len(parts) == 5:
            _, name, child, parent, ordinal = parts
            edge = edges.setdefault(
                name, {"name": name, "child": child.rsplit(".", 1)[0],
                       "parent": parent.rsplit(".", 1)[0], "pairs": []}
            )
            edge["pairs"].append(
                {"child_column": child.rsplit(".", 1)[1],
                 "parent_column": parent.rsplit(".", 1)[1]}
            )

    # Deterministic column order: PK first, then declaration order from sys.columns
    # (which the catalog returns by column_id).
    for table in tables.values():
        table["columns"].sort(key=lambda c: (not c["pk"],))
    for edge in edges.values():
        edge["pairs"].sort(key=lambda p: p["child_column"])

    return {
        "database": database,
        "tables": sorted(tables.values(), key=lambda t: t["name"]),
        "edges": sorted(edges.values(), key=lambda e: (e["child"], e["name"])),
    }


def depths(model: dict) -> dict[str, int]:
    """Longest-path depth: referenced tables sit left of the tables that point at them."""
    parents: dict[str, list[str]] = {t["name"]: [] for t in model["tables"]}
    for edge in model["edges"]:
        if edge["child"] != edge["parent"] and edge["child"] in parents:
            parents[edge["child"]].append(edge["parent"])

    memo: dict[str, int] = {}
    visiting: set[str] = set()

    def depth(name: str) -> int:
        if name in memo:
            return memo[name]
        if name in visiting:
            return 0
        visiting.add(name)
        value = 0
        for parent in parents.get(name, []):
            value = max(value, depth(parent) + 1)
        visiting.discard(name)
        memo[name] = min(value, 4)
        return memo[name]

    return {t["name"]: depth(t["name"]) for t in model["tables"]}


CARD_W = 336
HEAD_H = 42
ROW_H = 26
PAD_B = 12
GAP_X = 120
GAP_Y = 44
MARGIN = 56

PALETTE = [
    ("#e8ecf8", "#2b3a67"), ("#e6f4f1", "#1f5f57"), ("#fdf1e4", "#8a5320"),
    ("#fbe9ef", "#8c3050"), ("#eaf1fb", "#1d4b8f"), ("#f0edfb", "#4b3f8f"),
    ("#eef3e5", "#4d6229"), ("#fdeeee", "#8f3a32"), ("#e9f3f7", "#215d70"),
]


def esc(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def render_svg(model: dict) -> tuple[str, dict]:
    level = depths(model)
    degree: dict[str, int] = {t["name"]: 0 for t in model["tables"]}
    for edge in model["edges"]:
        degree[edge["child"]] = degree.get(edge["child"], 0) + 1
        degree[edge["parent"]] = degree.get(edge["parent"], 0) + 1

    columns: dict[int, list[str]] = {}
    for table in model["tables"]:
        columns.setdefault(level[table["name"]], []).append(table["name"])

    heights = {
        t["name"]: HEAD_H + len(t["columns"]) * ROW_H + PAD_B for t in model["tables"]
    }
    stack = {
        col_index: sum(heights[n] for n in names) + GAP_Y * (len(names) - 1)
        for col_index, names in columns.items()
    }
    tallest = max(stack.values()) if stack else 0

    box: dict[str, dict] = {}
    for col_index in sorted(columns):
        # Busiest tables first so the short connections stay at the top.
        names = sorted(columns[col_index], key=lambda n: (-degree.get(n, 0), n))
        x = MARGIN + col_index * (CARD_W + GAP_X)
        y = MARGIN + (tallest - stack[col_index]) / 2
        for name in names:
            box[name] = {"x": x, "y": y, "w": CARD_W, "h": heights[name]}
            y += heights[name] + GAP_Y

    width = MARGIN * 2 + max((b["x"] + b["w"]) for b in box.values())
    height = MARGIN * 2 + max((b["y"] + b["h"]) for b in box.values())
    width = max(width, 900)

    def row_y(table: str, column: str) -> float:
        t = next(t for t in model["tables"] if t["name"] == table)
        for index, col in enumerate(t["columns"]):
            if col["name"] == column:
                return box[table]["y"] + HEAD_H + index * ROW_H + ROW_H / 2
        return box[table]["y"] + HEAD_H + ROW_H / 2

    parts: list[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.0f} {height:.0f}" '
        'font-family="Inter, Segoe UI Variable Text, Segoe UI, system-ui, -apple-system, Helvetica, Arial, sans-serif" '
        f'width="{width:.0f}" height="{height:.0f}" role="img" '
        f'aria-label="Entity relationship diagram for {esc(model["database"])}" class="erd-svg">'
    )
    parts.append(f'<rect width="{width:.0f}" height="{height:.0f}" fill="#f7f9fc"/>')
    parts.append(
        '<defs><pattern id="dots" width="24" height="24" patternUnits="userSpaceOnUse">'
        '<circle cx="1.5" cy="1.5" r="1.1" fill="#dfe6f0"/></pattern>'
        '<filter id="cardShadow" x="-6%" y="-6%" width="112%" height="116%">'
        '<feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#1d2637" flood-opacity="0.08"/>'
        '</filter></defs>'
    )
    parts.append(f'<rect width="{width:.0f}" height="{height:.0f}" fill="url(#dots)"/>')

    # Connectors: one lane per edge inside the gutter between two columns, ordered
    # by the row each edge leaves, so parallel runs never overlap or cross a card.
    gutters: dict[tuple[int, int], list] = {}
    for edge in model["edges"]:
        if edge["child"] not in box or edge["parent"] not in box:
            continue
        c, p = box[edge["child"]], box[edge["parent"]]
        if abs(c["x"] - p["x"]) < 1:
            continue
        key = (int(min(c["x"], p["x"])), int(max(c["x"], p["x"])))
        first = edge["pairs"][0]
        gutters.setdefault(key, []).append(
            (row_y(edge["child"], first["child_column"]), edge)
        )

    for (left_x, right_x), items in sorted(gutters.items()):
        items.sort(key=lambda it: (it[0], it[1]["parent"]))
        gutter_left = left_x + CARD_W
        gutter_w = right_x - gutter_left
        step = min(10.0, max(6.0, (gutter_w - 40) / max(len(items), 1)))
        for index, (_, edge) in enumerate(items):
            lane_x = gutter_left + 20 + index * step
            c, p = box[edge["child"]], box[edge["parent"]]
            child_left = c["x"] < p["x"]
            start_x = c["x"] + c["w"] if child_left else c["x"]
            end_x = p["x"] if child_left else p["x"] + p["w"]
            outward = 1 if child_left else -1
            for pair in edge["pairs"]:
                sy = row_y(edge["child"], pair["child_column"])
                ey = row_y(edge["parent"], pair["parent_column"])
                r = 10
                down = 1 if ey >= sy else -1
                path = (
                    f"M {start_x:.1f} {sy:.1f} "
                    f"L {lane_x - outward * r:.1f} {sy:.1f} "
                    f"Q {lane_x:.1f} {sy:.1f} {lane_x:.1f} {sy + down * r:.1f} "
                    f"L {lane_x:.1f} {ey - down * r:.1f} "
                    f"Q {lane_x:.1f} {ey:.1f} {lane_x + outward * r:.1f} {ey:.1f} "
                    f"L {end_x:.1f} {ey:.1f}"
                )
                parts.append(
                    f'<path d="{path}" fill="none" stroke="#7b89a3" stroke-width="1.3" '
                    f'stroke-linejoin="round" data-fk="{esc(edge["name"])}">'
                    f'<title>{esc(edge["name"])}</title></path>'
                )
                # one-side tick just outside the parent, crow's foot at the child
                parts.append(
                    f'<line x1="{end_x - outward * 7:.1f}" y1="{ey - 5:.1f}" '
                    f'x2="{end_x - outward * 7:.1f}" y2="{ey + 5:.1f}" '
                    f'stroke="#3b4a66" stroke-width="1.7"/>'
                )
                for dy in (-5.5, 0, 5.5):
                    parts.append(
                        f'<line x1="{start_x:.1f}" y1="{sy:.1f}" '
                        f'x2="{start_x + outward * 11:.1f}" y2="{sy + dy:.1f}" '
                        f'stroke="#3b4a66" stroke-width="1.3"/>'
                    )

    schemas = sorted({t["name"].split(".")[0] for t in model["tables"]})
    palette = {schema: PALETTE[index % len(PALETTE)] for index, schema in enumerate(schemas)}

    for table in model["tables"]:
        b = box[table["name"]]
        fill, ink = palette[table["name"].split(".")[0]]
        parts.append(
            f'<g class="card" transform="translate({b["x"]:.0f} {b["y"]:.0f})">'
        )
        parts.append(
            f'<rect width="{b["w"]}" height="{b["h"]}" rx="12" fill="#ffffff" stroke="#dbe3ef" stroke-width="1" filter="url(#cardShadow)"/>'
        )
        parts.append(
            f'<path d="M0 12a12 12 0 0 1 12-12h{b["w"] - 24}a12 12 0 0 1 12 12v{HEAD_H - 12}H0z" fill="{fill}"/>'
        )
        parts.append(
            f'<text x="16" y="27" font-size="15" font-weight="650" letter-spacing=".1" fill="{ink}">{esc(table["name"].split(".")[-1])}</text>'
        )
        for index, col in enumerate(table["columns"]):
            y = HEAD_H + index * ROW_H + 18
            key = col["pk"]
            marker = "PK" if key else ("FK" if col["fk"] else "")
            if marker:
                tone = "#b8860b" if key else "#4a6fa5"
                parts.append(
                    f'<text x="15" y="{y}" font-size="9.5" font-weight="700" fill="{tone}" letter-spacing=".5">{marker}</text>'
                )
            parts.append(
                f'<text x="45" y="{y}" font-size="12.5" fill="#16202f">{esc(col["name"] if len(col["name"]) <= 25 else col["name"][:24] + "…")}<title>{esc(col["name"])}</title></text>'
            )
            suffix = " NOT NULL" if not col["nullable"] else ""
            label = f'{col["type"]}{suffix}'
            parts.append(
                f'<text x="{b["w"] - 14}" y="{y}" font-size="10" fill="#6b7a90" text-anchor="end">{esc(label)}</text>'
            )
        parts.append("</g>")

    height += 46
    parts.append(
        f'<g class="legend" transform="translate({MARGIN} {height - 34})">'
        '<rect width="470" height="26" rx="6" fill="#ffffff" stroke="#d7dfeb"/>'
        '<text x="12" y="17" font-size="10" font-weight="700" fill="#b8860b">PK</text>'
        '<text x="34" y="17" font-size="11" fill="#5b6779">primary key</text>'
        '<text x="112" y="17" font-size="9" font-weight="700" fill="#4a6fa5">FK</text>'
        '<text x="134" y="17" font-size="11" fill="#5b6779">foreign key</text>'
        '<path d="M232 13 h14" stroke="#7f8ca6" stroke-width="1.4"/>'
        '<line x1="305" y1="8" x2="305" y2="18" stroke="#42506b" stroke-width="1.6"/>'
        '<text x="252" y="17" font-size="11" fill="#5b6779">many</text>'
        '<text x="314" y="17" font-size="11" fill="#5b6779">one</text>'
        '</g>'
    )
    parts.append("</svg>")
    return "".join(parts), {"width": width, "height": height}


SITE_ERDS = ROOT / "site" / "assets" / "erds"

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{db} relationships — Apex Financial Services</title>
<style>
body{{margin:0;background:#060a11;color:#e8edf6;font:15px/1.5 "Inter","Segoe UI",system-ui,sans-serif}}
header{{display:flex;flex-wrap:wrap;gap:10px 16px;align-items:baseline;padding:16px 20px;border-bottom:1px solid rgba(255,255,255,.1)}}
h1{{font-size:16px;margin:0;font-weight:600}}
a{{color:#5fd3c4;text-decoration:none}}
p{{margin:0;color:#93a4bd;font-size:13px;min-width:0}}
a{{white-space:nowrap}}
main{{padding:18px}}
img{{display:block;width:100%;height:auto;background:#f7f9fc;border-radius:12px}}
</style>
</head>
<body>
<header>
  <h1>{db}</h1>
  <p>{tables} tables · {edges} declared foreign keys</p>
  <p style="margin-left:auto"><a href="../../diagrams.html">All diagrams</a></p>
</header>
<main><img src="{db}.svg" alt="Entity relationship diagram for {db}"></main>
</body>
</html>
"""


def export_site_svgs() -> None:
    """Write the diagrams the architecture page embeds (SVG + a small HTML view)."""
    SITE_ERDS.mkdir(parents=True, exist_ok=True)
    for database in DATABASES:
        model = parse(database, extract(database))
        svg, _ = render_svg(model)
        (SITE_ERDS / f"{database}.svg").write_text(svg, encoding="utf-8")
        (SITE_ERDS / f"{database}.html").write_text(
            PAGE.format(db=database, tables=len(model["tables"]), edges=len(model["edges"])),
            encoding="utf-8",
        )
        print(f"  site/assets/erds/{database}.svg  ({len(model['tables'])} tables)")


def main() -> None:
    OUT_DATA.mkdir(parents=True, exist_ok=True)
    models = []
    for database in DATABASES:
        model = parse(database, extract(database))
        (OUT_DATA / f"{database}.json").write_text(
            json.dumps(model, indent=2) + "\n", encoding="utf-8"
        )
        svg, size = render_svg(model)
        models.append({"model": model, "svg": svg, "size": size})
        print(f"{database}: {len(model['tables'])} tables, {len(model['edges'])} relationships, "
              f"{size['width']:.0f}x{size['height']:.0f}")

    panels = []
    tabs = []
    for index, entry in enumerate(models):
        model = entry["model"]
        active = " is-active" if index == 0 else ""
        tabs.append(
            f'<button type="button" class="erd-tab{active}" role="tab" '
            f'aria-selected="{"true" if index == 0 else "false"}" '
            f'data-panel="{esc(model["database"])}">{esc(model["database"].replace("AFS_", ""))}'
            f'<span>{len(model["tables"])} tables</span></button>'
        )
        panels.append(
            f'<section class="erd-panel{active}" id="panel-{esc(model["database"])}" '
            f'data-db="{esc(model["database"])}" role="tabpanel">'
            f'<div class="erd-frame" tabindex="0">{entry["svg"]}</div>'
            f'<p class="erd-note">{len(model["edges"])} declared foreign keys, read from '
            f'<code>sys.foreign_keys</code>.</p></section>'
        )

    html = TEMPLATE.replace("{{TABS}}", "".join(tabs)).replace("{{PANELS}}", "".join(panels))
    OUT_HTML.write_text(html, encoding="utf-8")
    export_site_svgs()
    print(f"wrote {OUT_HTML.relative_to(ROOT)}")


TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AFS estate — entity relationship diagrams</title>
<style>
:root{
  --navy:#0d1b34;--navy-2:#122444;--ink:#1d2637;--muted:#5b6779;
  --line:#d7dfeb;--teal:#1f9d8f;--surface:#f6f8fc;--white:#fff;
}
*{box-sizing:border-box}
body{margin:0;background:var(--navy);color:#e8edf6;
  font:15px/1.55 "Inter","Segoe UI",system-ui,-apple-system,sans-serif}
header{padding:26px 24px 18px;border-bottom:1px solid rgba(255,255,255,.1)}
h1{margin:0 0 6px;font-size:20px;letter-spacing:.2px}
header p{margin:0;color:#9fb0c9;font-size:13.5px;max-width:70ch}
.tabs{display:flex;gap:8px;overflow-x:auto;padding:14px 24px 0}
.erd-tab{flex:0 0 auto;background:rgba(255,255,255,.06);color:#cfd9ea;border:1px solid rgba(255,255,255,.12);
  border-radius:10px 10px 0 0;padding:9px 14px;font:inherit;font-size:13.5px;cursor:pointer;display:flex;
  gap:8px;align-items:center}
.erd-tab span{color:#8fa1ba;font-size:11.5px}
.erd-tab:hover{background:rgba(255,255,255,.12)}
.erd-tab.is-active{background:var(--surface);color:var(--navy);border-color:var(--surface);font-weight:600}
.erd-tab.is-active span{color:#5b6779}
.erd-tab:focus-visible{outline:2px solid var(--teal);outline-offset:2px}
main{background:var(--surface);border-radius:0 14px 14px 14px;margin:0 24px 24px;padding:18px}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
.toolbar button{background:var(--white);border:1px solid var(--line);border-radius:8px;padding:7px 12px;
  font:inherit;font-size:13px;color:var(--navy);cursor:pointer}
.toolbar button:hover{border-color:#a9b6ca}
.toolbar button:focus-visible{outline:2px solid var(--teal);outline-offset:2px}
.toolbar .hint{color:var(--muted);font-size:12.5px;margin-left:auto}
.erd-panel{display:none}
.erd-panel.is-active{display:block}
.erd-frame{overflow:hidden;border:1px solid var(--line);border-radius:12px;background:var(--white);
  cursor:grab;height:min(74vh,760px);touch-action:none}
.erd-frame:active{cursor:grabbing}
.erd-svg{display:block;transform-origin:0 0;transition:transform .06s linear}
.erd-note{margin:10px 2px 0;color:var(--muted);font-size:12.5px}
code{font:12px/1.4 ui-monospace,"Cascadia Mono",Consolas,monospace;background:#eef1f7;padding:1px 5px;border-radius:4px}
@media (max-width:720px){
  header,main{padding-left:16px;padding-right:16px}
  main{margin:0 12px 18px;border-radius:12px}
  .erd-frame{height:62vh}
  .toolbar .hint{display:none}
}
</style>
</head>
<body>
<header>
  <h1>Apex Financial Services — SQL Server entity relationships</h1>
  <p>Generated from the live catalog: table and column metadata from <code>sys.columns</code>,
     relationships from <code>sys.foreign_keys</code>. Only declared foreign keys are drawn.</p>
</header>
<nav class="tabs" role="tablist" aria-label="Database">{{TABS}}</nav>
<main>
  <div class="toolbar">
    <button type="button" data-zoom="fit">Fit</button>
    <button type="button" data-zoom="in">Zoom in</button>
    <button type="button" data-zoom="out">Zoom out</button>
    <button type="button" data-zoom="reset">Reset</button>
    <span class="hint">Drag to pan · scroll to zoom · PK / FK mark key columns</span>
  </div>
  {{PANELS}}
</main>
<script>
(function () {
  var frame = null, scale = 1, x = 0, y = 0, dragging = false, sx = 0, sy = 0;

  function svgEl(panel) { return panel.querySelector('.erd-svg'); }

  function apply() {
    if (!frame) return;
    var svg = frame.querySelector('.erd-svg');
    var w = parseFloat(svg.getAttribute('width'));
    var h = parseFloat(svg.getAttribute('height'));
    var boxW = frame.clientWidth, boxH = frame.clientHeight;
    x = Math.min(0, Math.max(boxW - w * scale, x));
    y = Math.min(0, Math.max(boxH - h * scale, y));
    svg.style.transform = 'translate(' + x + 'px,' + y + 'px) scale(' + scale + ')';
  }

  function fit() {
    if (!frame) return;
    var svg = frame.querySelector('.erd-svg');
    var w = parseFloat(svg.getAttribute('width'));
    var h = parseFloat(svg.getAttribute('height'));
    scale = Math.min(frame.clientWidth / w, frame.clientHeight / h, 1);
    x = (frame.clientWidth - w * scale) / 2;
    y = (frame.clientHeight - h * scale) / 2;
    apply();
  }

  function activate(name) {
    document.querySelectorAll('.erd-tab').forEach(function (t) {
      var on = t.dataset.panel === name;
      t.classList.toggle('is-active', on);
      t.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    document.querySelectorAll('.erd-panel').forEach(function (p) {
      var on = p.dataset.db === name;
      p.classList.toggle('is-active', on);
      if (on) frame = p.querySelector('.erd-frame');
    });
    fit();
    setTimeout(fit, 60);
  }

  document.querySelectorAll('.erd-tab').forEach(function (tab) {
    tab.addEventListener('click', function () { activate(tab.dataset.panel); });
  });

  document.querySelectorAll('[data-zoom]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      if (!frame) return;
      var mode = btn.dataset.zoom;
      if (mode === 'fit') return fit();
      if (mode === 'reset') { scale = 1; x = 0; y = 0; return apply(); }
      var next = mode === 'in' ? scale * 1.2 : scale / 1.2;
      next = Math.max(0.2, Math.min(3, next));
      var cx = frame.clientWidth / 2, cy = frame.clientHeight / 2;
      x = cx - (cx - x) * (next / scale);
      y = cy - (cy - y) * (next / scale);
      scale = next;
      apply();
    });
  });

  document.querySelectorAll('.erd-frame').forEach(function (el) {
    el.addEventListener('pointerdown', function (e) {
      dragging = true; sx = e.clientX - x; sy = e.clientY - y;
      el.setPointerCapture(e.pointerId);
    });
    el.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      x = e.clientX - sx; y = e.clientY - sy; apply();
    });
    el.addEventListener('pointerup', function () { dragging = false; });
    el.addEventListener('wheel', function (e) {
      e.preventDefault();
      var next = Math.max(0.2, Math.min(3, scale * (e.deltaY < 0 ? 1.08 : 0.926)));
      var r = el.getBoundingClientRect();
      var px = e.clientX - r.left, py = e.clientY - r.top;
      x = px - (px - x) * (next / scale);
      y = py - (py - y) * (next / scale);
      scale = next; apply();
    }, { passive: false });
  });

  activate(document.querySelector('.erd-tab.is-active').dataset.panel);
  window.addEventListener('load', function () { if (frame) fit(); });
  window.addEventListener('resize', function () { if (frame) fit(); });
  if (window.ResizeObserver) {
    new ResizeObserver(function () { if (frame) fit(); }).observe(document.querySelector('main'));
  }
})();
</script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
