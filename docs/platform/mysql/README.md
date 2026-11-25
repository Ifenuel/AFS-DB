# MySQL DBA Laboratory

**Status:** BLOCKED — MySQL Community Server is not installed. The Windows service installation requires administrator rights, and the current account is a standard user. This directory contains reviewed SQL exercises and procedures, not executed results.

## 1. Planned platform

- MySQL Community Server 8.4 LTS (8.4.9 was current in the winget catalogue at assessment).
- Windows x64 MSI/MySQL Installer, **Server only** or Custom with Shell/Workbench.
- Service `MySQL84`, TCP 3306 (confirmed free).
- Development Computer configuration.
- `innodb_buffer_pool_size` 1–2 GB; do not run concurrent SQL Server benchmarks.
- Binary logging enabled for point-in-time recovery exercises.

Official references:

- <https://dev.mysql.com/doc/refman/8.4/en/windows-installation.html>
- <https://dev.mysql.com/doc/mysql-installer/en/mysql-installer.html>

## 2. Installation verification (planned)

```powershell
Get-Service MySQL84
mysql --version
mysql -u root -p -e "SELECT VERSION(), @@port, @@log_bin, @@innodb_buffer_pool_size;"
```

Record the actual output in `evidence/mysql/`; do not commit the root password.

## 3. Exercises

| Exercise | File | Status |
|---|---|---|
| Users, roles, least privilege | `security/01_users_and_grants.sql` | Authored, not executed |
| Core schema and transaction test | `tests/01_smoke.sql` | Authored, not executed |
| Backup and point-in-time recovery plan | `backup/README.md` | Authored, not executed |
| Index/EXPLAIN investigation | `performance/01_explain.sql` | Authored, not executed |
| Single-primary replication plan | `replication/README.md` | Designed only |

## 4. Concepts to demonstrate

- `CREATE USER` / `CREATE ROLE` / `GRANT` / `REVOKE`; `caching_sha2_password`.
- InnoDB transactions, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, isolation levels.
- `EXPLAIN` / `EXPLAIN ANALYZE`, index selectivity, covering indexes.
- `mysqldump --single-transaction --routines --triggers --events`, binary logs, `mysqlbinlog`.
- Replication: `CHANGE REPLICATION SOURCE TO`, `START REPLICA`, `SHOW REPLICA STATUS`, GTID.
- `performance_schema`, `SHOW ENGINE INNODB STATUS`, slow query log.
- Differences from SQL Server: no `GO`, delimiter for routines, `AUTO_INCREMENT`, storage engines, clustered primary key, no SQL Server Agent (Event Scheduler/cron), different backup tooling.

## 5. Honest limitations

- No MySQL service exists yet; none of these scripts has run.
- MySQL licensing/edition is Community, not Enterprise.
- A second local instance for replication has not been created.
- No production connectivity, TLS or backup encryption is claimed.
