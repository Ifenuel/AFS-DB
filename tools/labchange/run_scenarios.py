#!/usr/bin/env python3
"""P-03 change, failure and recovery driver.

Runs against the disposable database AFS_Lab_Change only:
  bad mass update -> detection -> point-in-time restore
  guarded update (same intent, row-count assertion)
  unsafe migration (rejected) -> safe migration
  blocking before and after READ_COMMITTED_SNAPSHOT

Drops the lab database at the end. Writes evidence/research/P-03/.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "evidence" / "research" / "P-03"
SQLCMD = (
    os.environ.get("SQLCMD")
    or r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"
    or shutil.which("sqlcmd")
)
BACKUP_DIR = r"C:\ProgramData\AFS\backups\labchange"
FULL_BAK = rf"{BACKUP_DIR}\labchange_full.bak"
LOG1_BAK = rf"{BACKUP_DIR}\labchange_log1.trn"
LOG2_BAK = rf"{BACKUP_DIR}\labchange_tail.trn"
ASSERTIONS: list[dict] = []


def sqlcmd(sql: str, db: str = "master", timeout: int = 180) -> tuple[int, str, str]:
    fd, name = tempfile.mkstemp(suffix=".sql", text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(sql)
    try:
        proc = subprocess.run(
            [SQLCMD, "-E", "-C", "-S", ".", "-d", db, "-b", "-I",
             "-h", "-1", "-W", "-s", "|", "-f", "65001", "-i", name],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    finally:
        os.unlink(name)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def rows(sql: str, db: str = "master") -> list[list[str]]:
    rc, out, err = sqlcmd(sql, db)
    if rc != 0:
        raise RuntimeError(err or out)
    return [line.split("|") for line in out.splitlines() if line.strip()]


def scalar(sql: str, db: str = "master", default: str = "") -> str:
    r = rows(sql, db)
    return r[0][0] if r else default


def apply_file(rel: str, db: str = "master") -> tuple[int, str]:
    rc, out, err = sqlcmd((ROOT / rel).read_text(encoding="utf-8"), db)
    return rc, (err or out)


def check(aid: str, description: str, expected, actual) -> None:
    passed = str(expected) == str(actual)
    ASSERTIONS.append({"id": aid, "description": description,
                       "expected": expected, "actual": actual, "passed": passed})
    print(f"  {'PASS' if passed else 'FAIL'}  {aid}  {description} (expected {expected}, got {actual})")


def state() -> dict:
    r = rows("SET NOCOUNT ON; SELECT COUNT(*), SUM(Balance), CHECKSUM_AGG(BINARY_CHECKSUM(AccountId, Balance, Tier)) "
             "FROM lab.Account;", "AFS_Lab_Change")[0]
    return {"rows": int(r[0]), "total": r[1], "checksum": r[2]}


def start(sql: str, db: str = "AFS_Lab_Change") -> subprocess.Popen:
    fd, name = tempfile.mkstemp(suffix=".sql", text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(sql)
    proc = subprocess.Popen(
        [SQLCMD, "-E", "-C", "-S", ".", "-d", db, "-b", "-I", "-h", "-1", "-W", "-f", "65001", "-i", name],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    proc._path = name  # type: ignore[attr-defined]
    return proc


def finish(proc: subprocess.Popen) -> tuple[int, str]:
    out, err = proc.communicate(timeout=120)
    path = getattr(proc, "_path", None)
    if path:
        os.unlink(path)
    return proc.returncode, (out.strip() or err.strip())


def main() -> int:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    timings: dict[str, float] = {}

    print("== setup: create and seed AFS_Lab_Change ==")
    rc, msg = apply_file("sql-server/labchange/00_setup.sql")
    if rc != 0:
        raise SystemExit(msg)
    rc, msg = apply_file("sql-server/labchange/10_scenarios.sql", "AFS_Lab_Change")
    if rc != 0:
        raise SystemExit(msg)

    base = state()
    print(f"  baseline rows={base['rows']} total={base['total']} checksum={base['checksum']}")
    check("C1", "baseline row count", "10000", base["rows"])

    sqlcmd(f"EXEC master.dbo.xp_create_subdir N'{BACKUP_DIR}';")

    print("== backup chain ==")
    rc, out, err = sqlcmd(f"BACKUP DATABASE AFS_Lab_Change TO DISK=N'{FULL_BAK}' WITH INIT, COMPRESSION, CHECKSUM;")
    if rc != 0:
        raise SystemExit(err)
    rc, out, err = sqlcmd(f"BACKUP LOG AFS_Lab_Change TO DISK=N'{LOG1_BAK}' WITH INIT, COMPRESSION;")
    if rc != 0:
        raise SystemExit(err)

    print("== bad update (Clerk-style unbounded UPDATE) ==")
    before = scalar("SELECT CONVERT(varchar(23), SYSUTCDATETIME(), 126);")
    rc, out, err = sqlcmd("EXEC lab.usp_BadMassUpdate @Multiplier = 1.10;", "AFS_Lab_Change")
    if rc != 0:
        raise SystemExit(err)
    after_bad = state()
    drift = rows(f"EXEC lab.usp_DetectDrift @ExpectedRows=10000, @ExpectedTotal={base['total']}, "
                 f"@ExpectedChecksum={base['checksum']};", "AFS_Lab_Change")[0]
    changed = scalar("SELECT TOP 1 RowsAffected FROM lab.ChangeLog ORDER BY ChangeId DESC;", "AFS_Lab_Change")
    print(f"  changed rows={changed} verdict={drift[3]} total={after_bad['total']}")
    check("C2", "unbounded update rewrote every row", "10000", changed)
    check("C3", "detection reports the balance drift", "BALANCE_DRIFT", drift[3])

    print("== tail-log backup and point-in-time restore ==")
    rc, out, err = sqlcmd(f"BACKUP LOG AFS_Lab_Change TO DISK=N'{LOG2_BAK}' WITH INIT, COMPRESSION;")
    if rc != 0:
        raise SystemExit(err)

    t0 = time.perf_counter()
    rc, out, err = sqlcmd(f"""
RESTORE DATABASE AFS_Lab_Change FROM DISK=N'{FULL_BAK}' WITH REPLACE, NORECOVERY;
RESTORE LOG AFS_Lab_Change FROM DISK=N'{LOG1_BAK}' WITH NORECOVERY;
RESTORE LOG AFS_Lab_Change FROM DISK=N'{LOG2_BAK}' WITH STOPAT='{before}', RECOVERY;
""")
    timings["database_restore_s"] = round(time.perf_counter() - t0, 2)
    if rc != 0:
        raise SystemExit(err)

    restored = state()
    service_t0 = time.perf_counter()
    verify = rows(f"EXEC lab.usp_DetectDrift @ExpectedRows=10000, @ExpectedTotal={base['total']}, "
                  f"@ExpectedChecksum={base['checksum']};", "AFS_Lab_Change")[0]
    timings["service_verified_s"] = round(time.perf_counter() - service_t0, 2)
    print(f"  restore={timings['database_restore_s']}s verify={verify[3]} rows={restored['rows']}")
    check("C4", "restore returns the pre-update state", "OK", verify[3])
    check("C5", "row count after restore", "10000", restored["rows"])
    check("C6", "total balance after restore", base["total"], restored["total"])
    check("C7", "checksum after restore", base["checksum"], restored["checksum"])

    print("== guarded update ==")
    rc, out, err = sqlcmd("EXEC lab.usp_GuardedUpdate @Multiplier = 1.10, @ExpectedRows = 1;", "AFS_Lab_Change")
    guarded = state()
    print(f"  rc={rc} msg={(err or out).splitlines()[-1] if (err or out) else ''}")
    check("C8", "guarded update rejected by row-count assertion", "yes", "yes" if rc != 0 else "no")
    check("C9", "guarded update changed nothing", base["checksum"], guarded["checksum"])

    print("== migrations ==")
    rc, out, err = sqlcmd("EXEC lab.usp_UnsafeMigration;", "AFS_Lab_Change")
    check("C10", "unsafe NOT NULL migration rejected", "yes", "yes" if rc != 0 else "no")
    rc, out, err = sqlcmd("EXEC lab.usp_SafeMigration;", "AFS_Lab_Change")
    nonnull = scalar("SELECT COUNT(*) FROM lab.Account WHERE RiskScore IS NOT NULL;", "AFS_Lab_Change")
    check("C11", "safe migration applied", "0", rc)
    check("C12", "backfilled column is populated", "10000", nonnull)

    print("== blocking before READ_COMMITTED_SNAPSHOT ==")
    writer = start("BEGIN TRAN; UPDATE lab.Account SET Balance = Balance WHERE AccountId = 1; "
                   "WAITFOR DELAY '00:00:06'; ROLLBACK;")
    time.sleep(1.0)
    t0 = time.perf_counter()
    rc, out, err = sqlcmd("SET NOCOUNT ON; SELECT Balance FROM lab.Account WHERE AccountId = 1;", "AFS_Lab_Change")
    before_wait = time.perf_counter() - t0
    finish(writer)
    print(f"  reader waited {before_wait:.2f}s")
    check("C13", "reader blocked by the open transaction", "yes", "yes" if before_wait > 3.0 else "no")

    sqlcmd("ALTER DATABASE AFS_Lab_Change SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;")
    print("== blocking after READ_COMMITTED_SNAPSHOT ==")
    writer = start("BEGIN TRAN; UPDATE lab.Account SET Balance = Balance WHERE AccountId = 1; "
                   "WAITFOR DELAY '00:00:06'; ROLLBACK;")
    time.sleep(1.0)
    t0 = time.perf_counter()
    rc, out, err = sqlcmd("SET NOCOUNT ON; SELECT Balance FROM lab.Account WHERE AccountId = 1;", "AFS_Lab_Change")
    after_wait = time.perf_counter() - t0
    finish(writer)
    print(f"  reader waited {after_wait:.2f}s")
    check("C14", "reader no longer blocked", "yes", "yes" if after_wait < 1.5 else "no")

    passed = sum(1 for a in ASSERTIONS if a["passed"])
    payload = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "baseline": base, "after_bad_update": after_bad, "restored": restored,
        "timings_seconds": timings,
        "blocking_seconds": {"before_rcsi": round(before_wait, 2), "after_rcsi": round(after_wait, 2)},
        "assertions": ASSERTIONS, "summary": {"passed": passed, "total": len(ASSERTIONS)},
    }
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    (EVIDENCE / f"p03-run-{stamp}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    (EVIDENCE / "p03-latest.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

    md = [
        "# P-03 change and recovery — executed results", "",
        f"Generated {payload['generated_at_utc']} against disposable `AFS_Lab_Change`.", "",
        "## Change and detection", "",
        f"- Baseline: {base['rows']} rows, total {base['total']}, checksum {base['checksum']}",
        f"- Unbounded `UPDATE`: **{after_bad['rows']} rows**, total {after_bad['total']}",
        f"- Detection verdict after the change: **BALANCE_DRIFT** (checksum also changed; balance is checked first)", "",
        "## Recovery (point in time, before the update)", "",
        f"- Database restore: **{timings['database_restore_s']} s**",
        f"- Verification query after restore: **{timings['service_verified_s']} s**",
        f"- Restored state: {restored['rows']} rows, checksum {restored['checksum']} (baseline match: "
        f"{'yes' if restored['checksum'] == base['checksum'] else 'no'})", "",
        "## Blocking", "",
        "| Configuration | Reader wait (s) |", "|---|---:|",
        f"| READ COMMITTED (default) | {before_wait:.2f} |",
        f"| READ_COMMITTED_SNAPSHOT ON | {after_wait:.2f} |", "",
        "## Assertions", "", "| ID | Check | Expected | Actual | Result |", "|---|---|---|---|---|",
        *[f"| {a['id']} | {a['description']} | `{a['expected']}` | `{a['actual']}` | "
          f"{'PASS' if a['passed'] else 'FAIL'} |" for a in ASSERTIONS], "",
        f"**{passed}/{len(ASSERTIONS)} assertions passed.**", "",
        "Database restore time is not business-service recovery: the second figure only covers verifying",
        "the restored state, not reconnecting applications, replaying messages or clearing a queue.",
    ]
    (EVIDENCE / "RESULTS.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print("== cleanup ==")
    sqlcmd("ALTER DATABASE AFS_Lab_Change SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_Lab_Change;")
    print(f"{passed}/{len(ASSERTIONS)} assertions passed")
    return 0 if passed == len(ASSERTIONS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
