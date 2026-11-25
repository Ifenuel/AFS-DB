# Documentation index — AFS-DBA-001

Every Markdown file in this project lives under `docs/`. The repository root holds one short `README.md` that points here.

Start with the four in order: **OVERVIEW → START-HERE → HANDOVER → PROJECT_TRACKER**.

---

## 1. Read these first

| Document | What it answers |
|---|---|
| [AIM.md](AIM.md) | **Why the project exists:** the 2026 Nigerian fintech and upstream data problems, each with a source, mapped to what this lab proves and what it does not |
| [OVERVIEW.md](OVERVIEW.md) | What the project is, current status per phase, honesty statement |
| [START-HERE.md](START-HERE.md) | Exact folders, commands and expected results on this computer |
| [HANDOVER.md](HANDOVER.md) | Where the work stands today, what is verified, what is blocked |
| [PROJECT_TRACKER.md](PROJECT_TRACKER.md) | Dated execution log, task IDs, blockers |
| [PROJECT_CHARTER.md](PROJECT_CHARTER.md) | Scope, constraints, success criteria |
| [REQUIREMENTS.md](REQUIREMENTS.md) | Numbered functional and non-functional requirements |
| [USER_HANDS_ON_TESTS.md](USER_HANDS_ON_TESTS.md) | Copy-paste checks a reviewer can run |
| [REPORT_VERIFICATION_2026-11-24.md](REPORT_VERIFICATION_2026-11-24.md) | **The verification report:** all six conditions answered with evidence |
| [AFS_MASTER_PRIVATE_GUIDE.md](AFS_MASTER_PRIVATE_GUIDE.md) | **Private.** Full technical guide: navigation, schema, demo script, interview answers |

## 2. Environment and installation

| Document | Contents |
|---|---|
| [environment/ENVIRONMENT_ASSESSMENT.md](environment/ENVIRONMENT_ASSESSMENT.md) | Original host assessment |
| [environment/AUDIT_2026-11-24.md](environment/AUDIT_2026-11-24.md) | 2026-11-24 audit pass |
| [environment/INVENTORY_2026-11-24_V2.md](environment/INVENTORY_2026-11-24_V2.md) | Verified inventory V2 (both SQL Server instances, Oracle) |
| [installation/INSTALLATION_PLAN.md](installation/INSTALLATION_PLAN.md) | Install order and prerequisites |
| [installation/SOFTWARE_INVENTORY.md](installation/SOFTWARE_INVENTORY.md) | Installed versions, what is absent |

## 3. Architecture and data model

| Document | Contents |
|---|---|
| [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) | Layers, boundaries, component map |
| [architecture/DATABASE_INVENTORY.md](architecture/DATABASE_INVENTORY.md) | Six databases, objects, sizes |
| [architecture/DATA_MODEL.md](architecture/DATA_MODEL.md) | Entities, keys, relationships |
| [data-dictionary/DATA_DICTIONARY.md](data-dictionary/DATA_DICTIONARY.md) | Column-level dictionary |
| [platform/diagrams/ARCHITECTURE.md](platform/diagrams/ARCHITECTURE.md) | Diagram-specific notes |
| [platform/diagrams/SSMS_DIAGRAMS.md](platform/diagrams/SSMS_DIAGRAMS.md) | SSMS diagram status (manual GUI step) |
| [platform/diagrams/README.md](platform/diagrams/README.md) | ERD generator usage |

## 4. Security

| Document | Contents |
|---|---|
| [security/SECURITY_MODEL.md](security/SECURITY_MODEL.md) | Roles, users, grants and denials |
| [standards/SECURITY_BASELINE.md](standards/SECURITY_BASELINE.md) | Baseline controls |
| [standards/NAMING_STANDARDS.md](standards/NAMING_STANDARDS.md) | Naming conventions |

## 5. Backup, recovery, DR

| Document | Contents |
|---|---|
| [backup-recovery/BACKUP_STRATEGY.md](backup-recovery/BACKUP_STRATEGY.md) | Schedules, retention, compression, verification |
| [backup-recovery/RECOVERY_RUNBOOK.md](backup-recovery/RECOVERY_RUNBOOK.md) | Step-by-step restores, PITR, failure branches |
| [backup-recovery/RECOVERY_CLAIMS.md](backup-recovery/RECOVERY_CLAIMS.md) | **Repair claims:** schedule vs actual recovery point vs tested result vs RPO/RTO target, per engine |
| [disaster-recovery/HA_DR_DESIGN.md](disaster-recovery/HA_DR_DESIGN.md) | HA/DR design; what is designed vs executed |
| [change/ORCL-CHG-001_archivelog_rman.md](change/ORCL-CHG-001_archivelog_rman.md) | **EXECUTED 2026-11-24/25** Oracle ARCHIVELOG, RMAN baseline and PDB point-in-time recovery |
| [reports/recovery/RECOVERY_REPORT.md](reports/recovery/RECOVERY_REPORT.md) | Recovery test results |

## 6. Operations and performance

| Document | Contents |
|---|---|
| [monitoring/MONITORING_GUIDE.md](monitoring/MONITORING_GUIDE.md) | Health checks, alert thresholds |
| [performance/PERFORMANCE_LAB.md](performance/PERFORMANCE_LAB.md) | Query lab: before/after plans, reads, limitations |
| [reports/performance/PERFORMANCE_REPORT.md](reports/performance/PERFORMANCE_REPORT.md) | Performance findings |
| [reports/capacity/CAPACITY_REPORT.md](reports/capacity/CAPACITY_REPORT.md) | Growth and sizing |
| [reports/security/SECURITY_REPORT.md](reports/security/SECURITY_REPORT.md) | Security test results |

## 7. Verification, testing, evidence

| Document | Contents |
|---|---|
| [docs/evidence/EVIDENCE_INDEX.md](evidence/EVIDENCE_INDEX.md) | Evidence catalogue, including EV-100…EV-110 |
| [docs/evidence/verify/2026-11-24/FINDINGS.md](evidence/verify/2026-11-24/FINDINGS.md) | Authoritative findings for the latest read-only pass |
| [testing/TEST_REPORT_2026-11-24.md](testing/TEST_REPORT_2026-11-24.md) | Every test with PASS / FAIL / BLOCKED / NOT TESTED |
| [audit/PUBLIC_CLAIM_AUDIT.md](audit/PUBLIC_CLAIM_AUDIT.md) | Each public claim traced to evidence |
| [research/RESEARCH_REGISTER.md](research/RESEARCH_REGISTER.md) | Research questions, sources, conclusions |
| [evidence/execution/20261120T181900Z_execution_summary.md](evidence/execution/20261120T181900Z_execution_summary.md) | 2026-11-20 execution summary |
| [evidence/oracle/README.md](evidence/oracle/README.md) | Oracle evidence notes |

## 8. Incidents and change requests

| Document | Contents |
|---|---|
| [incidents/README.md](incidents/README.md) | Incident index (INC-001 … INC-011) |
| [incidents/INC-004_ACCIDENTAL_DELETION.md](incidents/INC-004_ACCIDENTAL_DELETION.md) | Deletion + PITR drill (also the performance case) |
| [incidents/INC-008_BLOCKING.md](incidents/INC-008_BLOCKING.md) | Blocking chain |
| [incidents/INC-009_DEADLOCK.md](incidents/INC-009_DEADLOCK.md) | Deadlock graph and fix |
| [change-requests/README.md](change-requests/README.md) | Change request index (CR-001 … CR-006) |

## 9. Platform labs (Oracle, MySQL, test data, tests)

| Document | Contents |
|---|---|
| [platform/oracle/README.md](platform/oracle/README.md) | Oracle 26ai Free lab status |
| [platform/oracle/installation/README.md](platform/oracle/installation/README.md) | Install record |
| [platform/oracle/backup/README.md](platform/oracle/backup/README.md) | Oracle backup status (RMAN not executed) |
| [platform/mysql/README.md](platform/mysql/README.md) | MySQL exercises (server not installed) |
| [platform/mysql/backup/README.md](platform/mysql/backup/README.md) | MySQL backup notes |
| [platform/mysql/replication/README.md](platform/mysql/replication/README.md) | Replication notes |
| [platform/test-data/README.md](platform/test-data/README.md) | Synthetic data sets and manifests |
| [platform/test-data/generators/README.md](platform/test-data/generators/README.md) | Generator usage |
| [platform/tests/README.md](platform/tests/README.md) | Test suite layout |

## 10. Interview preparation

| Document | Contents |
|---|---|
| [interview/CURRICULUM.md](interview/CURRICULUM.md) | Study plan mapped to the lab |
| [interview/DEMO_SCRIPT.md](interview/DEMO_SCRIPT.md) | 10-minute live demonstration |
| [interview/QUESTION_BANK.md](interview/QUESTION_BANK.md) | Questions with grounded answers |

## 11. Status

| Document | Contents |
|---|---|
| [reports/FINAL_STATUS.md](reports/FINAL_STATUS.md) | Phase-by-phase final status |
| [reports/README.md](reports/README.md) | Report index |

---

## Rules for this folder

1. Every number here traces to a file in `../evidence/`. If it does not, it says "not measured".
2. Raw evidence stays at its original path (`evidence/`, `sql-server/`, `site/`). Only Markdown lives in `docs/`.
3. `python automation/python/validate_repo.py` must pass after any edit; it checks every relative link in this folder.
4. `AFS_MASTER_PRIVATE_GUIDE.md` is private — it must never be copied into `site/`.
