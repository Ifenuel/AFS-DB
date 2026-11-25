from pathlib import Path
import glob

REPL = [
    ("3 engines \u00b7 6 databases \u00b7 41 tables \u00b7 27 foreign keys",
     "3 engines \u00b7 9 databases \u00b7 59 tables \u00b7 43 foreign keys"),
    ("6 databases", "9 databases"),
    ("41 tables", "59 tables"),
    ("27 foreign keys", "43 foreign keys"),
    ("six databases", "nine databases"),
    ("Six databases", "Nine databases"),
]

targets = ["automation/python/build_site_pages.py"] + glob.glob("site/*.html")
for f in targets:
    p = Path(f)
    t = p.read_text(encoding="utf-8")
    before = t
    for a, b in REPL:
        t = t.replace(a, b)
    if t != before:
        p.write_text(t, encoding="utf-8", newline="\n" if f.endswith(".py") else "")
        print("updated", f)

# --- stale dataset sentence and stat note on the home page
idx = Path("site/index.html")
t = idx.read_text(encoding="utf-8")
old = ("The Developer estate carries 500 customers loaded on top of the 62 that arrived in the migration, with\r\n"
       "      5,370 transfers posted through the application's own transfer procedure. Every posted transfer carries its two\r\n"
       "      ledger entries, its transfer event and its audit record.")
new = ("The estate carries 1,000 customers, 1,000 accounts and 20,000 transfers posted through the\n"
       "      application's own transfer procedure. Every posted transfer carries its two ledger entries and its transfer\n"
       "      event, and every account balance reconciles against the ledger.")
assert old in t, "stale sentence not found"
t = t.replace(old, new)
t = t.replace("12,002 migrated + 5,370 posted by the procedure",
              "posted through the procedure \u00b7 40,000 ledger entries")
idx.write_text(t, encoding="utf-8")
print("index copy corrected")

# --- capability matrix: add the three governance disciplines
b = Path("automation/python/build_site_pages.py")
s = b.read_text(encoding="utf-8")

row_anchor = ('      <tr><td data-label="Discipline">High availability and failover</td>')
new_rows = (
    '      <tr><td data-label="Discipline">Access governance</td><td data-label="What was done">Human and '
    'service identities, role grants with approval, quarterly reviews whose revoke decisions actually remove '
    'the grant, and session history per principal</td><td data-label="Measured" class="num">240 grants \u00b7 '
    '4 reviews</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>\n'
    '      <tr><td data-label="Discipline">Compliance control testing</td><td data-label="What was done">24 '
    'obligations across DORA, CBN, PCI DSS, ISO 27001 and NIST CSF mapped to 30 controls, tested with sample '
    'sizes and evidence references; failures become findings and remediation</td><td data-label="Measured" '
    'class="num">60 mappings \u00b7 120 tests</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>\n'
    '      <tr><td data-label="Discipline">Tamper-evident retention</td><td data-label="What was done">Archived '
    'records chained with SHA-256, legal holds that block purges, and a verification query that recomputes the '
    'chain; a single altered hash was detected and then rolled back</td><td data-label="Measured" class="num">'
    '2,000 records \u00b7 0 breaks</td><td data-label="Status"><span class="cap-status ok">Proven</span></td></tr>\n'
)
assert row_anchor in s
s = s.replace(row_anchor, new_rows + row_anchor, 1)

s = s.replace('<span class="badge">25 disciplines</span>', '<span class="badge">28 disciplines</span>', 1)
s = s.replace('<span class="badge">23 proven</span>', '<span class="badge">26 proven</span>', 1)
s = s.replace("Twenty-five disciplines, and the honest status of each",
              "Twenty-eight disciplines, and the honest status of each", 1)
s = s.replace('<strong>41</strong><span class="stat-note">27 foreign keys \u00b7 11 views</span>',
              '<strong>59</strong><span class="stat-note">43 foreign keys \u00b7 11 views</span>', 1)
s = s.replace('<div class="stat"><span class="stat-label">Application tables</span><strong>41</strong>',
              '<div class="stat"><span class="stat-label">Application tables</span><strong>59</strong>', 1)

# --- evidence: add the governance capture
s = s.replace('''     "40,000 ledger entries, and the accounting invariant still holds."),''',
'''     "40,000 ledger entries, and the accounting invariant still holds."),
    ("56_governance_databases", "Identity, control testing and retention are queryable",
     "Three further databases model what most estates keep in spreadsheets: who holds which grant and when it "
     "was reviewed, which control answers which obligation and when it last failed, and which records are "
     "retained under hold.",
     "240 grants and 4 reviews reconcile, 120 control tests produce findings with remediation, and the archive "
     "hash chain shows zero breaks until one row is deliberately altered \\u2014 which the check catches."),''', 1)
s = s.replace('<span class="badge">7 captures shown</span>', '<span class="badge">8 captures shown</span>', 1)
b.write_text(s, encoding="utf-8", newline="\n")
print("matrix and evidence updated")
