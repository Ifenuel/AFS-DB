# MySQL Backup and Recovery Plan

**Status:** Authored only; MySQL is not installed.

## 1. Baseline

- `mysqldump --single-transaction --routines --triggers --events --set-gtid-purged=ON afs_lab > afs_lab_full.sql`
- Enable binary logging (`log_bin=ON`, unique `server_id`) for point-in-time recovery.
- Store dumps outside the data directory, with restricted ACLs.
- Verify a dump by restoring into `afs_lab_restore`.

## 2. Point-in-time outline

1. Take a consistent full dump (or a physical backup with Percona XtraBackup if installed).
2. Record the binary log position/GTID at backup time.
3. Restore the full dump.
4. Replay binary logs up to the target time with `mysqlbinlog --stop-datetime`.
5. Run `CHECK TABLE` and reconciliation queries.
6. Measure RTO and record the data-loss window.

## 3. Verification

A dump is not valid merely because `mysqldump` exited 0. Restore it, compare row counts/checksums, and run application-level reconciliation.

## 4. Security

Do not put passwords on the command line in a shared shell. Use a protected option file (outside Git) or a secret manager. Do not commit dumps; they contain synthetic data in this lab but would contain sensitive data in production.

## 5. Gap

No MySQL instance or backup has been run, so no RTO/RPO evidence exists. The SQL Server lab is the primary backup/recovery demonstration for this portfolio.
