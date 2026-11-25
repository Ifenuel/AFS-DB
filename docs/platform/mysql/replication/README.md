# MySQL Replication Exercise

**Status:** DESIGNED ONLY. No MySQL instance or replica exists.

## Topology

Two local MySQL instances on the same Windows host:

- Source: port 3306, `server_id=1`, binary logging on.
- Replica: port 3307, `server_id=2`, separate data directory.
- Replication user with `REPLICATION SLAVE` only.
- GTID-based replication preferred.

## Steps (planned)

1. Install two MySQL instances or initialize a second data directory with `mysqld --initialize-insecure`.
2. Configure `log_bin`, `server_id`, `gtid_mode=ON`, `enforce_gtid_consistency=ON`.
3. Create the replication user with a locally generated password.
4. Take a consistent backup of the source and restore it to the replica.
5. `CHANGE REPLICATION SOURCE TO SOURCE_HOST='localhost', SOURCE_PORT=3306, SOURCE_AUTO_POSITION=1, ...`
6. `START REPLICA; SHOW REPLICA STATUS\G`
7. Insert a test row on the source and verify it on the replica.
8. Stop the replica, insert more rows, restart and verify catch-up.
9. Test a deliberate conflict/failure and document the error.

## Limitations

- Single host: this is **not** high availability. A host failure takes both instances down.
- No automatic failover/orchestration.
- No production TLS or network segmentation.
- The exercise is a replication learning lab, not a claim of production HA.
