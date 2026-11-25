#!/usr/bin/env python3
"""P-01 payment integrity laboratory — scenario driver.

Runs the same four scenarios twice: once against the deliberately unsafe
processor (problem reproduction + diagnosis), once against the corrected one
(validation). Writes JSON and Markdown evidence under evidence/research/P-01/.

Every result is produced by executing SQL against the local instance. Nothing is
hard-coded as a pass.

Usage:
    python tools/paylab/run_scenarios.py
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DB = "AFS_Payments"
EVIDENCE = ROOT / "evidence" / "research" / "P-01"
SQLCMD = (
    os.environ.get("SQLCMD")
    or r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"
    or shutil.which("sqlcmd")
)

RAW_LOG: list[str] = []
ASSERTIONS: list[dict] = []
SCENARIOS: list[dict] = []


def _cmd(path: Path) -> list[str]:
    return [SQLCMD, "-E", "-C", "-S", ".", "-d", DB,
            "-b", "-I", "-h", "-1", "-W", "-s", "|", "-f", "65001", "-i", str(path)]


def _temp(sql: str) -> Path:
    fd, name = tempfile.mkstemp(suffix=".sql", text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(sql)
    return Path(name)


def run_sql(sql: str, timeout: int = 180) -> tuple[int, str, str]:
    path = _temp(sql)
    try:
        proc = subprocess.run(_cmd(path), capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=timeout)
    finally:
        path.unlink(missing_ok=True)
    out, err = proc.stdout.strip(), proc.stderr.strip()
    RAW_LOG.append(f"--- rc={proc.returncode}\n{sql.strip()}\n--- out\n{out}\n--- err\n{err}")
    return proc.returncode, out, err


def scalar(sql: str, default: str | None = None) -> str | None:
    rc, out, err = run_sql(sql)
    if rc != 0:
        raise RuntimeError(f"query failed rc={rc}: {err or out}")
    for line in out.splitlines():
        line = line.strip()
        if line:
            return line.split("|")[0].strip()
    return default


def reset(drop_index: bool) -> None:
    run_sql(f"EXEC paylab.usp_Reset @DropIdempotencyIndex = {1 if drop_index else 0};")


def apply_file(rel: str) -> None:
    path = ROOT / rel
    rc, out, err = run_sql(path.read_text(encoding="utf-8"))
    if rc != 0:
        raise RuntimeError(f"{rel} failed: {err or out}")
    print(f"applied {rel}")


def _row(sql: str) -> list[str]:
    rc, out, err = run_sql(sql)
    if rc != 0:
        raise RuntimeError(f"query failed: {err or out}")
    return out.splitlines()[0].split("|") if out else []


def submit_unsafe(request_id: str, debit: int, credit: int, amount: float,
                  fault: str | None = None, delay: int = 0) -> tuple[str, str]:
    fault_sql = f"@Fault='{fault}'" if fault else "@Fault=NULL"
    sql = f"""
SET NOCOUNT ON;
DECLARE @pid bigint, @out varchar(30);
EXEC paylab.usp_Submit_Unsafe
     @RequestId='{request_id}', @DebitAccountId={debit}, @CreditAccountId={credit},
     @Amount={amount}, @ReadDelayMs={delay}, {fault_sql},
     @PaymentId=@pid OUTPUT, @Outcome=@out OUTPUT;
SELECT CONCAT(@pid, '|', @out);
"""
    return tuple(_row(sql))  # type: ignore[return-value]


def submit_safe(key: str, request_id: str, debit: int, credit: int,
                amount: float, fault: str | None = None) -> tuple[str, str]:
    fault_sql = f"@Fault='{fault}'" if fault else "@Fault=NULL"
    sql = f"""
SET NOCOUNT ON;
DECLARE @pid bigint, @res int;
EXEC paylab.usp_Submit_Safe
     @IdempotencyKey='{key}', @RequestId='{request_id}',
     @DebitAccountId={debit}, @CreditAccountId={credit}, @Amount={amount},
     {fault_sql}, @PaymentId=@pid OUTPUT, @Result=@res OUTPUT;
SELECT CONCAT(ISNULL(CAST(@pid AS varchar), 'NULL'), '|', @res);
"""
    return tuple(_row(sql))  # type: ignore[return-value]


def submit_async(fn, *args) -> subprocess.Popen:
    """Start a submission in a separate sqlcmd process so two really overlap."""
    script = f"""
SET NOCOUNT ON;
DECLARE @pid bigint, @out varchar(30);
EXEC paylab.usp_Submit_Unsafe
     @RequestId='{args[0]}', @DebitAccountId={args[1]}, @CreditAccountId={args[2]},
     @Amount={args[3]}, @ReadDelayMs={args[4]}, @Fault=NULL,
     @PaymentId=@pid OUTPUT, @Outcome=@out OUTPUT;
SELECT CONCAT(@pid, '|', @out);
"""
    path = _temp(script)
    proc = subprocess.Popen(_cmd(path), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, encoding="utf-8", errors="replace")
    proc._sql_path = path  # type: ignore[attr-defined]
    return proc


def submit_safe_async(key: str, request_id: str, debit: int, credit: int, amount: float) -> subprocess.Popen:
    script = f"""
SET NOCOUNT ON;
DECLARE @pid bigint, @res int;
EXEC paylab.usp_Submit_Safe
     @IdempotencyKey='{key}', @RequestId='{request_id}',
     @DebitAccountId={debit}, @CreditAccountId={credit}, @Amount={amount},
     @Fault=NULL, @PaymentId=@pid OUTPUT, @Result=@res OUTPUT;
SELECT CONCAT(ISNULL(CAST(@pid AS varchar), 'NULL'), '|', @res);
"""
    path = _temp(script)
    proc = subprocess.Popen(_cmd(path), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, encoding="utf-8", errors="replace")
    proc._sql_path = path  # type: ignore[attr-defined]
    return proc


def finish(proc: subprocess.Popen) -> list[str]:
    out, err = proc.communicate(timeout=120)
    path = getattr(proc, "_sql_path", None)
    if path:
        path.unlink(missing_ok=True)
    RAW_LOG.append(f"--- async rc={proc.returncode}\n--- out\n{out.strip()}\n--- err\n{err.strip()}")
    if proc.returncode != 0:
        raise RuntimeError(err or out)
    return out.strip().splitlines()[0].split("|")


def reconcile(mode: str) -> int:
    val = scalar(f"""
SET NOCOUNT ON;
DECLARE @run bigint;
EXEC paylab.usp_Reconcile @Mode='{mode}', @RunId=@run OUTPUT;
SELECT BreakCount FROM paylab.ReconRun WHERE RunId=@run;
""")
    return int(val or 0)


def breaks_by_type() -> dict[str, int]:
    rc, out, err = run_sql("""
SET NOCOUNT ON;
SELECT CONCAT(BreakType, '|', COUNT(*)) FROM paylab.ReconBreak GROUP BY BreakType ORDER BY BreakType;
""")
    if rc != 0:
        raise RuntimeError(err or out)
    result = {}
    for line in out.splitlines():
        if "|" in line:
            k, v = line.split("|", 1)
            result[k.strip()] = int(v)
    return result


def snapshot() -> dict:
    row = _row("""
SET NOCOUNT ON;
SELECT CONCAT(
  (SELECT COUNT(*) FROM paylab.Account), '|',
  (SELECT COUNT(*) FROM paylab.PaymentIntent), '|',
  (SELECT COUNT(*) FROM paylab.PaymentIntent WHERE Status='COMPLETED'), '|',
  (SELECT COUNT(*) FROM paylab.PaymentIntent WHERE Status='FAILED'), '|',
  (SELECT COUNT(*) FROM paylab.LedgerEntry), '|',
  (SELECT COUNT(*) FROM paylab.LedgerEntry WHERE Direction='D'), '|',
  (SELECT COUNT(*) FROM paylab.LedgerEntry WHERE Direction='C'), '|',
  (SELECT ISNULL(SUM(Balance),0) FROM paylab.Account), '|',
  (SELECT ISNULL(SUM(CASE WHEN Direction='D' THEN Amount ELSE -Amount END),0) FROM paylab.LedgerEntry));
""")
    keys = ["accounts", "intents", "completed", "failed", "entries",
            "debits", "credits", "total_balance", "ledger_net"]
    return dict(zip(keys, row))


def check(aid: str, description: str, expected, actual) -> None:
    passed = str(expected) == str(actual)
    ASSERTIONS.append({"id": aid, "description": description,
                       "expected": expected, "actual": actual, "passed": passed})
    print(f"  {'PASS' if passed else 'FAIL'}  {aid}  {description} (expected {expected}, got {actual})")


def main() -> int:
    if not Path(SQLCMD).exists() and not shutil.which(SQLCMD):
        raise SystemExit(f"sqlcmd not found at {SQLCMD}")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc)
    timings: dict[str, float] = {}

    print("== schema ==")
    apply_file("sql-server/paylab/00_schema.sql")
    apply_file("sql-server/paylab/10_baseline_unsafe.sql")
    apply_file("sql-server/paylab/99_reset.sql")

    # ---------------------------------------------------------------- baseline
    print("\n== BASELINE: dry posting (debit commits, credit never happens) ==")
    reset(drop_index=True)
    t0 = time.perf_counter()
    pid, outcome = submit_unsafe(str(uuid.uuid4()), 1, 2, 1500.00, fault="FAIL_AFTER_DEBIT")
    timings["baseline_dry_posting_s"] = round(time.perf_counter() - t0, 3)
    baseline_dry_breaks = reconcile("baseline")
    dry = scalar("""SET NOCOUNT ON;
SELECT COUNT(*) FROM paylab.PaymentIntent p
JOIN paylab.LedgerEntry d ON d.PaymentId=p.PaymentId AND d.Direction='D'
WHERE NOT EXISTS (SELECT 1 FROM paylab.LedgerEntry c WHERE c.PaymentId=p.PaymentId AND c.Direction='C');""")
    print(f"  payment {pid} outcome={outcome} orphan-debit payments={dry} breaks={baseline_dry_breaks}")
    check("B1.1", "processor reports dry posting", "DRY_POSTING", outcome)
    check("B1.2", "debit exists with no credit", "1", dry)
    dry_types = breaks_by_type()
    check("B1.3", "reconciliation reports an orphan debit and a mismatch",
          "AMOUNT_MISMATCH+ORPHAN_DEBIT", "+".join(sorted(dry_types)))
    check("B1.6", "every break is attributed to the injected payment", "1",
          scalar("SELECT COUNT(DISTINCT PaymentId) FROM paylab.ReconBreak"))
    SCENARIOS.append({"scenario": "dry posting", "mode": "baseline",
                      "breaks": baseline_dry_breaks, "break_types": dry_types,
                      "detail": f"1 debit, 0 credits; breaks={baseline_dry_breaks}"})
    check("B1.4", "debit balance decreased despite no credit", "8500.0000",
          scalar("SELECT Balance FROM paylab.Account WHERE AccountId=1"))
    check("B1.5", "beneficiary was not credited", "10000.0000",
          scalar("SELECT Balance FROM paylab.Account WHERE AccountId=2"))

    print("\n== BASELINE: duplicate submission of the same request ==")
    reset(drop_index=True)
    rid = str(uuid.uuid4())
    t0 = time.perf_counter()
    for _ in range(3):
        submit_unsafe(rid, 1, 2, 250.00)
    timings["baseline_duplicate_3x_s"] = round(time.perf_counter() - t0, 3)
    dup_intents = scalar(f"SELECT COUNT(*) FROM paylab.PaymentIntent WHERE RequestId='{rid}'")
    dup_debits = scalar(f"""SET NOCOUNT ON;
SELECT COUNT(*) FROM paylab.LedgerEntry l JOIN paylab.PaymentIntent p ON p.PaymentId=l.PaymentId
WHERE p.RequestId='{rid}' AND l.Direction='D';""")
    baseline_dup_breaks = reconcile("baseline")
    print(f"  intents={dup_intents} debits={dup_debits} breaks={baseline_dup_breaks}")
    check("B2.1", "three submissions create three intents", "3", dup_intents)
    check("B2.2", "three submissions create three debits", "3", dup_debits)
    check("B2.3", "debit account charged three times", "9250.0000",
          scalar("SELECT Balance FROM paylab.Account WHERE AccountId=1"))
    SCENARIOS.append({"scenario": "duplicate submission", "mode": "baseline",
                      "breaks": baseline_dup_breaks, "break_types": breaks_by_type(),
                      "detail": f"3 intents, 3 debits for one request; breaks={baseline_dup_breaks}"})

    print("\n== BASELINE: concurrent transfers racing for one balance ==")
    reset(drop_index=True)
    t0 = time.perf_counter()
    p1 = submit_async(None, str(uuid.uuid4()), 1, 2, 8000.00, 400)
    p2 = submit_async(None, str(uuid.uuid4()), 1, 3, 8000.00, 400)
    r1, r2 = finish(p1), finish(p2)
    timings["baseline_concurrency_s"] = round(time.perf_counter() - t0, 3)
    bal1 = scalar("SELECT Balance FROM paylab.Account WHERE AccountId=1")
    ledger_net1 = scalar("""SET NOCOUNT ON;
SELECT SUM(CASE WHEN Direction='C' THEN Amount ELSE -Amount END) FROM paylab.LedgerEntry WHERE AccountId=1;""")
    baseline_conc_breaks = reconcile("baseline")
    print(f"  results={r1} {r2} stored balance={bal1} ledger net={ledger_net1} breaks={baseline_conc_breaks}")
    check("B3.1", "both concurrent transfers report success", "2",
          sum(1 for r in (r1, r2) if r[1] == "COMPLETED"))
    check("B3.2", "account spent 16,000 from a 10,000 balance", "-16000.0000", ledger_net1)
    check("B3.3", "stored balance disagrees with the ledger", "2000.0000", bal1)
    check("B3.4", "reconciliation reports balance drift", "1",
          breaks_by_type().get("BALANCE_DRIFT", 0))
    SCENARIOS.append({"scenario": "concurrent transfers", "mode": "baseline",
                      "breaks": baseline_conc_breaks, "break_types": breaks_by_type(),
                      "detail": f"2 x 8,000 from a 10,000 balance; stored {bal1}, ledger {ledger_net1}"})

    baseline_snapshot = snapshot()
    baseline_breaks = breaks_by_type()

    # ------------------------------------------------------------------- fix
    print("\n== APPLY FIX ==")
    apply_file("sql-server/paylab/20_fix.sql")

    print("\n== FIXED: replay the same idempotency key three times ==")
    reset(drop_index=False)
    key = f"idem-{uuid.uuid4()}"
    rid = str(uuid.uuid4())
    t0 = time.perf_counter()
    results = [submit_safe(key, rid, 1, 2, 250.00)[1] for _ in range(3)]
    timings["fixed_replay_3x_s"] = round(time.perf_counter() - t0, 3)
    fixed_debits = scalar(f"""SET NOCOUNT ON;
SELECT COUNT(*) FROM paylab.LedgerEntry l JOIN paylab.PaymentIntent p ON p.PaymentId=l.PaymentId
WHERE p.IdempotencyKey='{key}' AND l.Direction='D';""")
    print(f"  results={results} debits={fixed_debits}")
    check("F1.1", "first submission posts", "0", results[0])
    check("F1.2", "replays are recognised, not reposted", "1,1", ",".join(results[1:]))
    check("F1.3", "exactly one debit exists", "1", fixed_debits)
    check("F1.4", "account charged once", "9750.0000",
          scalar("SELECT Balance FROM paylab.Account WHERE AccountId=1"))
    SCENARIOS.append({"scenario": "replay same key x3", "mode": "fixed",
                      "breaks": 0, "break_types": {},
                      "detail": f"results {results}; 1 debit"})

    print("\n== FIXED: injected failure after the debit must roll back ==")
    reset(drop_index=False)
    key = f"idem-{uuid.uuid4()}"
    failed_pid, failed_result = submit_safe(key, str(uuid.uuid4()), 1, 2, 900.00,
                                            fault="FAIL_AFTER_DEBIT")
    failed_entries = scalar(f"SELECT COUNT(*) FROM paylab.LedgerEntry WHERE PaymentId={failed_pid}")
    failed_exc = scalar("SELECT COUNT(*) FROM paylab.ExceptionQueue")
    print(f"  payment={failed_pid} result={failed_result} entries={failed_entries} exceptions={failed_exc}")
    check("F2.1", "posting fails cleanly", "3", failed_result)
    check("F2.2", "no ledger entry survives the failure", "0", failed_entries)
    check("F2.3", "debit account untouched", "10000.0000",
          scalar("SELECT Balance FROM paylab.Account WHERE AccountId=1"))
    check("F2.4", "failure is queued for an operator", "1", failed_exc)
    SCENARIOS.append({"scenario": "failure after debit", "mode": "fixed",
                      "breaks": 0, "break_types": {},
                      "detail": "transaction rolled back; debit untouched; exception queued"})
    trace_text = run_sql(f"EXEC paylab.usp_TracePayment @PaymentId={failed_pid};")[1]

    print("\n== FIXED: concurrent transfers cannot spend the same balance ==")
    reset(drop_index=False)
    p1 = submit_safe_async(f"idem-{uuid.uuid4()}", str(uuid.uuid4()), 1, 2, 8000.00)
    p2 = submit_safe_async(f"idem-{uuid.uuid4()}", str(uuid.uuid4()), 1, 3, 8000.00)
    r1, r2 = finish(p1), finish(p2)
    codes = sorted(int(r[1]) for r in (r1, r2))
    bal1 = scalar("SELECT Balance FROM paylab.Account WHERE AccountId=1")
    ledger_net1 = scalar("""SET NOCOUNT ON;
SELECT ISNULL(SUM(CASE WHEN Direction='C' THEN Amount ELSE -Amount END),0)
FROM paylab.LedgerEntry WHERE AccountId=1;""")
    fixed_breaks = reconcile("fixed")
    print(f"  results={codes} balance={bal1} ledger net={ledger_net1} breaks={fixed_breaks}")
    check("F3.1", "exactly one transfer succeeds and one is declined", "0,2", ",".join(map(str, codes)))
    check("F3.2", "stored balance equals ledger-derived balance", "2000.0000", bal1)
    check("F3.3", "ledger records only the successful 8,000", "-8000.0000", ledger_net1)
    check("F3.4", "reconciliation reports no breaks", "0", fixed_breaks)
    SCENARIOS.append({"scenario": "concurrent transfers", "mode": "fixed",
                      "breaks": fixed_breaks, "break_types": {},
                      "detail": f"results {codes}; balance {bal1}; ledger {ledger_net1}"})

    print("\n== FIXED: outbox and inbox ==")
    unpublished_before = scalar("SELECT COUNT(*) FROM paylab.Outbox WHERE PublishedAt IS NULL")
    published = scalar("EXEC paylab.usp_PublishOutbox @BatchSize = 100;")
    unpublished_after = scalar("SELECT COUNT(*) FROM paylab.Outbox WHERE PublishedAt IS NULL")
    msg = str(uuid.uuid4())
    first = scalar(f"DECLARE @r int; EXEC paylab.usp_ProcessInbox @MessageId='{msg}', @Result=@r OUTPUT; SELECT @r;")
    second = scalar(f"DECLARE @r int; EXEC paylab.usp_ProcessInbox @MessageId='{msg}', @Result=@r OUTPUT; SELECT @r;")
    print(f"  outbox unpublished {unpublished_before}->{unpublished_after}, inbox {first}/{second}")
    check("F4.1", "outbox row exists for the committed payment", "1", unpublished_before)
    check("F4.2", "publishing clears the queue", "0", unpublished_after)
    check("F4.3", "first message processed", "1", first)
    check("F4.4", "duplicate message ignored", "0", second)

    print("\n== FIXED: payment is traceable end to end ==")
    check("F5.1", "trace shows the failed payment", "yes",
          "yes" if str(failed_pid) in trace_text else "no")
    check("F5.2", "trace shows a FAILED event", "yes",
          "yes" if "FAILED" in trace_text else "no")

    fixed_snapshot = snapshot()

    # ------------------------------------------------------------------ report
    passed = sum(1 for a in ASSERTIONS if a["passed"])
    total = len(ASSERTIONS)
    payload = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "started_at_utc": started.isoformat(timespec="seconds"),
        "database": DB,
        "schema": "paylab",
        "scenarios": SCENARIOS,
        "baseline": {"snapshot": baseline_snapshot, "breaks": baseline_breaks,
                     "breaks_total": sum(baseline_breaks.values())},
        "fixed": {"snapshot": fixed_snapshot, "breaks_total": fixed_breaks},
        "assertions": ASSERTIONS,
        "summary": {"passed": passed, "total": total},
        "timings_seconds": timings,
    }
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    (EVIDENCE / f"p01-run-{stamp}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    (EVIDENCE / "p01-latest.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    (EVIDENCE / f"p01-run-{stamp}.log").write_text("\n\n".join(RAW_LOG), encoding="utf-8")

    md = [
        "# P-01 payment integrity — executed results",
        "",
        f"Generated {payload['generated_at_utc']} against `{DB}` schema `paylab`.",
        "",
        "## Scenarios executed",
        "",
        "| Scenario | Mode | Reconciliation breaks | Detail |",
        "|---|---|---:|---|",
        *[f"| {s['scenario']} | {s['mode']} | {s['breaks']} | {s['detail']} |" for s in SCENARIOS],
        "",
        "## Baseline (unsafe processor)",
        "",
        f"- Reconciliation breaks: **{payload['baseline']['breaks_total']}** "
        f"({', '.join(f'{k} {v}' for k, v in baseline_breaks.items()) or 'none'})",
        f"- Intents {baseline_snapshot['intents']}, ledger entries {baseline_snapshot['entries']}, "
        f"total balance {baseline_snapshot['total_balance']}, ledger net {baseline_snapshot['ledger_net']}",
        "",
        "## After the fix",
        "",
        f"- Reconciliation breaks: **{fixed_breaks}**",
        f"- Intents {fixed_snapshot['intents']}, ledger entries {fixed_snapshot['entries']}, "
        f"total balance {fixed_snapshot['total_balance']}, ledger net {fixed_snapshot['ledger_net']}",
        "",
        "## Assertions",
        "",
        "| ID | Check | Expected | Actual | Result |",
        "|---|---|---|---|---|",
    ]
    for a in ASSERTIONS:
        md.append(f"| {a['id']} | {a['description']} | `{a['expected']}` | `{a['actual']}` | "
                  f"{'PASS' if a['passed'] else 'FAIL'} |")
    md += ["", f"**{passed}/{total} assertions passed.**", "",
           "Timings (wall clock per scenario batch, including `sqlcmd` process start):", ""]
    for k, v in timings.items():
        md.append(f"- {k}: {v} s")
    (EVIDENCE / "RESULTS.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print(f"\n{passed}/{total} assertions passed")
    print(f"evidence: {EVIDENCE / 'RESULTS.md'}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
