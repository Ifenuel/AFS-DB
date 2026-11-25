"""Build the portfolio's shared navigation and the pages that are generated.

The site is a set of static pages. This script owns:
  * the grouped navigation (five top-level entries, dropdown panels, mobile groups),
  * `diagrams.html`, generated from live catalog metadata,
  * `oracle.html`,
so the chrome cannot drift between pages.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site"
INVENTORY = json.loads((SITE / "data" / "inventory.json").read_text(encoding="utf-8"))
SQL_INV = INVENTORY["sqlserver"]
TOTALS = SQL_INV["totals"]
INVENTORY_DATE = INVENTORY["generated_at_utc"][:10]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_erds  # noqa: E402

NAV_GROUPS = [
    ("Platform", [
        ("capabilities.html", "Capabilities", "What this proves, discipline by discipline"),
        ("architecture.html", "Schema", "Tables, keys and entity relationships"),
        ("explorer.html", "Explorer", "Browse every table and column"),
        ("diagrams.html", "Diagrams", "Foreign keys drawn per database"),
        ("oracle.html", "Oracle", "26ai Free lab and exercises"),
    ]),
    ("Operations", [
        ("operations.html", "Operations", "Jobs, maintenance and history"),
        ("backup.html", "Backup", "Restores tested end to end"),
        ("monitoring.html", "Monitoring", "Capacity and health"),
        ("incidents.html", "Incidents", "Ten drilled failures"),
        ("change.html", "Change", "Migrations with rollbacks"),
    ]),
    ("Investigations", [
        ("investigations.html", "Research and investigations", "Four documented failures, reproduced and fixed"),
        ("case-p01.html", "P-01 Payment integrity", "Dry posting, duplicates and concurrency"),
        ("case-p02.html", "P-02 Telemetry quality", "Missing, late, duplicate and invalid readings"),
        ("case-p03.html", "P-03 Change and recovery", "Unbounded update, blocking and PITR"),
        ("case-p04.html", "P-04 Security and audit", "Least privilege and an evidence trail"),
    ]),
    ("Assurance", [
        ("security.html", "Security", "Access control and audit"),
        ("performance.html", "Performance", "Measured before and after"),
        ("verification.html", "Evidence", "Every claim sourced"),
    ]),
]

HOME = ("index.html", "Estate", "Overview of the estate")
CONTEXT = ("context.html", "Context", "Why this project exists")
ABOUT = ("about.html", "About", "The engineer behind it")


def top_nav(current: str) -> str:
    parts = [
        f'<a class="nav-link{" active" if current == HOME[0] else ""}" href="{HOME[0]}">{HOME[1]}</a>'
    ]
    for name, items in NAV_GROUPS:
        panel_id = "nav-" + name.lower()
        is_current = any(page == current for page, _, _ in items)
        links = "".join(
            f'<a class="nav-item{" is-current" if page == current else ""}" href="{page}">'
            f'<span class="ni-title">{label}</span><span class="ni-sub">{sub}</span></a>'
            for page, label, sub in items
        )
        parts.append(
            f'<div class="nav-group" data-open="false">'
            f'<button class="nav-trigger{" is-current" if is_current else ""}" type="button" '
            f'aria-expanded="false" aria-controls="{panel_id}">{name}'
            f'<span class="chev" aria-hidden="true"></span></button>'
            f'<div class="nav-panel" id="{panel_id}">{links}</div></div>'
        )
    parts.append(
        f'<a class="nav-link{" active" if current == CONTEXT[0] else ""}" href="{CONTEXT[0]}">'
        f'{CONTEXT[1]}</a>'
    )
    parts.append(
        f'<a class="nav-link{" active" if current == ABOUT[0] else ""}" href="{ABOUT[0]}">'
        f'{ABOUT[1]}</a>'
    )
    return "".join(parts)


def drawer_nav(current: str) -> str:
    parts = [
        f'<a class="drawer-link{" is-current" if current == HOME[0] else ""}" href="{HOME[0]}">'
        f'{HOME[1]}<small>{HOME[2]}</small></a>'
    ]
    for name, items in NAV_GROUPS:
        parts.append(f'<p class="drawer-group">{name}</p>')
        for page, label, sub in items:
            current_class = ' is-current" aria-current="page' if page == current else ""
            parts.append(
                f'<a class="drawer-link{current_class}" href="{page}">{label}<small>{sub}</small></a>'
            )
    parts.append(
        f'<p class="drawer-group">About</p>'
        f'<a class="drawer-link{" is-current" if current == CONTEXT[0] else ""}" '
        f'href="{CONTEXT[0]}">{CONTEXT[1]}<small>{CONTEXT[2]}</small></a>'
        f'<a class="drawer-link{" is-current" if current == ABOUT[0] else ""}" '
        f'href="{ABOUT[0]}">{ABOUT[1]}<small>{ABOUT[2]}</small></a>'
    )
    return "".join(parts)


def _asset_version(name: str) -> str:
    path = SITE / "assets" / name
    return hashlib.md5(path.read_bytes()).hexdigest()[:10] if path.exists() else "1"


def nav_head() -> str:
    return (
        f'<link rel="stylesheet" href="assets/nav.css?v={_asset_version("nav.css")}">\n'
        f'<script src="assets/nav.js?v={_asset_version("nav.js")}" defer></script>'
    )


def ensure_assets(text: str) -> str:
    """Point every page at the current nav assets, replacing stale version strings."""
    css = _asset_version("nav.css")
    js = _asset_version("nav.js")
    text = re.sub(r'<link rel="stylesheet" href="assets/nav\.css(?:\?v=[0-9a-f]+)?">',
                  f'<link rel="stylesheet" href="assets/nav.css?v={css}">', text)
    text = re.sub(r'<script src="assets/nav\.js(?:\?v=[0-9a-f]+)?" defer></script>',
                  f'<script src="assets/nav.js?v={js}" defer></script>', text)
    if "assets/nav.css" not in text:
        text = text.replace("</head>", f'<link rel="stylesheet" href="assets/nav.css?v={css}">\n</head>', 1)
    if "assets/nav.js" not in text:
        text = text.replace("</body>", f'<script src="assets/nav.js?v={js}" defer></script>\n</body>', 1)
    return text


def restamp_assets() -> None:
    """Re-stamp every page (generated or hand-maintained) with the current asset hashes."""
    app = _asset_version("app.css")
    nav = _asset_version("nav.css")
    js = _asset_version("nav.js")
    changed = 0
    for path in sorted(SITE.glob("*.html")):
        text = path.read_text(encoding="utf-8")
        updated = re.sub(r'assets/app\.css(?:\?v=[0-9a-f]+)?', f'assets/app.css?v={app}', text)
        updated = re.sub(r'assets/nav\.css(?:\?v=[0-9a-f]+)?', f'assets/nav.css?v={nav}', updated)
        updated = re.sub(r'assets/nav\.js(?:\?v=[0-9a-f]+)?', f'assets/nav.js?v={js}', updated)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    print(f"restamped assets on {changed} page(s)")


def rewrite_navs() -> int:
    changed = 0
    for path in sorted(SITE.glob("*.html")):
        if path.name in ("diagrams.html", "oracle.html"):
            continue
        text = path.read_text(encoding="utf-8")
        updated = re.sub(
            r'<nav class="nav" aria-label="Sections">.*?</nav>',
            f'<nav class="nav" aria-label="Sections">{top_nav(path.name)}</nav>',
            text, count=1, flags=re.S,
        )
        updated = re.sub(
            r'<nav class="drawer-nav" aria-label="Sections">.*?</nav>',
            f'<nav class="drawer-nav" aria-label="Sections">{drawer_nav(path.name)}</nav>',
            updated, count=1, flags=re.S,
        )
        updated = ensure_assets(updated)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    return changed


def refresh_erd_versions() -> int:
    """Re-point embedded diagrams at a content hash so a stale SVG is never served."""
    changed = 0
    for path in sorted(SITE.glob("*.html")):
        text = path.read_text(encoding="utf-8")

        def repl(match: re.Match) -> str:
            svg = SITE / "assets" / "erds" / match.group(1)
            if not svg.exists():
                return match.group(0)
            digest = hashlib.md5(svg.read_bytes()).hexdigest()[:10]
            return f"assets/erds/{match.group(1)}?v={digest}"

        updated = re.sub(r"assets/erds/(AFS_\w+\.svg)(?:\?v=\w+)?", repl, text)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    return changed


def shell(current: str, title: str, description: str, main: str, extra_head: str = "") -> str:
    return f"""<!doctype html>
<html lang="en" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{title}</title>
<meta name="description" content="{description}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#060a11">
<link rel="icon" href="assets/brand/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="assets/brand/apple-touch-icon.png">
<link rel="stylesheet" href="assets/app.css?v={_asset_version('app.css')}">
{nav_head()}
{extra_head}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="topbar">
  <div class="wrap topbar-inner">
    <a class="brand" href="index.html" aria-label="Apex Financial Services — home">
      <img class="brand-logo" src="assets/brand/logo-mark.png" width="34" height="34" alt="">
      <span class="brand-text">
        <span class="brand-name">Apex Financial Services</span>
        <span class="brand-tag">Database platform</span>
      </span>
    </a>
    <nav class="nav" aria-label="Sections">{top_nav(current)}</nav>
    <button class="menu-btn" type="button" aria-expanded="false" aria-controls="drawer" aria-label="Open menu">
      <span></span>
    </button>
  </div>
</header>
<div class="drawer" id="drawer" aria-hidden="true">
  <div class="drawer-head">
    <span class="brand-name">Apex Financial Services</span>
    <button class="drawer-close" type="button" aria-label="Close menu">&times;</button>
  </div>
  <nav class="drawer-nav" aria-label="Sections">{drawer_nav(current)}</nav>
</div>
<main id="main">
{main}
</main>
<footer class="foot">
  <div class="wrap">
    <div class="foot-inner">
      <div>
        <div class="foot-brand">
          <img src="assets/brand/logo-mark.png" width="38" height="38" alt="">
          <div><strong>Apex Financial Services</strong><span>Database engineering portfolio</span></div>
        </div>
        <p style="margin-top:14px;max-width:40ch">A nine-database SQL Server estate covering customers,
        accounts, transfers, ledger, payments, settlement, fraud, service, reporting and governance &mdash;
        with the constraints, controls and recovery procedures that keep it consistent.</p>
      </div>
      <div>
        <h4>Technology</h4>
        <p>SQL Server 2025 Developer<br>Oracle Database 26ai Free<br>MySQL 8.4.9<br>Python automation &middot; T-SQL</p>
      </div>
      <div>
        <h4>Portfolio</h4>
        <a href="verification.html">Evidence index</a>
        <a href="investigations.html">Research and investigations</a>
        <a href="context.html">Context</a>
        <a href="about.html">About and contact</a>
      </div>
    </div>
    <div class="foot-base">
      <span>Inventory generated {INVENTORY_DATE}; each operational figure keeps the timestamp of its capture. SQL Server: {TOTALS['databases']} databases &middot; {TOTALS['tables']} tables &middot; {TOTALS['foreign_keys']} foreign keys.</span>
      <span class="foot-tag">Research. Engineer. Validate.</span>
    </div>
  </div>
</footer>
<script src="assets/vendor/gsap.min.js?v={_asset_version('vendor/gsap.min.js')}" defer></script>
<script src="assets/site.js?v={_asset_version('site.js')}" defer></script>
</body>
</html>
"""


ERD_STYLE = """<style>
.erd-wrap{border:1px solid rgba(255,255,255,.12);border-radius:18px;background:#f6f8fc;color:#1d2637;padding:16px}
.erd-tabs{display:flex;gap:8px;overflow-x:auto;padding:0 0 14px}
.erd-tab{flex:0 0 auto;background:#eef1f7;border:1px solid #d7dfeb;border-radius:9px;padding:9px 14px;
 font:inherit;font-size:13.5px;color:#22304a;cursor:pointer;display:flex;gap:8px;align-items:center}
.erd-tab span{color:#5b6779;font-size:11.5px}
.erd-tab.is-active{background:#0d1b34;color:#fff;border-color:#0d1b34;font-weight:600}
.erd-tab.is-active span{color:#a9bbd4}
.erd-tab:focus-visible{outline:2px solid #1f9d8f;outline-offset:2px}
.erd-tools{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
.erd-tools button{background:#fff;border:1px solid #d7dfeb;border-radius:8px;padding:7px 12px;font:inherit;font-size:13px;color:#0d1b34;cursor:pointer}
.erd-tools button:hover{border-color:#9fb0c9}
.erd-tools button:focus-visible{outline:2px solid #1f9d8f;outline-offset:2px}
.erd-tools .hint{color:#5b6779;font-size:12.5px;margin-left:auto}
.erd-frame{overflow:hidden;border:1px solid #d7dfeb;border-radius:12px;background:#fff;cursor:grab;
 height:min(72vh,720px);touch-action:none}
.erd-frame:active{cursor:grabbing}
.erd-frame:focus-visible{outline:2px solid #1f9d8f;outline-offset:-2px}
.erd-svg{display:block;transform-origin:0 0}
.erd-panel{display:none}
.erd-panel.is-active{display:block}
.erd-note{margin:10px 2px 0;color:#5b6779;font-size:12.5px}
.erd-note code{background:#eef1f7;padding:1px 5px;border-radius:4px;font-size:12px}
@media (max-width:720px){.erd-frame{height:58vh}.erd-tools .hint{display:none}}
</style>"""

ERD_SCRIPT = """<script>
(function(){
 var frame=null,scale=1,x=0,y=0,dragging=false,sx=0,sy=0;
 function apply(){if(!frame)return;var s=frame.querySelector('.erd-svg');
  var w=+s.getAttribute('width'),h=+s.getAttribute('height');
  x=Math.min(0,Math.max(frame.clientWidth-w*scale,x));
  y=Math.min(0,Math.max(frame.clientHeight-h*scale,y));
  s.style.transform='translate('+x+'px,'+y+'px) scale('+scale+')';}
 function fit(){if(!frame)return;var s=frame.querySelector('.erd-svg');
  var w=+s.getAttribute('width'),h=+s.getAttribute('height');
  scale=Math.min(frame.clientWidth/w,frame.clientHeight/h,1);
  x=(frame.clientWidth-w*scale)/2;y=(frame.clientHeight-h*scale)/2;apply();}
 function activate(name){
  document.querySelectorAll('.erd-tab').forEach(function(t){var on=t.dataset.panel===name;
   t.classList.toggle('is-active',on);t.setAttribute('aria-selected',on?'true':'false');});
  document.querySelectorAll('.erd-panel').forEach(function(p){var on=p.dataset.db===name;
   p.classList.toggle('is-active',on);if(on)frame=p.querySelector('.erd-frame');});
  fit();setTimeout(fit,60);}
 document.querySelectorAll('.erd-tab').forEach(function(t){t.addEventListener('click',function(){activate(t.dataset.panel);});});
 document.querySelectorAll('[data-zoom]').forEach(function(b){b.addEventListener('click',function(){
  if(!frame)return;var m=b.dataset.zoom;
  if(m==='fit')return fit();
  if(m==='reset'){scale=1;x=0;y=0;return apply();}
  var n=Math.max(.2,Math.min(3,m==='in'?scale*1.2:scale/1.2));
  var cx=frame.clientWidth/2,cy=frame.clientHeight/2;
  x=cx-(cx-x)*(n/scale);y=cy-(cy-y)*(n/scale);scale=n;apply();});});
 document.querySelectorAll('.erd-frame').forEach(function(el){
  el.addEventListener('pointerdown',function(e){dragging=true;sx=e.clientX-x;sy=e.clientY-y;el.setPointerCapture(e.pointerId);});
  el.addEventListener('pointermove',function(e){if(!dragging)return;x=e.clientX-sx;y=e.clientY-sy;apply();});
  el.addEventListener('pointerup',function(){dragging=false;});
  el.addEventListener('wheel',function(e){e.preventDefault();
   var n=Math.max(.2,Math.min(3,scale*(e.deltaY<0?1.08:.926))),r=el.getBoundingClientRect();
   var px=e.clientX-r.left,py=e.clientY-r.top;
   x=px-(px-x)*(n/scale);y=py-(py-y)*(n/scale);scale=n;apply();},{passive:false});});
 activate(document.querySelector('.erd-tab.is-active').dataset.panel);
 window.addEventListener('load',fit);window.addEventListener('resize',function(){if(frame)fit();});
})();
</script>"""


def build_diagrams_page() -> None:
    models = []
    for database in build_erds.DATABASES:
        model = build_erds.parse(database, build_erds.extract(database))
        svg, _ = build_erds.render_svg(model)
        models.append((model, svg))

    tabs, panels = [], []
    for index, (model, svg) in enumerate(models):
        active = " is-active" if index == 0 else ""
        tabs.append(
            f'<button type="button" class="erd-tab{active}" role="tab" '
            f'aria-selected="{"true" if index == 0 else "false"}" data-panel="{model["database"]}">'
            f'{model["database"].replace("AFS_", "")}<span>{len(model["tables"])} tables</span></button>'
        )
        panels.append(
            f'<section class="erd-panel{active}" data-db="{model["database"]}" role="tabpanel" '
            f'aria-label="{model["database"]} relationships">'
            f'<div class="erd-frame" tabindex="0">{svg}</div>'
            f'<p class="erd-note">{len(model["edges"])} declared foreign keys read from '
            f'<code>sys.foreign_keys</code>. Only real constraints are drawn.</p></section>'
        )

    main = f"""
  <div class="wrap page-head">
    <div class="kicker" data-hero>Relationships</div>
    <h1 data-hero>The foreign keys, drawn from the catalog</h1>
    <p class="lede" data-hero>Nine diagrams, one per database, generated from the live SQL Server
    metadata. Each card is a table with its real columns and types; each line is a declared foreign
    key, marked with a bar at the referenced table and a crow's foot at the referencing one.</p>
    <div class="badges" data-hero><span class="badge">64 tables</span><span class="badge">46 foreign keys</span>
    <span class="badge">Catalog 2026-11-25</span></div>
  </div>

  <section class="wrap section" data-reveal>
    <div class="erd-wrap">
      <div class="erd-tabs" role="tablist" aria-label="Database">{''.join(tabs)}</div>
      <div class="erd-tools">
        <button type="button" data-zoom="fit">Fit</button>
        <button type="button" data-zoom="in">Zoom in</button>
        <button type="button" data-zoom="out">Zoom out</button>
        <button type="button" data-zoom="reset">Reset</button>
        <span class="hint">Drag to pan · scroll to zoom · PK and FK mark key columns</span>
      </div>
      {''.join(panels)}
    </div>
    <p class="muted small">Some databases hold no foreign keys by design \u2014 Audit is an append-only event store,
    so its diagram shows the tables without inventing relationships between them.</p>
  </section>
"""
    path = SITE / "diagrams.html"
    path.write_text(
        shell("diagrams.html", "Relationships — Apex Financial Services",
              "Entity relationship diagrams for the six AFS SQL Server databases, generated from live catalog metadata.",
              main, ERD_STYLE).replace("</body>", ERD_SCRIPT + "</body>"),
        encoding="utf-8",
    )
    print("wrote site/diagrams.html")


def build_oracle_page() -> None:
    main = """
  <div class="wrap page-head">
    <div class="kicker" data-hero>Oracle lab</div>
    <h1 data-hero>A second engine, administered for real</h1>
    <p class="lede" data-hero>Oracle AI Database 26ai Free runs beside the SQL Server estate, with its
    own pluggable database, a least-privilege schema, SQL and PL/SQL exercises executed against it
    through SQL*Plus, and archive-log recovery proven by restoring a deleted row.</p>
    <div class="badges" data-hero><span class="badge">26ai Free 23.26.4</span><span class="badge">FREE / FREEPDB1</span>
    <span class="badge">Listener 1521</span><span class="badge">ARCHIVELOG</span><span class="badge">Executed 2026-11-24 &middot; rechecked 2026-11-25</span></div>
  </div>

  <section class="wrap section" data-reveal>
    <div class="stat-grid">
      <div class="stat"><span class="stat-label">Version</span><strong>23.26.4</strong><span class="stat-note">26ai Free, x64</span></div>
      <div class="stat"><span class="stat-label">Container</span><strong>FREE</strong><span class="stat-note">READ WRITE</span></div>
      <div class="stat"><span class="stat-label">Pluggable</span><strong>FREEPDB1</strong><span class="stat-note">READ WRITE</span></div>
      <div class="stat"><span class="stat-label">Lab schema</span><strong>AFS_LAB</strong><span class="stat-note">5 privileges, no roles</span></div>
    </div>
  </section>

  <section class="wrap section" data-reveal>
    <div class="section-head">
      <div class="kicker">Exercises</div>
      <h2>What ran on the instance</h2>
      <p>Each item below was executed through SQL*Plus against FREEPDB1 and its output was captured.</p>
    </div>
    <div class="grid-2">
      <div class="panel"><h3>Least-privilege user</h3><p class="muted">AFS_LAB was created in FREEPDB1 with
        CREATE SESSION, TABLE, VIEW, PROCEDURE and SEQUENCE, unlimited quota on USERS, and no roles. The
        dictionary shows exactly those five grants and nothing else.</p></div>
      <div class="panel"><h3>Transaction integrity</h3><p class="muted">A two-account transfer created both
        rows, wrote the matching debit and credit ledger entries in one transaction and committed. Balances
        moved 1,000 to 900 and 500 to 600 with ledger sums of -100 and +100.</p></div>
      <div class="panel"><h3>Execution plan</h3><p class="muted">DBMS_XPLAN on the currency and balance query
        returns TABLE ACCESS FULL with cost 3 and dynamic sampling level 2 — a baseline measured before any
        index is proposed.</p></div>
      <div class="panel"><h3>Instance health</h3><p class="muted">Instance status, open mode, PDB state and
        the listener's registered services were read from v$database, v$pdbs and lsnrctl rather than assumed.</p></div>
    </div>
  </section>

  <section class="wrap section" data-reveal>
    <div class="section-head">
      <div class="kicker">Recovery</div>
      <h2>A deleted row, brought back by redo</h2>
      <p>The instance runs in ARCHIVELOG with RMAN backups, and the recovery claim was tested rather
      than asserted: a committed row was archived, deleted, then recovered from the backup plus
      archived redo.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Item</th><th>Value at the drill</th></tr></thead><tbody>
      <tr><td data-label="Item">Container / pluggable database</td><td data-label="Value at the drill"><span class="mono">FREE</span> / <span class="mono">FREEPDB1</span>, both READ WRITE</td></tr>
      <tr><td data-label="Item">Redo mode</td><td data-label="Value at the drill">ARCHIVELOG, database role PRIMARY (rechecked 2026-11-25)</td></tr>
      <tr><td data-label="Item">Recovery target</td><td data-label="Value at the drill">Point in time 2026-11-24 22:12:35, after the marker commit at 22:12:24 and before its delete at 22:12:43</td></tr>
      <tr><td data-label="Item">Restore procedure</td><td data-label="Value at the drill">RMAN restores the FREEPDB1 datafiles from the 22:11:44 backup, recovers the pluggable database with archived redo <span class="mono">UNTIL TIME</span>, then opens it <span class="mono">RESETLOGS</span></td></tr>
      <tr><td data-label="Item">Result</td><td data-label="Value at the drill">Marker row present exactly once with its original commit timestamp; PDB read-write again</td></tr>
      <tr><td data-label="Item">Limitations</td><td data-label="Value at the drill">One PDB on the same host, restored inside the live container; no Data Guard, no off-host restore. Oracle Free permits one installation per environment, so host-loss recovery is proved on SQL Server instead</td></tr>
    </tbody></table></div>
    <div class="grid-2">
      <div class="panel"><h3>Archive log mode</h3><p class="muted">ARCHIVELOG was enabled on
        2026-11-24 at 22:07, with a 6 GB fast recovery area. Destination 1 reports VALID, and every log
        switch produces an archived log — seven were on disk by the next morning.</p></div>
      <div class="panel"><h3>RMAN, on a schedule</h3><p class="muted">A daily 02:00 task backs up the
        database plus every archived log, then prunes obsolete sets under a two-day retention.
        Control-file autobackup is on, the sets are compressed, and the first scheduled run completed
        with no RMAN or ORA errors.</p></div>
      <div class="panel"><h3>The drill</h3><p class="muted">A marker row was committed at 22:12:24,
        archived, then deleted at 22:12:43. FREEPDB1 was restored from the 22:11:44 datafile backup and
        rolled forward to 22:12:35; the row returned exactly once with its original commit timestamp,
        and the pluggable database opened read-write again.</p></div>
      <div class="panel"><h3>Scope of the test</h3><p class="muted">One pluggable database on the
        same host, restored by RMAN inside the live container, with the task running only while the
        user is logged on. Oracle Free permits one installation per environment, so the host-loss
        rebuild was proved on SQL Server instead: the estate restored onto a second instance in 1.7 s
        with identical row counts.</p></div>
    </div>
  </section>

  <section class="wrap section" data-reveal>
    <div class="section-head">
      <div class="kicker">Method</div>
      <h2>How the lab is administered</h2>
    </div>
    <p class="muted">The instance is reached with SQL*Plus over the listener, and every object is created
    with explicit privileges rather than a broad role grant. Instance state is read from the data
    dictionary and the listener, so the numbers on this page trace to the running database.</p>
  </section>
"""
    path = SITE / "oracle.html"
    path.write_text(
        shell("oracle.html", "Oracle — Apex Financial Services",
              "Oracle AI Database 26ai Free lab: instance facts, least-privilege schema, archive-log backup and a tested pluggable-database point-in-time recovery.",
              main),
        encoding="utf-8",
    )
    print("wrote site/oracle.html")


CAP_CSS = """<style>
.cap-status{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.05em;
 text-transform:uppercase;padding:3px 8px;border-radius:999px;white-space:nowrap}
.cap-status.ok{background:rgba(31,157,143,.16);color:#7ee0d1;border:1px solid rgba(31,157,143,.42)}
.cap-status.part{background:rgba(214,158,46,.14);color:#f0c674;border:1px solid rgba(214,158,46,.4)}
.cap-status.no{background:rgba(255,255,255,.06);color:#9aa7b8;border:1px solid rgba(255,255,255,.18)}
.num{font-variant-numeric:tabular-nums;font-weight:650;color:#fff}
.cap-src{font-size:12.5px;color:#9aa7b8}
.cap-src a{color:#7ee0d1}
</style>"""

CAP_MAIN = f"""
  <div class="wrap page-head">
    <div class="kicker" data-hero>Capabilities</div>
    <h1 data-hero>What this platform proves, discipline by discipline</h1>
    <p class="lede" data-hero>Database administration and database engineering, on three real engines,
    with one rule: every row below carries a number that came from a command, and a status that says how
    far the proof actually goes. Nothing is marked proven because it was configured.</p>
    <div class="badges" data-hero><span class="badge">29 disciplines</span>
    <span class="badge">29 proven</span>
    <span class="badge">limits stated per row</span></div>
  </div>

  <section data-reveal class="wrap">
    <div class="stat-grid">
      <div class="stat"><span class="stat-label">Engines</span><strong>3</strong><span class="stat-note">SQL Server, Oracle, MySQL</span></div>
      <div class="stat"><span class="stat-label">Application tables</span><strong>{TOTALS['tables']}</strong><span class="stat-note">{TOTALS['foreign_keys']} foreign keys · {TOTALS['views']} views</span></div>
      <div class="stat"><span class="stat-label">Verified full backups</span><strong>{TOTALS['databases']}/{TOTALS['databases']}</strong><span class="stat-note">logs every 15 min · ages watched</span></div>
      <div class="stat"><span class="stat-label">Fastest proven restore</span><strong>0.75 s</strong><span class="stat-note">row recovered to a chosen second</span></div>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">The problem</div>
      <h2>Why this exists, in four numbers that are not mine</h2>
      <p>Database work is judged by what happens on the worst day. These published figures describe the
      size of that day, and the rules that now surround it.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Published fact</th><th>Number</th><th>Source</th></tr></thead><tbody>
      <tr><td data-label="Published fact">Share of enterprises where one hour of unplanned downtime costs $300,000 or more</td><td data-label="Number" class="num">93%</td><td data-label="Source" class="cap-src">ITIC, 2025 reliability survey, 2,000 respondents</td></tr>
      <tr><td data-label="Published fact">Enterprises whose hourly downtime exceeds $1 million</td><td data-label="Number" class="num">46%</td><td data-label="Source" class="cap-src">ITIC, 2025</td></tr>
      <tr><td data-label="Published fact">Respondents whose most recent major outage cost over $100,000</td><td data-label="Number" class="num">57%</td><td data-label="Source" class="cap-src">Uptime Institute 2025 survey, annual outage analysis 2026</td></tr>
      <tr><td data-label="Published fact">Date EU financial entities had to document and test backup and restoration procedures (DORA)</td><td data-label="Number" class="num">17 Jan 2025</td><td data-label="Source" class="cap-src">Regulation (EU) 2022/2554</td></tr>
    </tbody></table></div>
    <p class="muted">The same obligation exists in other jurisdictions, with local deadlines — Nigeria's
    CBN data-localisation circular reaches full compliance on 1 January 2027 and covers database
    administration, backup and recovery explicitly. The mechanism is identical everywhere: a firm must be
    able to say what it would lose, and prove it can get it back. That is the work this lab practises.</p>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">The matrix</div>
      <h2>Twenty-nine disciplines, and the honest status of each</h2>
      <p><span class="cap-status ok">Proven</span> means a command produced the number and the output is
      kept. Every row was re-measured on <strong>2026-11-25</strong>; the sweep output is
      <a href="verification.html#53_capability_sweep">the captured sweep</a>. The limits that matter are
      written into the row rather than averaged away: asynchronous log shipping instead of a synchronous
      replica, no hardware HSM, and a simulated plant behind a real Modbus collector.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Discipline</th><th>What was done</th><th>Measured</th><th>Status</th></tr></thead><tbody>
      <tr><td data-label="Discipline">Engine installation and operation</td><td data-label="What was done">SQL Server 2025 Developer, Oracle 26ai Free and MySQL 8.4.9 running on one host, each with its own backup path</td><td data-label="Measured" class="num">3 engines</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Schema and referential integrity</td><td data-label="What was done">Nine databases split by domain, constraints enforced rather than declared in documentation</td><td data-label="Measured" class="num">64 tables · 46 FKs</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Transaction design for money movement</td><td data-label="What was done">Debit, credit, ledger event and audit row commit together or not at all</td><td data-label="Measured" class="num">4 tables · 1 commit</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Idempotency and reconciliation</td><td data-label="What was done">A replayed request settles once; the ledger is compared against account balances</td><td data-label="Measured" class="num">0 mismatches</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Full backup and media verification</td><td data-label="What was done">RESTORE VERIFYONLY WITH CHECKSUM against every database's latest full backup, read from msdb</td><td data-label="Measured" class="num">{TOTALS['databases']} of {TOTALS['databases']} pass</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Log backup cadence</td><td data-label="What was done">Transactional log backups every 15 minutes, with their age checked independently of job status</td><td data-label="Measured" class="num">15 min cadence &middot; age watched</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Encrypted backup media</td><td data-label="What was done">Full backups written with AES-256 under a server certificate; the certificate was removed to test a stolen dump, then re-imported to restore</td><td data-label="Measured" class="num">33111 refusal</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Key custody and rotation</td><td data-label="What was done">TDE protector rotated and exported encrypted to a directory outside the instance, with the passphrase wrapped by DPAPI for the custodian. An encrypted backup was restored only after its certificate came back from custody; every protector is registered with its thumbprint. No hardware HSM</td><td data-label="Measured" class="num">6,168 rows restored from custody</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      
      <tr><td data-label="Discipline">Point-in-time recovery, SQL Server</td><td data-label="What was done">A deleted row restored with STOPAT to the second before deletion</td><td data-label="Measured" class="num">1 row · 0.75 s</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Point-in-time recovery, Oracle</td><td data-label="What was done">Pluggable database recovered with RMAN to before a deleted marker row, then opened resetlogs</td><td data-label="Measured" class="num">row at 22:12:24</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Restore rehearsal, timed</td><td data-label="What was done">Full database restore measured end to end, repeated three times</td><td data-label="Measured" class="num">7.2–8.4 s</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Monitoring that can fail</td><td data-label="What was done">Health check covering backup age, job outcome and log gaps, then deliberately broken to prove it alarms</td><td data-label="Measured" class="num">CRITICAL · exit 2</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Cross-engine backup automation</td><td data-label="What was done">RMAN at 02:00, MySQL dump at 02:30, SQL Server jobs, health check hourly</td><td data-label="Measured" class="num">4 schedules</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Index design under volume</td><td data-label="What was done">One million rows; the obvious index ignored, a covering index chosen by the optimiser</td><td data-label="Measured" class="num">6,700 → 164 reads</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Query plan reading</td><td data-label="What was done">Plans captured with SHOWPLAN_TEXT and I/O counters recorded per statement</td><td data-label="Measured" class="num">41× fewer reads</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Blocking and isolation</td><td data-label="What was done">A holder kept an exclusive lock open; a second session waited on it with a 2.5 s lock timeout, observed live in <code>sys.dm_exec_requests</code></td><td data-label="Measured" class="num">2,514 ms · LCK_M_X</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Least privilege</td><td data-label="What was done">Application identity with no server role: SELECT granted on one reporting view, DENY on the customer and account tables, plus a blast-radius audit that removed a stray mapping</td><td data-label="Measured" class="num">2 denials</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Auditing</td><td data-label="What was done">Dedicated audit database, audit rows written inside the transfer transaction, and failed logins captured by an extended-events session with client and reason</td><td data-label="Measured" class="num">within seconds</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Capacity and growth</td><td data-label="What was done">Every file size, growth step and log-space reading collected per database against a 70% log-alert threshold</td><td data-label="Measured" class="num">1,648 MB · 8 MB growth</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Change management</td><td data-label="What was done">Numbered change records; live rehearsal of the pattern: apply, prove with a query, roll back, confirm the object is gone</td><td data-label="Measured" class="num">with rollback</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Automation surface</td><td data-label="What was done">PowerShell covering backup, restore drills, health, tasks, Oracle and MySQL operations</td><td data-label="Measured" class="num">29 scripts</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Evidence practice</td><td data-label="What was done">Captured outputs indexed by ID and published from a sanitised copy, with a validator that fails the build on a broken link or leaked secret</td><td data-label="Measured" class="num">captures indexed &middot; paths removed</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Reporting separation</td><td data-label="What was done">Report query plan captured with SHOWPLAN_XML to prove it touches the warehouse and never the operational databases</td><td data-label="Measured" class="num">plan: AFS_Reporting only</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Access governance</td><td data-label="What was done">Human and service identities, role grants with approval, quarterly reviews whose revoke decisions actually remove the grant, and session history per principal</td><td data-label="Measured" class="num">240 grants · 4 reviews</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Compliance control testing</td><td data-label="What was done">24 obligations across DORA, CBN, PCI DSS, ISO 27001 and NIST CSF mapped to 30 controls, tested with sample sizes and evidence references; failures become findings and remediation</td><td data-label="Measured" class="num">60 mappings · 120 tests</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Tamper-evident retention</td><td data-label="What was done">Archived records chained with SHA-256, legal holds that block purges, and a verification query that recomputes the chain; a single altered hash was detected and then rolled back</td><td data-label="Measured" class="num">2,000 records · 0 breaks</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">High availability and failover</td><td data-label="What was done">Warm standby on a LocalDB instance with the transaction log shipped every second. A watchdog promotes the standby when the primary stops answering, and the client resolves the new owner from a published endpoint. Asynchronous log shipping, no availability group and no synchronous replica</td><td data-label="Measured" class="num">4.4 s client outage &middot; 0.6 s promotion</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Host-loss recovery</td><td data-label="What was done">The estate was backed up, then rebuilt onto a second SQL Server 2025 instance with its own files and services, as if the original host was gone</td><td data-label="Measured" class="num">11 objects identical · 1.7 s</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
      <tr><td data-label="Discipline">Operational telemetry (historian, SCADA, metering)</td><td data-label="What was done">A Modbus TCP collector reads three plant registers at 1 Hz into the historian schema; a poll failure is written as a gap with its duration and missed samples instead of disappearing. The plant is a simulator: readings are synthetic, the protocol and the database write are real</td><td data-label="Measured" class="num">189 readings &middot; 991 ms average &middot; 5.7 s gap recorded</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>
    </tbody></table></div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Across engines</div>
      <h2>The same discipline, three different mechanisms</h2>
      <p>Portability is not knowing three syntaxes; it is knowing that STOPAT, PDB point-in-time
      recovery and a mysqldump restore answer the same business question with different failure modes.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Engine</th><th>Role in the estate</th><th>Backup mechanism</th><th>Recovery proven</th></tr></thead><tbody>
      <tr><td data-label="Engine">SQL Server 2025 Developer</td><td data-label="Role in the estate">Primary: nine databases, the transactional core</td><td data-label="Backup mechanism">Full plus transaction log, VERIFYONLY WITH CHECKSUM</td><td data-label="Recovery proven">STOPAT to the second; timed restores 7.2–8.4 s</td></tr>
      <tr><td data-label="Engine">Oracle 26ai Free</td><td data-label="Role in the estate">Archive-log mode, FREEPDB1, least-privilege schema</td><td data-label="Backup mechanism">RMAN with a recovery area and retention</td><td data-label="Recovery proven">Pluggable-database PITR, same 1,000-account dataset</td></tr>
      <tr><td data-label="Engine">MySQL 8.4.9</td><td data-label="Role in the estate">Independent engine, separate service and accounts</td><td data-label="Backup mechanism">Nightly dump at 02:30 under a dedicated backup user</td><td data-label="Recovery proven">Dump restored into a scratch schema: 1,000 accounts, 40,000 entries, 0 mismatches</td></tr>
    </tbody></table></div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Verify it</div>
      <h2>Ten minutes, three commands, no trust required</h2>
    </div>
    <div class="grid-2">
      <div class="panel"><h3>Read the estate</h3><p class="muted">Every table, row count and relationship on this site is read from the running catalog, not typed in.</p><p><a href="architecture.html">Schema</a> · <a href="explorer.html">Explorer</a> · <a href="diagrams.html">Diagrams</a></p></div>
      <div class="panel"><h3>Check the recovery</h3><p class="muted">Backup sets, verification results and the two point-in-time recoveries, each with its captured output.</p><p><a href="backup.html">Backup</a> · <a href="oracle.html">Oracle</a> · <a href="verification.html">Evidence</a></p></div>
    </div>
    <div class="panel" style="margin-top:16px"><h3>Run it yourself</h3>
      <p class="mono muted">sqlcmd -S . -E -C -Q "SELECT name, state_desc FROM sys.databases WHERE name LIKE 'AFS%'"</p>
      <p class="mono muted">sqlcmd -S . -E -C -Q "RESTORE VERIFYONLY FROM DISK='&lt;backup-root&gt;\\AFS_CoreBanking_FULL.bak' WITH CHECKSUM"</p>
      <p class="mono muted">powershell -NoProfile -ExecutionPolicy Bypass -File automation\\powershell\\Test-AfsBackupHealth.ps1</p>
      <p class="mono muted">powershell -NoProfile -ExecutionPolicy Bypass -File tools\\drill-host-loss.ps1</p>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Limits</div>
      <h2>What this is not</h2>
    </div>
    <p class="muted">Not production software, never touched real money, not certified against any
    regulation, and not a demonstration of oil-and-gas domain knowledge. It is a lab built to the standard
    those industries demand — provenance, measured recovery, and a written record of what failed — with the
    gaps listed above rather than hidden. What is claimed was measured, and the output is on the
    <a href="verification.html">evidence page</a>.</p>
  </section>
"""


def build_capabilities_page() -> None:
    path = SITE / "capabilities.html"
    path.write_text(
        shell("capabilities.html", "Capabilities — Apex Financial Services",
              "Twenty-nine database disciplines across SQL Server, Oracle and MySQL, each with a measured result and the limits of its proof stated in the row.",
              CAP_MAIN, CAP_CSS),
        encoding="utf-8",
    )
    print("wrote site/capabilities.html")


CONTEXT_MAIN = """
  <div class="wrap page-head">
    <div class="kicker" data-hero>The problem</div>
    <h1 data-hero>One unpatched server became 3 terabytes of stolen payment data</h1>
    <p class="lede" data-hero>In March 2026 a commercial bank and the country's government payment
    infrastructure were breached in a single chain. The first academic reconstruction of it is in the
    <em>Journal of Cyber Security</em> (2026, 8, 357&ndash;371). This page is what a database team can
    actually do about the failures it documents &mdash; with the tests, and the limits.</p>
    <div class="badges" data-hero><span class="badge">CVE-2025-55182 · CVSS 9.8</span>
    <span class="badge">47 days unpatched</span><span class="badge">9 days undetected</span></div>
  </div>

  <section data-reveal class="wrap">
    <div class="stat-grid">
      <div class="stat"><span class="stat-label">Customer records exposed</span><strong>~900,000</strong><span class="stat-note">per the paper</span></div>
      <div class="stat"><span class="stat-label">Data published</span><strong>3 TB</strong><span class="stat-note">source, keys, KYC files</span></div>
      <div class="stat"><span class="stat-label">Days undetected</span><strong>9</strong><span class="stat-note">found by the attacker's post</span></div>
      <div class="stat"><span class="stat-label">Database dumps taken</span><strong>3</strong><span class="stat-note">35,000+ password hashes</span></div>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">The chain</div>
      <h2>Five failures, only one of which is a patch</h2>
      <p>The paper's ablation is the useful part: the remote code execution opened the door, but
      <strong>segmentation</strong> was the linchpin. Remove that one control and a pilot server becomes a
      national incident.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Stage</th><th>What failed in 2026</th><th>What a database team controls</th></tr></thead><tbody>
      <tr><td data-label="Stage"><strong>Initial access</strong></td><td data-label="What failed in 2026">Internet-facing pilot server running a framework with a patched RCE (CVE-2025-55182); patch available 47 days before exploitation.</td><td data-label="What a database team controls">Patch cadence is documented as a change, not a hope &mdash; and the database does not listen on the internet.</td></tr>
      <tr><td data-label="Stage"><strong>Credential access</strong></td><td data-label="What failed in 2026">Encryption keys in a JavaScript file; database connection strings, cloud keys and client secrets committed to a Git repository.</td><td data-label="What a database team controls">No credential in source; the repository build fails on a secret. Passwords live in a git-ignored secrets store.</td></tr>
      <tr><td data-label="Stage"><strong>Lateral movement</strong></td><td data-label="What failed in 2026">Development and pilot systems shared a cluster with production; the trusted peer accepted traffic from the compromised bank.</td><td data-label="What a database team controls">Containment at the database layer: one login, one database, no server role &mdash; a compromised application cannot read the audit or fraud estate.</td></tr>
      <tr><td data-label="Stage"><strong>Collection</strong></td><td data-label="What failed in 2026">Three database dumps, 657,242 KYC documents (588 GB), 46 HSM key files and a Git repository with credentials.</td><td data-label="What a database team controls">Encrypted backup media: a dump without the certificate is noise, proven by a restore that is refused.</td></tr>
      <tr><td data-label="Stage"><strong>Detection</strong></td><td data-label="What failed in 2026">Nine days of hands-on-keyboard activity, discovered when the actor published it.</td><td data-label="What a database team controls">Failed logins and permission changes recorded with client and reason, queryable by the same SQL that runs the estate.</td></tr>
    </tbody></table></div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">The answer in this estate</div>
      <h2>Four controls, each with a test that fails without it</h2>
      <p>These are not configuration claims. Each row is a test that was run against the running engine,
      and the output is kept.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Control</th><th>Test performed</th><th>Result</th><th>Evidence</th></tr></thead><tbody>
      <tr><td data-label="Control"><strong>Encrypted backup media</strong><br><span class="cap-src">AES-256 under a server certificate</span></td><td data-label="Test performed">Restore the encrypted backup with the certificate removed &mdash; the stolen-media case</td><td data-label="Result"><span class="cap-status ok">Refused</span> SQL 33111: cannot find server certificate with that thumbprint. Re-importing the key restores it in 0.7 s.</td><td data-label="Evidence"><a href="verification.html#49_encrypted_backup">captured output</a></td></tr>
      <tr><td data-label="Control"><strong>Least privilege per database</strong><br><span class="cap-src">one login, no server role</span></td><td data-label="Test performed">Read customer and account tables as the application identity</td><td data-label="Result"><span class="cap-status ok">Denied</span> SELECT refused on Customer and Account; the reporting view returns rows; no user mapped in the audit or fraud databases.</td><td data-label="Evidence"><a href="verification.html#50_least_privilege">captured output</a></td></tr>
      <tr><td data-label="Control"><strong>Blast-radius audit</strong><br><span class="cap-src">findings acted on, not just listed</span></td><td data-label="Test performed">Enumerate every database where the application identity had a mapping</td><td data-label="Result"><span class="cap-status ok">Fixed</span> A connect-only user existed in the payments database from earlier work; removed, so the identity now reaches one database.</td><td data-label="Evidence"><a href="verification.html#50_least_privilege">captured output</a></td></tr>
      <tr><td data-label="Control"><strong>Failed-login detection</strong><br><span class="cap-src">extended events, ring buffer</span></td><td data-label="Test performed">Deliberate bad logins from a client, then query the session</td><td data-label="Result"><span class="cap-status ok">Recorded</span> events appear within seconds with the client machine and the rejection reason.</td><td data-label="Evidence"><a href="verification.html#51_failed_login_detection">captured output</a></td></tr>
      <tr><td data-label="Control"><strong>No credentials in source</strong><br><span class="cap-src">scanner inside the build</span></td><td data-label="Test performed">Scan every tracked file for keys, passwords and connection strings</td><td data-label="Result"><span class="cap-status ok">Clean</span> 200+ files scanned, zero findings; the build fails on a hit, so a future commit cannot reintroduce one.</td><td data-label="Evidence">build check</td></tr>
    </tbody></table></div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Check it in five minutes</div>
      <h2>Three commands, run against the live instance</h2>
      <p>Each check below is a command you can run on this instance. Remove the control and it fails; that is what makes it a control rather than a claim.</p>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Check</th><th>Command</th><th>What proves it</th></tr></thead><tbody>
      <tr><td data-label="Check">Encryption is real</td><td data-label="Command"><code class="mono">RESTORE DATABASE proof FROM DISK='&lt;backup-root&gt;\\AFS_Audit_ENCRYPTED.bak'</code></td><td data-label="What proves it">Fails with <strong>33111</strong> until the certificate is imported. No key, no data.</td></tr>
      <tr><td data-label="Check">Privilege is enforced</td><td data-label="Command"><code class="mono">EXECUTE AS USER='afs_app'; SELECT COUNT(*) FROM customer.Customer;</code></td><td data-label="What proves it">Error <strong>229</strong>, permission denied &mdash; then <code>REVERT</code> and the same query returns 1,000 rows.</td></tr>
      <tr><td data-label="Check">Intrusion is recorded</td><td data-label="Command"><code class="mono">SELECT * FROM sys.dm_xe_session_targets</code></td><td data-label="What proves it">The <code>AFS_FailedLogins</code> ring buffer holds each rejected login with client and reason.</td></tr>
    </tbody></table></div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Oil and gas</div>
      <h2>Same controls, different plant</h2>
    </div>
    <p class="muted">Imran et al. (<em>Computers &amp; Security</em> 167, 2026, 104918) interviewed 23
    practitioners across Gulf upstream operators and found the IT/OT boundary governed by neither
    framework cleanly: ISO/IEC 27001 covers the enterprise, IEC 62443 covers the control system, and the
    seam between them is where process, people and technology fail together. Their framework adds
    <em>process</em> as a first-class dimension because segmentation on paper did not survive operational
    pressure.</p>
    <p class="muted">That is the same conclusion the 2026 breach paper reached from the other direction,
    and it is testable in a transactional estate: can one identity reach a system it has no business
    reaching, can a stolen file be read, and would anyone know it happened. The answers here are no, no
    and yes. What is <strong>not</strong> claimed: historians, SCADA, safety instrumented systems, the OT
    network, or any IEC 62443 certification. Those need plant access this lab does not have.</p>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Limits</div>
      <h2>What this does not cover</h2>
    </div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Gap</th><th>Honest position</th></tr></thead><tbody>
      <tr><td data-label="Gap">Network segmentation</td><td data-label="Honest position">The estate is one host. Containment is demonstrated at the database layer only; there is no VLAN, firewall zone or jump host to show.</td></tr>
      <tr><td data-label="Gap">Endpoint and SIEM</td><td data-label="Honest position">No EDR, no log pipeline. Detection here is a SQL extended-events session, which proves the record exists, not that a SOC would act on it.</td></tr>
      <tr><td data-label="Gap">Key management</td><td data-label="Honest position">The TDE protector is rotated, exported encrypted to a custody directory outside the instance, and its passphrase is wrapped for the custodian only; an encrypted backup is unreadable once the certificate is dropped. The remaining limitation is hardware: without an HSM or external KMS the custody boundary is a Windows account, not a tamper-resistant device.</td></tr>
      <tr><td data-label="Gap">SQL authentication</td><td data-label="Honest position">The instance is Windows-authentication only, so privilege tests use impersonation rather than a live SQL login. Mixed mode would be required to demonstrate a network login path.</td></tr>
    </tbody></table></div>
    <p class="muted">The full argument, the papers behind it and the captured output for every number
    are on the <a href="verification.html">evidence page</a>.</p>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head"><div class="kicker">Sources</div><h2>What this page is built on</h2></div>
    <div class="table-wrap"><table class="data"><thead><tr><th>Source</th><th>Use here</th></tr></thead><tbody>
      <tr><td data-label="Source">Amaechi et al., <em>From One Unpatched Server to National Exposure: The Sterling Bank&ndash;Remita Chain Breach of 2026</em>, Journal of Cyber Security 8 (2026) 357&ndash;371, doi:10.32604/jcs.2026.084201</td><td data-label="Use here">The failure chain, the figures (900,000 records, 3 TB, 9 days, 47 days) and the ablation finding on segmentation</td></tr>
      <tr><td data-label="Source">Imran et al., <em>Human-centered cybersecurity risk management for IT/OT-converged oil and gas operating facilities</em>, Computers &amp; Security 167 (2026) 104918, doi:10.1016/j.cose.2026.104918</td><td data-label="Use here">The oil-and-gas parallel: segmentation and privilege at the IT/OT boundary</td></tr>
      <tr><td data-label="Source">CBN data-localisation circular (15 June 2026) and FAQ (4 November 2026)</td><td data-label="Use here">Database administration and backup/recovery in scope from 1 January 2027</td></tr>
      <tr><td data-label="Source">Regulation (EU) 2022/2554 (DORA), applicable 17 January 2025</td><td data-label="Use here">Documented and tested restoration as a legal obligation</td></tr>
      <tr><td data-label="Source">ITIC, 2025 Global Server Hardware and Server OS Reliability Survey</td><td data-label="Use here">The cost of one hour of downtime</td></tr>
    </tbody></table></div>
  </section>
"""


def build_context_page() -> None:
    path = SITE / "context.html"
    path.write_text(
        shell("context.html", "The problem — Apex Financial Services",
              "The March 2026 Sterling Bank-Remita chain breach, reconstructed in the Journal of Cyber Security, and the four database controls this estate uses against it.",
              CONTEXT_MAIN, CAP_CSS),
        encoding="utf-8",
    )
    print("wrote site/context.html")


PAGE_INTRO = """  <div class="wrap page-head">
    <div class="kicker" data-hero>Evidence</div>
    <h1 data-hero>The output, exactly as the tools printed it</h1>
    <p class="lede" data-hero>Every claim on this site ends in a command, and this is what those commands
    returned. Nothing below is retyped: it is the captured output, including the failures that came before
    the fix, published from a sanitised copy. Workstation paths, account names, certificate thumbprints and
    process ids become bracketed tokens; engine versions, SQL error numbers, object names, timestamps and
    measurements are unchanged.</p>
    <div class="badges" data-hero><span class="badge">13 captures shown</span>
    <span class="badge">Re-run on 2026-11-25</span><span class="badge">Copy, paste, repeat</span></div>
  </div>
"""

EVIDENCE_CARD = """  <section data-reveal class="wrap section">
    <article class="ev" id="{stem}">
      <h3>{title}</h3>
      <p class="meta">{what}</p>
      <p class="meta"><b>Result.</b> {proves}</p>
      <pre class="term">{output}</pre>
    </article>
  </section>
"""

HONESTY_BLOCK = """  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Honesty</div>
      <h2>What this audit changed, including the parts that looked worse</h2>
      <p>Three governance databases were added on 24 November, after the nightly full backup had already
      run. They were online, constrained and queryable \u2014 and they had no backup history at all. The
      scheduled log job then failed every 15 minutes because it cannot back up a log with no full backup
      behind it. The health check caught exactly that and returned CRITICAL; it was not silenced. Full
      backups were taken for all nine, VERIFYONLY passed 9/9, the three databases were restored to scratch
      copies with identical row counts, and the check returned 46 OK. Both states are published above.</p>
      <p>The public numbers were also rebuilt from one inventory rather than retyped: 64 application
      tables (the six dbo.sysdiagrams support tables are excluded), 46 foreign keys, 11 views and nine
      application procedures. Backup counts are stated with a timestamp because msdb grows every 15
      minutes; a fixed total would be wrong by lunchtime. The 6/6 backup badge, the 24-discipline count
      and the 202-versus-217 split were three different scopes being printed as one.</p>
    </div>
  </section>
"""


EVIDENCE_CSS = """<style>
.term{background:#070c14;border:1px solid #1e2b3d;border-radius:12px;padding:16px 18px;margin:0;
 overflow:auto;max-height:460px;font:12.5px/1.65 ui-monospace,SFMono-Regular,"Cascadia Mono",Consolas,monospace;
 color:#c7d5e6;white-space:pre;tab-size:2}
.term::-webkit-scrollbar{width:10px;height:10px}
.term::-webkit-scrollbar-thumb{background:#22334a;border-radius:8px}
.ev{border-left:2px solid rgba(31,157,143,.55);padding-left:18px;margin-top:34px}
.ev h3{margin:0 0 6px;font-size:18px;letter-spacing:-.01em}
.ev .meta{margin:0 0 12px;color:#9aa7b8;font-size:13px}
.ev .meta b{color:#cfdae8;font-weight:600}
</style>"""

EVIDENCE_FILES = [
    ("49_encrypted_backup", "A stolen backup file is worthless",
     "The audit database was backed up with AES-256 under a server certificate. The certificate is then "
     "removed, exactly as it would be on a host the attacker controls, and the restore is attempted.",
     "Refused with SQL error 33111 until the certificate is imported; then the same file restores in 0.7 s."),
    ("50_least_privilege", "One identity, one database",
     "The application identity is made to read the tables it should not see, then the tables it should.",
     "Permission denied (229) on customer and account, the reporting view returns 1,000 rows, and the stray "
     "connect-only login is removed from the payments database."),
    ("51_failed_login_detection", "A rejected login leaves a record",
     "Five deliberate bad logins are attempted from a client machine while the extended-events session is running.",
     "The session records the rejection with its reason and the client host within seconds, and the audit "
     "table already holds 60 login events — the trail a breach investigation needs and rarely gets."),
    ("52_dataset_load", "The ledger is the balance",
     "Twenty thousand transfers were posted against 1,000 accounts, each writing a double entry into the ledger.",
     "Balance equals opening balance plus the summed ledger for every account: 0 mismatches, 0 negative balances."),
    ("53_capability_sweep", "Every capability measured on the same day",
     "One sweep collects blocking, capacity, plan, change and object counts from the live instance.",
     "A 2,520 ms lock wait surfaces as LCK_M_X; the reporting query is confined to the warehouse; every count is printed."),
    ("54_host_loss_restore", "The estate rebuilds on another machine",
     "A fresh backup of both databases is restored onto a second SQL Server 2025 instance with its own "
     "service and files — the same operation as rebuilding after the original host is lost.",
     "Eleven objects match the live estate row for row, balances still reconcile, total restore 1.7 s."),
    ("55_standby_failover", "The estate runs on a second instance",
     "A second instance receives the backup stream: full restore with NORECOVERY, then the transaction log, "
     "so it stays consistent and unreadable until it is needed.",
     "Manual failover completes in 0.28 s, the standby comes online with 1,000 accounts, 20,000 transfers and "
     "40,000 ledger entries, and the accounting invariant still holds."),
    ("56_governance_databases", "Identity, control testing and retention are queryable",
     "Three further databases model what most estates keep in spreadsheets: who holds which grant and when it "
     "was reviewed, which control answers which obligation and when it last failed, and which records are "
     "retained under hold.",
     "240 grants and 4 reviews reconcile, 120 control tests produce findings with remediation, and the archive "
     "hash chain shows zero breaks until one row is deliberately altered \u2014 which the check catches."),
    ("59_automatic_failover", "Failover the application does not perform",
     "A LocalDB standby receives the log every second while a watchdog and a client probe run; the primary database "
     "is then taken offline without warning.",
     "Detection 969 ms, promotion 607 ms, client reads recovered after 4.4 s, and a row committed 1.3 s before the "
     "outage was present on the promoted standby."),
    ("60_key_custody", "A key you cannot get back is not a key",
     "TDE is enabled, its protector rotated and exported encrypted; an encrypted backup is read after the "
     "certificate is dropped from the instance.",
     "The restore is refused with a missing-thumbprint error, then succeeds from the custodied certificate with all "
     "6,168 rows intact."),
    ("61_telemetry", "A plant that reports in seconds, not transactions",
     "A Modbus TCP simulator serves three holding registers; the collector writes 1 Hz readings into the historian "
     "and the simulator is stopped for seven seconds mid-run.",
     "189 readings at a 991 ms average interval, with the 5.7 s outage recorded as a gap of five missed samples "
     "rather than silently missing rows."),
    ("62_backup_coverage", "Every database, not just the first six",
     "VERIFYONLY is run against the most recent FULL backup of every AFS database, with the file list "
     "read from msdb rather than typed into the script.",
     "Nine databases checked, nine verified, zero missing. The three governance databases had no backup "
     "history when this audit began; that is the gap the next capture shows being caught."),
    ("63_restore_coverage", "The three newest databases restore",
     "Each governance database is restored under a scratch name with MOVE, compared table for table "
     "and row for row, then dropped.",
     "Identity, Compliance and Archive all restore identical: 7/9/7 tables and 3,785/261/2,737 rows, "
     "with the named detail table matching in every case."),
    ("64_health_check_caught_gap", "The monitor caught the gap it was built for",
     "The hourly health check ran while three databases still had no full backup. This is the unedited "
     "result, including the failed log-backup job it exposed.",
     "Overall CRITICAL: one failed check, the 15-minute log job, because it tried to back up logs for "
     "databases with no full backup. The alert was correct, not a false positive."),
    ("65_health_check", "And then it went quiet for the right reason",
     "The same check after full backups were taken for all nine databases.",
     "Overall OK: 46 checks, zero critical, zero warnings, including full and log freshness for every "
     "database and every Agent job outcome."),
    ("58_lab_scale", "Oracle and MySQL carry the same estate, not a sample",
     "Both portability labs were reloaded to the size of the SQL Server core: 1,000 accounts and 20,000 "
     "double-entry transfers, then reconciled and dumped.",
     "Oracle and MySQL each report 1,000 accounts and 40,000 ledger entries with zero balance mismatches, "
     "and the MySQL dump restores into a scratch schema with identical counts."),
    ("57_three_engines", "All three engines answer, on the same day",
     "One check queries SQL Server, Oracle and MySQL: version, open mode, archive-log setting and the rows"
     "each engine actually holds.",
     "SQL Server reports nine AFS databases, Oracle FREEPDB1 is READ WRITE in ARCHIVELOG with its AFS_LAB"
     " schema answering, and MySQL 8.4.9 returns its own schema and rows."),
]


def build_verification_page() -> None:
    live = ROOT / "evidence" / "public"
    parts = [PAGE_INTRO.replace("13 captures shown", f"{len(EVIDENCE_FILES)} captures shown")]
    for stem, title, what, proves in EVIDENCE_FILES:
        source = live / (stem + ".txt")
        text = source.read_text(encoding="utf-8-sig").replace(chr(13), "").rstrip()
        escaped = (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        parts.append(EVIDENCE_CARD.format(stem=stem, title=title, what=what,
                                          proves=proves, output=escaped))
    parts.append(HONESTY_BLOCK)
    (SITE / "verification.html").write_text(
        shell("verification.html", "Evidence — Apex Financial Services",
              "The verbatim output behind every claim: encrypted-backup refusal, least privilege, failed-login capture, dataset integrity, the capability sweep and a host-loss rebuild.",
              chr(10).join(parts), EVIDENCE_CSS),
        encoding="utf-8",
    )
    print("wrote site/verification.html")



ABOUT_CSS = """<style>
.about-hero{padding:118px 0 26px;position:relative;overflow:clip}
.about-hero:before{content:"";position:absolute;inset:-20% 40% 30% -10%;pointer-events:none;
 background:radial-gradient(50% 50% at 30% 30%,rgba(61,187,247,.16),transparent 70%),
            radial-gradient(45% 45% at 80% 60%,rgba(177,140,248,.14),transparent 72%);filter:blur(10px)}
.about-grid{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:64px;align-items:center;position:relative}
.about-name{font-size:clamp(38px,5vw,62px);line-height:1.02;letter-spacing:-.04em;margin:16px 0 0}
.about-name em{font-style:normal;background:linear-gradient(94deg,#7ee0d1,#8b93f8 52%,#c4a6ff);
 -webkit-background-clip:text;background-clip:text;color:transparent}
.about-role{margin:18px 0 0;font:500 13px/1.4 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:#8fa4bd}
.about-chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:24px}
.about-chips span{border:1px solid var(--line-2);border-radius:999px;padding:6px 12px;
 font:11.5px/1 var(--mono);color:#a9bacf;background:rgba(255,255,255,.02)}
.about-actions{display:flex;flex-wrap:wrap;gap:12px;margin-top:30px}
.about-actions .btn{display:inline-flex;align-items:center;gap:8px;padding:11px 18px;border-radius:10px;
 border:1px solid var(--line-2);font:500 13.5px/1 var(--display);letter-spacing:-.01em}
.about-actions .btn.solid{background:linear-gradient(180deg,rgba(61,187,247,.22),rgba(61,187,247,.10));
 border-color:rgba(61,187,247,.45);color:#eaf6ff}
.portrait{position:relative;margin:0;--mx:0;--my:0}
.portrait-glow{position:absolute;inset:-46px;border-radius:50%;z-index:0;pointer-events:none;
 background:radial-gradient(50% 50% at 50% 45%,rgba(61,187,247,.30),rgba(139,147,248,.12) 45%,transparent 72%);
 filter:blur(28px);opacity:.9}
.portrait-frame{position:relative;z-index:1;border-radius:22px;padding:1px;overflow:hidden;
 background:linear-gradient(150deg,rgba(126,224,209,.75),rgba(139,147,248,.35) 45%,rgba(255,255,255,.06) 75%);
 transform:perspective(900px) rotateX(calc(var(--my) * -4deg)) rotateY(calc(var(--mx) * 5deg));
 transition:transform .35s cubic-bezier(.22,.61,.36,1);will-change:transform}
.portrait-frame img{display:block;width:100%;height:auto;border-radius:21px;
 filter:contrast(1.04) saturate(.95)}
.portrait figcaption{margin-top:14px;font:11.5px/1.5 var(--mono);color:#8fa4bd;display:flex;
 justify-content:space-between;gap:12px}
.portrait figcaption b{color:#cfe0f2;font-weight:500}
.about-tag{position:absolute;z-index:2;left:16px;bottom:70px;display:flex;align-items:center;gap:8px;
 background:rgba(6,10,17,.82);border:1px solid rgba(255,255,255,.14);border-radius:10px;
 padding:8px 12px;font:11px/1 var(--mono);color:#d9e6f5;backdrop-filter:blur(10px)}
.about-tag i{width:6px;height:6px;border-radius:50%;background:#3ddc97;box-shadow:0 0 0 3px rgba(61,220,151,.16)}
.about-facts{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin:44px 0 0}
.about-facts .stat{padding:18px 20px}
.about-facts .stat strong{font-family:var(--display);font-weight:500;font-size:30px;letter-spacing:-.03em}
.about-split{display:grid;grid-template-columns:minmax(0,.9fr) minmax(0,1.1fr);gap:56px;align-items:start}
.about-split .section-head{margin:0;position:sticky;top:108px}
.about-stages{display:grid;gap:14px}
.stage{display:grid;grid-template-columns:auto 1fr;gap:16px;padding:20px 22px;border:1px solid var(--line);
 border-radius:14px;background:linear-gradient(180deg,rgba(255,255,255,.035),rgba(255,255,255,0));}
.stage .n{width:30px;height:30px;border-radius:9px;display:grid;place-items:center;
 font:600 12px/1 var(--mono);color:#7ee0d1;border:1px solid rgba(126,224,209,.32);background:rgba(126,224,209,.07)}
.stage h3{margin:2px 0 6px;font-size:16.5px}
.stage p{margin:0;color:var(--muted);font-size:14.5px;line-height:1.62}
.about-cards{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
.about-card{position:relative;padding:24px 26px;border:1px solid var(--line);border-radius:16px;
 background:var(--panel);overflow:hidden;transition:transform .3s ease,border-color .3s ease}
.about-card:after{content:"";position:absolute;inset:0;border-radius:16px;pointer-events:none;opacity:0;
 background:radial-gradient(60% 60% at 20% 0%,rgba(61,187,247,.14),transparent 70%);transition:opacity .3s ease}
.about-card:hover{transform:translateY(-3px);border-color:rgba(61,187,247,.35)}
.about-card:hover:after{opacity:1}
.about-card h3{margin:0 0 8px;font-size:17px}
.about-card p{margin:0;color:var(--muted);font-size:14.5px;line-height:1.62}
.about-card .tag{display:inline-block;margin-bottom:12px;font:11px/1 var(--mono);letter-spacing:.12em;
 text-transform:uppercase;color:#7ee0d1}
.about-stack{display:flex;flex-wrap:wrap;gap:10px;margin-top:22px}
.about-stack span{padding:8px 14px;border:1px solid var(--line-2);border-radius:10px;
 font:12px/1 var(--mono);color:#b7c6d9;background:rgba(255,255,255,.02)}
.about-cta{margin-top:26px;display:flex;flex-wrap:wrap;gap:14px;align-items:center}
@media(max-width:980px){
 .about-grid{grid-template-columns:1fr;gap:34px}
 .portrait{max-width:420px}
 .about-split{grid-template-columns:1fr;gap:26px}
 .about-split .section-head{position:static}
 .about-cards{grid-template-columns:1fr}
 .about-facts{grid-template-columns:repeat(2,minmax(0,1fr))}
}
@media(prefers-reduced-motion:reduce){.portrait-frame{transform:none}}
</style>"""

ABOUT_MAIN = """
  <section class="about-hero wrap">
    <div class="about-grid">
      <div>
        <p class="kicker">About</p>
        <h1 class="about-name" data-hero>Awoyo Emmanuel<br><em>Ifeoluwa</em></h1>
        <p class="about-role" data-hero>Database administration &middot; database engineering &middot; full-stack</p>
        <p class="lede" data-hero style="margin-top:20px">I build and run the database layer: nine databases
        across SQL Server, Oracle and MySQL, with the constraints, recovery proofs and privilege boundaries
        that keep money consistent.</p>
        <p class="lede" data-hero style="margin-top:14px">I am looking for a database administration or
        database engineering role. The failures worth designing for are the quiet ones &mdash; an untested
        restore, a grant nobody reviewed, a report that queries production &mdash; and the work on this site
        is the evidence that I can meet them.</p>
        <div class="about-chips" data-hero>
          <span>SQL Server 2025</span><span>Oracle 26ai</span><span>MySQL 8.4</span>
          <span>T-SQL</span><span>RMAN</span><span>PowerShell</span>
        </div>
        <div class="about-actions" data-hero>
          <a class="btn solid" href="verification.html">See the captured evidence</a>
          <a class="btn" href="capabilities.html">What is proven</a>
          <a class="btn" href="mailto:awoyoemmanuel12@gmail.com?subject=Database%20role%20%E2%80%94%20portfolio">Email me</a>
          <a class="btn" href="https://github.com/Ifenuel" rel="me noopener" target="_blank">GitHub</a>
        </div>
        <div class="about-contact">
          <a href="mailto:awoyoemmanuel12@gmail.com">awoyoemmanuel12@gmail.com</a>
          <span aria-hidden="true">&middot;</span>
          <a href="https://github.com/Ifenuel" rel="me noopener" target="_blank">github.com/Ifenuel</a>
        </div>
      </div>
      <figure class="portrait" data-tilt>
        <div class="portrait-glow"></div>
        <div class="portrait-frame">
          <img src="assets/brand/awoyo-emmanuel.webp" alt="Awoyo Emmanuel Ifeoluwa" width="864" height="925">
        </div>
        <div class="about-tag"><i></i>Awoyo Emmanuel Ifeoluwa</div>
        <figcaption><b>Portrait</b><span>Database administration &middot; 2026</span></figcaption>
      </figure>
    </div>

    <div class="about-facts" data-reveal>
      <div class="stat"><span class="stat-label">Databases</span><strong>9</strong><span class="stat-note">built and operated</span></div>
      <div class="stat"><span class="stat-label">Engines</span><strong>3</strong><span class="stat-note">SQL Server, Oracle, MySQL</span></div>
      <div class="stat"><span class="stat-label">Tables</span><strong>64</strong><span class="stat-note">with constraints</span></div>
      <div class="stat"><span class="stat-label">Captures</span><strong>17</strong><span class="stat-note">sanitised output</span></div>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="about-split">
      <div class="section-head">
        <div class="kicker">Background</div>
        <h2>Systems thinking, applied where mistakes are expensive</h2>
        <p>A database either reconciles or it does not. I read it the way I read any system: change one
        variable, follow the consequence, and defend the conclusion with output rather than opinion. That is
        why every claim on this site has a capture behind it.</p>
      </div>
      <div class="about-stages">
        <article class="stage"><div class="n">01</div><div><h3>Software, built end to end</h3>
          <p>Two years of interfaces, services, scripts and data flows. Building the application first is why
          I know how easily it produces rows that nobody can explain later.</p></div></article>
        <article class="stage"><div class="n">02</div><div><h3>Then the layer that outlives the feature</h3>
          <p>Constraints, recovery, privilege and audit. The work below was built schema by schema over
          several months, and every drill was repeated until it could be reproduced from a clean start.</p></div></article>
        <article class="stage"><div class="n">03</div><div><h3>Months on this estate</h3>
          <p>Nine databases, 64 constrained tables, three engines, encrypted backups, least privilege, access
          reviews, control testing, a hash-chained archive and two recovery drills. Built schema by schema,
          not assembled for a screenshot.</p></div></article>
        <article class="stage"><div class="n">04</div><div><h3>Next: database administration</h3>
          <p>I want the role where recovery time, privilege boundaries and audit evidence are the job
          description rather than an afterthought.</p></div></article>
      </div>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">What the months produced</div>
      <h2>Proof instead of promise</h2>
      <p>Every number below is generated by a command and kept on the evidence page, including the ones that
      failed first. That is the standard I want to be held to.</p>
    </div>
    <div class="about-cards">
      <article class="about-card"><span class="tag">Recovery</span><h3>A backup is a hypothesis</h3>
        <p>Restores are drilled to a chosen second, the estate is rebuilt on a second instance in 1.7 s, and a
        warm standby is promoted by a watchdog in 0.6 s, without a human. If it has not been restored, it is not a backup.</p></article>
      <article class="about-card"><span class="tag">Privilege</span><h3>Reach one database, not nine</h3>
        <p>The application identity is denied the tables it should not read. Grants are reviewed quarterly and
        the revoke decision actually removes the grant.</p></article>
      <article class="about-card"><span class="tag">Audit</span><h3>Evidence that survives the admin</h3>
        <p>Failed logins are captured with client detail, and archived records are hash-chained so a single
        altered row is provable rather than suspected.</p></article>
      <article class="about-card"><span class="tag">Honesty</span><h3>Name the gap</h3>
        <p>A watchdog promotes the warm standby in 0.6 s while a client sees 4.4 s of failed reads, the TDE protector is rotated with its key held outside the instance, and a Modbus collector records plant data &mdash; gaps included. What a lab cannot fake is a hardware HSM, and that is the one absence still named.</p></article>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Toolkit</div>
      <h2>What I actually use</h2>
      <p>Not a logo wall. These are the tools behind the numbers on this site, each exercised in a capture.</p>
    </div>
    <div class="about-stack">
      <span>SQL Server 2025</span><span>T-SQL</span><span>Query plans</span><span>Extended Events</span>
      <span>Oracle 26ai</span><span>RMAN</span><span>PL/SQL</span><span>MySQL 8.4</span>
      <span>PowerShell</span><span>Python</span><span>JavaScript</span><span>Git</span><span>Bash</span>
    </div>
  </section>

  <section data-reveal class="wrap section">
    <div class="section-head">
      <div class="kicker">Next</div>
      <h2>Give me the estate and I will keep it recoverable</h2>
      <p>I am applying for database administration and database engineering roles in financial services or
      energy &mdash; and I am equally comfortable starting on the application side, because I have built
      both. What I want is a team that will judge me on the work: an untested restore, a shared administrator
      account, a log nobody reads, a report that quietly queries production. Those are the problems I have
      spent months learning to solve properly.</p>
    </div>
    <div class="about-cta">
      <a class="btn solid" href="verification.html">The captured output</a>
      <a class="btn" href="capabilities.html">The capability matrix</a>
      <a class="btn" href="context.html">The problem this answers</a>
    </div>
  </section>
"""


def build_about_page() -> None:
    (SITE / "about.html").write_text(
        shell("about.html", "About \u2014 Awoyo Emmanuel Ifeoluwa",
              "Awoyo Emmanuel Ifeoluwa: database administration and engineering across SQL Server, Oracle and MySQL, with measured recovery, least privilege and tamper-evident audit from a nine-database estate.",
              ABOUT_MAIN, ABOUT_CSS),
        encoding="utf-8",
    )
    print("wrote site/about.html")


def build_investigations_page() -> None:
    """Research register and case studies, rendered from executed evidence JSON."""
    import json

    root = SITE.parent

    def load(rel: str) -> dict:
        try:
            return json.loads((root / "evidence" / "research" / rel).read_text(encoding="utf-8"))
        except Exception:
            return {}

    p1 = load("P-01/p01-latest.json")
    p2 = load("P-02/p02-latest.json")
    p3 = load("P-03/p03-latest.json")
    p4 = load("P-04/p04-latest.json")

    def passed(p: dict) -> int:
        return int(p.get("summary", {}).get("passed", 0))

    def total(p: dict) -> int:
        return int(p.get("summary", {}).get("total", 0))

    checks = sum(passed(p) for p in (p1, p2, p3, p4))
    checks_total = sum(total(p) for p in (p1, p2, p3, p4))

    p1_base = p1.get("baseline", {})
    p1_fixed = p1.get("fixed", {})
    p2_col = p2.get("collector", {})
    p2_out = p2.get("outcomes", {})
    p2_reasons = p2.get("quarantine_reasons", {})
    ratios = [c.get("ratio", 1) for c in p2.get("completeness", [])] or [1]
    p3_t = p3.get("timings_seconds", {})
    p3_b = p3.get("blocking_seconds", {})
    p4_base = p4.get("baseline", {})
    p4_after = p4.get("after", {})

    defs = [
        ("P-01", "Payment integrity",
         "NIBSS dry posting, 6-9 Sep 2024: credits without debits, N13.66bn, 176 accounts",
         "Credits without debits are documented. The defect itself is not public, so the mechanism is reproduced, not the incident."),
        ("P-02", "Telemetry data quality",
         "Oil-and-gas and industrial IoT research; Seplat discloses IT/OT and data-correction risk",
         "Missing, late, duplicate, out-of-order and unit-faulted readings are industry research findings, not a named operator's incident."),
        ("P-03", "Change and recovery",
         "Clerk, 6 Feb 2025: one manual UPDATE took a service down for 26 minutes; ECB, 27 Feb 2025: storage fault misread as a database fault",
         "Both incidents are documented. The storage failure is modelled at the database layer, not reproduced in hardware."),
        ("P-04", "Privileged access and audit",
         "Clerk's direct database access outside change control; Seplat's top-ranked cyber risk and access-rights control",
         "Over-privilege is a documented risk with one documented case; no claim is made about any bank's internal access model."),
    ]
    rows = "".join(
        f'<tr><td data-label="ID"><strong>{i}</strong></td><td data-label="Problem">{n}</td>'
        f'<td data-label="Documented evidence">{e}</td><td data-label="Status">PASS - executed</td></tr>'
        for i, n, e, _ in defs)

    main = f"""
  <div class="wrap page-head">
    <div class="kicker">Research and investigations</div>
    <h1>Four documented industry failures, reproduced on this estate</h1>
    <p class="lede">Each investigation starts with a failure that is documented in the real world, reproduces the
    mechanism in an isolated laboratory, establishes the cause, implements a control and measures the result.
    Every number below was produced by executing the scripts in this repository; a case that only has a diagram
    or an unexecuted script is not counted.</p>
    <div class="badges"><span class="badge">4 investigations</span>
      <span class="badge">{checks}/{checks_total} assertions executed</span>
      <span class="badge">Fault injection before the fix</span></div>
  </div>
  <div class="wrap">
    <section>
      <h2>Method</h2>
      <div class="table-wrap"><table class="data">
        <thead><tr><th>Step</th><th>What is done</th><th>Rule</th></tr></thead>
        <tbody>
          <tr><td data-label="Step">1</td><td data-label="What is done">Read primary sources and grade them</td><td data-label="Rule">A conceptual paper is never used for a number</td></tr>
          <tr><td data-label="Step">2</td><td data-label="What is done">Reproduce the failure with synthetic data</td><td data-label="Rule">The problem is created before the solution</td></tr>
          <tr><td data-label="Step">3</td><td data-label="What is done">Diagnose with queries an engineer would run</td><td data-label="Rule">The injection is found from the data, not from the script</td></tr>
          <tr><td data-label="Step">4</td><td data-label="What is done">Implement the control</td><td data-label="Rule">Constraints and transactions, not conventions</td></tr>
          <tr><td data-label="Step">5</td><td data-label="What is done">Re-run the same scenario and assert</td><td data-label="Rule">A failed assertion fails the run</td></tr>
        </tbody>
      </table></div>
    </section>

    <section>
      <h2>Register</h2>
      <div class="table-wrap"><table class="data">
        <thead><tr><th>ID</th><th>Problem</th><th>Documented evidence</th><th>Status</th></tr></thead>
        <tbody>{rows}</tbody>
      </table></div>
    </section>

    <section>
      <h2>P-01 - Payment integrity and ledger recovery</h2>
      <p><strong>Documented.</strong> A NIBSS Instant Payment fault credited beneficiaries without debiting originators
      between 6 and 9 September 2024: N13.66bn across 176 accounts in 19 institutions, found in settlement review rather
      than by the transaction path. Keystone's February 2025 balance inflation followed the same shape at smaller scale.</p>
      <p><strong>Reproduced.</strong> A processor that commits the debit and the credit separately, has no idempotency
      constraint, writes balances from a stale read and reconciles nothing. Injected failures produce a debit with no
      credit, three debits for one request, and two concurrent transfers spending 16,000 from a 10,000 balance.</p>
      <p><strong>Fixed.</strong> One transaction, a unique idempotency key, a guarded balance update, an in-transaction
      double-entry invariant, an outbox and an exception queue.</p>
      <p class="mono">Executed: {passed(p1)}/{total(p1)} assertions. Baseline reconciliation breaks {p1_base.get('breaks_total', 0)};
      after the fix {p1_fixed.get('breaks_total', 0)}. Replay of one key produces one debit.</p>
      <p><strong>Not claimed:</strong> that this is NIBSS's design or root cause, or that it transfers across services or hosts.
      Full write-up: <a href="case-p01.html">P-01 payment integrity</a>.</p>
    </section>

    <section>
      <h2>P-02 - Oilfield telemetry data quality</h2>
      <p><strong>Documented.</strong> Industrial data quality degrades mainly through missing, late, noisy and
      inconsistent readings; the systematic review found almost no metrics for ordering, traceability or auditability.</p>
      <p><strong>Reproduced.</strong> The existing Modbus simulator is read by a collector that injects dropped samples,
      duplicates, late and out-of-order timestamps, kPa values, spikes, null frames and a conflicting source. Invalid
      readings are quarantined, never interpolated.</p>
      <p><strong>Fixed.</strong> A staging layer with unit normalisation, duplicate detection, plausibility checks,
      quarantine, corrections that preserve originals, and completeness scored from the run's cadence.</p>
      <p class="mono">Executed: {passed(p2)}/{total(p2)} assertions. Staged {p2_col.get('staged', 0)} rows;
      {p2_reasons.get('DUPLICATE', 0)} duplicates and {p2_reasons.get('NULL_VALUE', 0) + p2_reasons.get('OUT_OF_RANGE', 0)}
      invalid readings quarantined; {p2.get('promoted_readings', 0)} promoted; about {p2.get('estimated_missing', 0)} readings
      estimated missing; lowest completeness ratio {min(ratios):.3f}.</p>
      <p><strong>Not claimed:</strong> that any operator had this failure, or that the simplified gap probability is the
      BISE/Prophet method. Full write-up: <a href="case-p02.html">P-02 telemetry quality</a>.</p>
    </section>

    <section>
      <h2>P-03 - Change, failure and recovery</h2>
      <p><strong>Documented.</strong> Clerk's 6 February 2025 outage came from a single manual UPDATE outside staged
      rollout; the ECB's 27 February 2025 outage was first blamed on DB2 and was actually a storage-hardware fault,
      and the 60-minute RTO was missed.</p>
      <p><strong>Reproduced.</strong> On a disposable database, an unbounded UPDATE rewrites 10,000 rows, an unsafe
      NOT NULL migration is rejected, an open transaction blocks a reader, and the damage is recovered by restoring the
      full backup plus log backups to a point before the change.</p>
      <p><strong>Fixed.</strong> A row-count guard that rolls the change back, a nullable/backfill/NOT NULL migration
      path, READ_COMMITTED_SNAPSHOT for reader blocking, and point-in-time recovery with separate database and
      verification timings.</p>
      <p class="mono">Executed: {passed(p3)}/{total(p3)} assertions. Database restore {p3_t.get('database_restore_s', 0)} s;
      reader wait {p3_b.get('before_rcsi', 0)} s before RCSI and {p3_b.get('after_rcsi', 0)} s after. Restored checksum
      matched the baseline exactly.</p>
      <p><strong>Not claimed:</strong> that database restore time equals service recovery, or that the storage fault was
      reproduced in hardware. Full write-up: <a href="case-p03.html">P-03 change and recovery</a>.</p>
    </section>

    <section>
      <h2>P-04 - Privileged access and audit evidence</h2>
      <p><strong>Documented.</strong> Clerk restricted direct database access after its outage; Seplat ranks cyber and
      IT/OT risk first and discloses access-rights control as a mitigation.</p>
      <p><strong>Reproduced.</strong> An application principal holding CONTROL on the lab schema rewrites and deletes
      ledger rows with no in-database evidence of either action.</p>
      <p><strong>Fixed.</strong> CONTROL revoked, direct DML denied, execution through the payment procedure only, and an
      audit trigger that attributes every ledger write to the calling principal.</p>
      <p class="mono">Executed: {passed(p4)}/{total(p4)} assertions. CONTROL grants {p4_base.get('control_grants', 0)} to
      {p4_after.get('control_grants', 0)}; update and delete now denied; {p4_after.get('app_audit_rows', 0)} ledger writes
      attributed to the application.</p>
      <p><strong>Not claimed:</strong> that this replaces SQL Server Audit or a SIEM, or that denied statements are
      captured by the trigger (they never execute). Case study:
      <a href="case-p04.html">P-04 privileged access and audit</a>.</p>
    </section>

    <section>
      <h2>What this does not prove</h2>
      <p>The laboratories run on one SQL Server instance with synthetic data. They show that specific mechanisms produce
      specific failures and that specific controls remove them under repeatable tests. They do not show production scale,
      multi-host behaviour, or any named company's architecture. The research register records each source's credibility,
      including three payment papers that are conceptual and are used for vocabulary only.</p>
    </section>
  </div>
"""

    (SITE / "investigations.html").write_text(
        shell("investigations.html",
              "Research and investigations - Apex Financial Services",
              "Four documented industry failures reproduced in the AFS laboratory: payment integrity, telemetry data quality, change and recovery, privileged access and audit.",
              main),
        encoding="utf-8")
    print("wrote site/investigations.html")


if __name__ == "__main__":
    build_context_page()
    build_capabilities_page()
    build_diagrams_page()
    build_oracle_page()
    build_verification_page()
    build_about_page()
    build_investigations_page()
    restamp_assets()
    print(f"nav updated in {rewrite_navs()} pages")
    print(f"diagram versions refreshed in {refresh_erd_versions()} pages")
