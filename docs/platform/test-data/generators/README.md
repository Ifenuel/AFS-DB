# Generators

The canonical generator lives at [`automation/python/generate_data.py`](../../../../automation/python/generate_data.py). It is intentionally not duplicated here: two copies of a data generator would drift and make the evidence ambiguous.

It produces customers, accounts, transfers, double-entry ledger rows, payments, support cases and audit events as CSV, with a manifest of the achieved volume. See [`../README.md`](../README.md).
