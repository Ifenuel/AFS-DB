# Oracle Backup and Recovery Plan

**Status:** DESIGNED ONLY. No Oracle instance exists.

## Prerequisites

- Database in `ARCHIVELOG` mode.
- Fast Recovery Area configured.
- RMAN catalogue optional; control-file autobackup recommended.
- Test restore to a separate host/database, not over the only lab database.

## Baseline commands (to execute later)

```sql
-- SQL*Plus as SYSDBA
ARCHIVE LOG LIST;
SHOW PARAMETER db_recovery_file_dest;
```

```text
# RMAN
BACKUP DATABASE PLUS ARCHIVELOG;
BACKUP INCREMENTAL LEVEL 1 DATABASE;
LIST BACKUP SUMMARY;
VALIDATE DATABASE;
RESTORE DATABASE PREVIEW;
```

## Recovery exercise outline

1. Record the target time and the last archive log sequence.
2. Back up the database and archive logs.
3. Create a controlled failure in a **separate** test database.
4. Restore the control file/spfile, then `RESTORE DATABASE`, `RECOVER DATABASE` to the target time.
5. `ALTER DATABASE OPEN RESETLOGS` only when appropriate; understand the implication.
6. Run `RMAN> VALIDATE DATABASE` and application reconciliation.
7. Record actual RTO and data loss.

## Limitations

- No Oracle instance, archive logs or RMAN output exists.
- Data Guard/standby requires a second database/host and is design-only.
- Do not run destructive recovery against a live database without approval and a verified backup.
