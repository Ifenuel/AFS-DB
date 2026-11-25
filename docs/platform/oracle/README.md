# Oracle DBA Laboratory

**Status:** INSTALLED AND EXERCISED — Oracle AI Database 26ai Free 23.26.4 runs locally as
`FREE` / `FREEPDB1` on port 1521. The security, transaction and execution-plan scripts below
were executed against it on 2026-11-24; raw output is in `evidence/oracle/`. The installation
record, including the account-name workaround this machine needed, is in
`oracle/installation/README.md`.

## 1. Platform decision

- Preferred: **Oracle AI Database Free 26ai for Windows x64** (free edition), `FREEPDB1` pluggable database, TCP 1521.
- Official requirements at assessment: Windows 11 x64 Pro/Enterprise/Education; 8.5 GB software plus 2 GB temporary; 2 GB RAM minimum; administrator installation.
- The laptop has enough RAM/disk for a lab, but three engines should not run simultaneously.
- Docker was not selected because virtualization is unconfirmed and Docker/WSL are absent.
- Installed home: `C:\app\oraclelab\product\26ai\dbhomeFree`; services `OracleServiceFREE`
  and `OracleOraDB23Home1TNSListener` run under virtual service accounts.

References:

- <https://docs.oracle.com/en/database/oracle/oracle-database/26/xeinw/requirements.html>
- <https://docs.oracle.com/en/database/oracle/oracle-database/26/xeinl/installing-oracle-database-free.html>

## 2. Connection details

```
sqlplus sys/<sys password>@//127.0.0.1:1521/freepdb1 as sysdba
sqlplus afs_lab/<lab password>@//127.0.0.1:1521/freepdb1
```

The listener on this host registers services with a `.FALSE` domain suffix; if
`FREEPDB1` alone returns ORA-12514, use `freepdb1.false`. Local passwords are kept in
`C:\oracle\admin\oracle-lab-credentials.txt`, outside the repository.

Oracle Live SQL was kept only as the fallback plan and is no longer needed; nothing here
was produced there.

## 3. Planned exercises

| Area | Exercise | File | Status |
|---|---|---|---|
| Users/roles/quotas | Create a least-privilege lab user | `security/01_create_lab_user.sql` | Executed — `evidence/oracle/02_create_lab_user.txt` |
| SQL/transactions | Create table, insert, commit, rollback | `tests/01_smoke.sql` | Executed — `evidence/oracle/03_smoke_test.txt` |
| Backup/recovery | RMAN full + archive log restore outline | `backup/README.md` | Designed only — database is `NOARCHIVELOG` |
| Performance | Explain plan and index investigation | `performance/01_explain.sql` | Baseline executed — `evidence/oracle/04_explain_plan.txt` |

## 4. Oracle concepts to demonstrate

- Instance vs database; CDB/PDB (`FREEPDB1`).
- Tablespaces, datafiles, segments, extents, blocks.
- Users, roles, system vs object privileges, quotas, profiles.
- `V$` dynamic performance views, `DBA_*` dictionary views.
- `EXPLAIN PLAN`, `DBMS_XPLAN`, indexes, statistics.
- `ARCHIVELOG` mode, RMAN backup, restore/recover, point-in-time.
- Alert log, trace files, listener (`lsnrctl`), `tnsping`, `sqlplus`.
- Differences from SQL Server: no `GO`, PL/SQL blocks, sequences/triggers, undo vs transaction log, RMAN vs BACKUP/RESTORE, CDB/PDB architecture.

## 5. Honest limitations

- Produced so far: `sqlplus` sessions, a least-privilege user, two tables, a committed
transfer, and one `DBMS_XPLAN` baseline. No RMAN backup, no restore, no AWR/ASH report.
- The database runs `NOARCHIVELOG`, so recovery exercises need a mode change and a bounce
first; that change has not been made.
- `AFS_LAB` holds five system privileges and no roles. It is a demonstration of least
privilege, not a hardened production account model.
- Oracle Free is not a production licence and has CPU, memory and 12 GB data limits.
- The local lab cannot demonstrate Data Guard, RAC or multi-host RMAN without a second
host.
