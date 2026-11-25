# Incident Register — AFS-DBA-001

Each incident report follows the same professional structure: identification, severity, environment, detection, impact, symptoms, timeline, investigation, commands/queries, root cause, resolution, verification, prevention, lessons, evidence and closure status.

## Status labels

- **EXECUTED / OBSERVED** — the event or a safe reproduction actually happened on this machine; command output exists.
- **DESIGNED ONLY** — the scenario is prepared with commands and expected evidence, but has not been reproduced because the database engine is not installed or the action would be unsafe without approval.
- **SIMULATED** — a controlled representation of a production condition, clearly not the real topology.

## Required incidents

| ID | Incident | Status |
|---|---|---|
| INC-001 | Installation blocked by missing administrator rights | **OBSERVED** |
| INC-002 | Deployment attempt fails because `sqlcmd`/engine is unavailable | **OBSERVED** |
| INC-003 | Backup failure | DESIGNED ONLY |
| INC-004 | Accidental data deletion | DESIGNED ONLY |
| INC-005 | Disk space shortage | DESIGNED ONLY |
| INC-006 | Slow query | DESIGNED ONLY |
| INC-007 | Unauthorized access attempt | DESIGNED ONLY |
| INC-008 | Blocking | DESIGNED ONLY |
| INC-009 | Deadlock | DESIGNED ONLY |
| INC-010 | Database/service outage | DESIGNED ONLY |
| INC-011 | Invalid backup / recovery failure | DESIGNED ONLY |

The required set of ten is covered; INC-001 and INC-002 are real observations from the current build. The rest are explicitly not claimed as executed.

## Evidence rules

- Do not paste passwords or connection strings.
- Include timestamps in UTC.
- Include the exact command or query and the observed result.
- If a step was not executed, write **not executed** rather than an imagined output.
- Link evidence files under `evidence/` and update the tracker.
