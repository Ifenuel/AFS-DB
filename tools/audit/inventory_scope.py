"""One definition of what counts as a published estate object.

The laboratory fixtures created for the investigations live in the same
databases as the portfolio objects. They must not appear in the published
inventory, the explorer or the diagrams. Keeping that rule here means the SQL
inventory query and the Python explorer cannot drift apart.

The SQL side uses placeholders of the form ``{{LAB_FILTER:schema_alias.object_alias}}``
which ``build_inventory.py`` expands with :func:`sql_filter`.
"""
from __future__ import annotations

LAB_SCHEMA = "paylab"

TELEMETRY_TABLES = ("Staging", "Quarantine", "Correction", "CompletenessScore")
TELEMETRY_VIEWS = ("vw_EffectiveReading",)
TELEMETRY_PROCEDURES = (
    "usp_ValidateStaging",
    "usp_ScoreCompleteness",
    "usp_CorrectReading",
    "usp_ResetQualityRun",
)

_BY_KIND = {
    "tables": TELEMETRY_TABLES,
    "views": TELEMETRY_VIEWS,
    "procedures": TELEMETRY_PROCEDURES,
}

ALL_OBJECTS = frozenset(TELEMETRY_TABLES + TELEMETRY_VIEWS + TELEMETRY_PROCEDURES)


def sql_filter(schema_alias: str, object_alias: str, kind: str = "tables",
               quote: str = "'") -> str:
    """Return a T-SQL predicate excluding the laboratory fixtures.

    ``quote`` is ``''`` when the predicate is injected into a dynamic-SQL
    string literal, where a single quote has to be doubled.
    """
    if kind not in _BY_KIND:
        raise ValueError(f"unknown object kind: {kind}")
    q = quote
    names = ", ".join(f"N{q}{name}{q}" for name in _BY_KIND[kind])
    return (
        f"{schema_alias}.name <> N{q}{LAB_SCHEMA}{q} "
        f"AND NOT ({schema_alias}.name = N{q}telemetry{q} AND {object_alias}.name IN ({names}))"
    )


def expand_sql(text: str, quote: str = "'") -> str:
    """Replace every ``{{LAB_FILTER:a.b.kind}}`` placeholder in a script."""
    import re

    return re.sub(
        r"\{\{LAB_FILTER:([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\.(tables|views|procedures)\}\}",
        lambda m: sql_filter(m.group(1), m.group(2), m.group(3), quote),
        text,
    )


def is_excluded(schema: str, name: str) -> bool:
    """True when an object must stay out of the published inventory."""
    if schema == LAB_SCHEMA:
        return True
    return schema == "telemetry" and name in ALL_OBJECTS
