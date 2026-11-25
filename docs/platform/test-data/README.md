# Synthetic Test Data

All data in this project is synthetic. Do not put real customer, account, payment or personal data here.

- Generator: [`automation/python/generate_data.py`](../../../automation/python/generate_data.py)
- Generated output: `test-data/generated/` — **ignored by Git** because it is large, reproducible and not source.
- Manifests: a generated run writes `manifest.json` with the actual counts and file sizes.
- Seed/reference values: `sql-server/tables/04_seed_reference.sql` (not customer data).
- Volume and reconciliation notes: [`reports/capacity/CAPACITY_REPORT.md`](../../reports/capacity/CAPACITY_REPORT.md).

```powershell
python automation/python/generate_data.py --profile smoke --output test-data/generated/smoke --force
```

The smoke profile is a verification dataset, not the target volume. A target-profile run is subject to the free-space guard and is not claimed until it has actually completed.
