# Change Requests — AFS-DBA-001

Every schema, index, procedure, permission or instance-configuration change must have a change record before implementation. The record is not a substitute for testing; it documents why, risk, scope, validation and rollback.

## Required fields

Change ID, title, date, requester, owner, reason, risk, scope, impact, pre-checks, implementation, testing, validation, rollback, evidence, status.

## Status vocabulary

- **DRAFT** — not approved.
- **APPROVED** — reviewed, not applied.
- **IMPLEMENTED** — applied, validation pending.
- **VERIFIED** — applied and validated with evidence.
- **FAILED** — did not apply or validation failed; rollback state recorded.
- **ROLLED BACK** — reverted and verified.

## Register

| ID | Change | Status |
|---|---|---|
| CR-001 | Add `Payment.BeneficiaryAccountId` for internal payment target | AUTHORED, NOT APPLIED |
| CR-002 | Add transfer currency/date covering index | AUTHORED, NOT APPLIED |
| CR-003 | Add idempotent transfer/payment procedures | AUTHORED, NOT APPLIED |
| CR-004 | Grant application execute permissions on payment procedures | AUTHORED, NOT APPLIED |
| CR-005 | Enable read-committed snapshot isolation | AUTHORED, NOT APPLIED |
| CR-006 | Install SQL Server 2025 Developer | **FAILED AT PRECHECK** (admin rights) |

No database change in this register is claimed as implemented until the deployment tests run.
