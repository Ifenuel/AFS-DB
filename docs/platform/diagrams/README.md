# Diagrams

**Published:** <https://afs-dba-portfolio.vercel.app/diagrams> — the same diagrams are on the
portfolio's Diagrams page, rebuilt from the catalog by `automation/python/build_site_pages.py`.

| File | What it is | Source of truth |
|---|---|---|
| `erd.html` | Interactive entity-relationship diagrams, one tab per SQL Server database. Pan, zoom, fit, reset. | Generated from the live catalog |
| `data/AFS_*.json` | The extracted model behind each diagram: tables, columns, keys, relationships | `sys.tables`, `sys.columns`, `sys.foreign_keys` |
| `ARCHITECTURE.md` | Estate and transaction-flow diagrams (Mermaid) | Authored |
| `SSMS_DIAGRAMS.md` | Status of the native SSMS designer feature and how to draw one | Live `sys.objects` check |

## Regenerating

```bash
python automation/python/build_erds.py
```

The script queries each database through `sqlcmd`, writes `data/<database>.json`, and rebuilds
`erd.html` with the metadata embedded, so the page works from the file system with no server
and no network access.

## What the diagrams show

- Tables as cards with their real columns, types and nullability.
- `PK` and `FK` markers on key columns.
- One connector per declared foreign key, ending in IE notation: a bar at the referenced
  ("one") table and a crow's foot at the referencing ("many") table.
- Columns placed by dependency depth, busiest tables first, so parent tables sit to the left of
  the tables that reference them.
- A legend for the markers.

Only declared foreign keys are drawn. `AFS_Audit` has none by design, so its tab shows an
unconnected table layout rather than invented relationships.

## What these are not

They are **not** native SSMS diagrams. SSMS keeps a diagram as a serialized blob that only its
designer writes, so the two cannot be produced by the same mechanism. The native feature is
covered separately in `SSMS_DIAGRAMS.md`; the diagram support objects are installed in all six
databases and no diagram has been saved yet.
