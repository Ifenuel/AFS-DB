# Oracle laboratory evidence

Captured 2026-11-24 on the local laptop against the installed instance. Each file is raw
SQL*Plus output, transferred without editing except for stripping the connection line.

| File | Command | What it shows |
|---|---|---|
| `01_environment.txt` | `sqlplus sys/…@//127.0.0.1:1521/freepdb1 as sysdba @00_environment.sql` | Version banner, `FREE` in `READ WRITE`, `FREEPDB1` open, `AFS_LAB` status and its five system privileges, two rows in each lab table |
| `02_create_lab_user.txt` | same connection, `@oracle/security/01_create_lab_user.sql` | The authored least-privilege script executed: user created, five grants, no roles |
| `03_smoke_test.txt` | `sqlplus afs_lab/…@//127.0.0.1:1521/freepdb1 @oracle/tests/01_smoke.sql` | Tables created, two accounts inserted, transfer committed, balances 900 and 600 with ledger −100 and +100 |
| `04_explain_plan.txt` | `sqlplus afs_lab/…@//127.0.0.1:1521/freepdb1 @oracle/performance/01_explain.sql` | `DBMS_XPLAN` for the currency/balance query: `TABLE ACCESS FULL` on `ACCOUNT`, cost 3, dynamic sampling level 2 |
| `05_listener.txt` | `lsnrctl status` | `FREE`, `FREEPDB1` and `FREEXDB` registered `READY` on port 1521 |

Connection identifiers used: `sys/…@//127.0.0.1:1521/freepdb1.false as sysdba` for
administration and `afs_lab/…@//127.0.0.1:1521/freepdb1` for the exercises. The listener on
this host appends the `.FALSE` domain to service names; `FREEPDB1` alone returns ORA-12514.

No password appears in any file here. Local credentials stay in
`C:\oracle\admin\oracle-lab-credentials.txt`, outside the repository.

## What these files do not show

- No AWR/ASH report, no index comparison run: `01_explain.sql` records the baseline plan only.
- No Data Guard, RAC or multi-host work; this is a single laptop instance.

## Backup and recovery (added 2026-11-24/25)

These five files are the original read-only inventory. The later recovery work — ARCHIVELOG,
RMAN, a simulated delete and a pluggable-database point-in-time recovery — is in
`evidence/verify/live/20`–`30`, with the change record in
`docs/change/ORCL-CHG-001_archivelog_rman.md` §11:

| File | What it shows |
|---|---|
| `live/22_oracle_archivelog.txt` | `LOG_MODE=ARCHIVELOG` from 2026-11-24 22:07:07 |
| `live/23_oracle_archive_verify.txt` | archived logs 1–5 on disk, destination 1 `VALID` |
| `live/24_rman_config.txt` | retention 2 days, controlfile autobackup ON, compressed backupsets |
| `live/25_rman_backup.txt` | `BACKUP DATABASE PLUS ARCHIVELOG` + `VALIDATE DATABASE`, zero RMAN/ORA errors |
| `live/26`–`27` | marker row inserted 22:12:24, archived, deleted 22:12:43 |
| `live/29`–`30` | PDB PITR to 22:12:35: marker row present exactly once after recovery |

Still not shown: a scheduled backup job, FRA growth alarms, host-loss recovery.
