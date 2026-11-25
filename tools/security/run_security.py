#!/usr/bin/env python3
"""P-04 privileged access and audit driver.

Baseline: paylab_app holds CONTROL on the lab schema and can rewrite ledger rows
with no in-database audit trail.
Fix: CONTROL revoked, direct DML denied, execution through the payment procedure
only, and every ledger write captured with the calling principal.

Uses EXECUTE AS USER, so no credential is created and nothing external is touched.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "evidence" / "research" / "P-04"
SQLCMD = (
    os.environ.get("SQLCMD")
    or r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"
    or shutil.which("sqlcmd")
)
ASSERTIONS: list[dict] = []


def sqlcmd(sql: str, db: str = "AFS_Payments", timeout: int = 120) -> tuple[int, str, str]:
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


def scalar(sql: str, db: str = "AFS_Payments", default: str = "") -> str:
    rc, out, err = sqlcmd(sql, db)
    if rc != 0:
        raise RuntimeError(err or out)
    for line in out.splitlines():
        if line.strip():
            return line.split("|")[0].strip()
    return default


def apply_file(rel: str) -> None:
    rc, out, err = sqlcmd((ROOT / rel).read_text(encoding="utf-8"))
    if rc != 0:
        raise RuntimeError(f"{rel}: {err or out}")


def check(aid: str, description: str, expected, actual) -> None:
    passed = str(expected) == str(actual)
    ASSERTIONS.append({"id": aid, "description": description,
                       "expected": expected, "actual": actual, "passed": passed})
    print(f"  {'PASS' if passed else 'FAIL'}  {aid}  {description} (expected {expected}, got {actual})")


def as_app(statement: str) -> tuple[int, str, str]:
    return sqlcmd(f"EXECUTE AS USER = 'paylab_app';\n{statement}\nREVERT;")


def main() -> int:
    EVIDENCE.mkdir(parents=True, exist_ok=True)

    print("== baseline: over-privileged application principal ==")
    apply_file("sql-server/security/00_lab_setup.sql")
    sqlcmd("EXEC paylab.usp_Reset @DropIdempotencyIndex = 0;")
    sqlcmd("DELETE FROM paylab.SecurityLog;")   # lab reset only, not a production pattern

    # seed one balanced payment so there is a ledger row to tamper with
    rc, out, err = sqlcmd(
        "DECLARE @pid bigint, @res int, @rid uniqueidentifier = NEWID();"
        "EXEC paylab.usp_Submit_Safe @IdempotencyKey='p04-seed', @RequestId=@rid, "
        "@DebitAccountId=1, @CreditAccountId=2, @Amount=100.00, "
        "@PaymentId=@pid OUTPUT, @Result=@res OUTPUT;")
    if rc != 0:
        raise RuntimeError(err or out)

    control_before = scalar(
        "SELECT COUNT(*) FROM sys.database_permissions dp JOIN sys.database_principals p "
        "ON p.principal_id=dp.grantee_principal_id WHERE p.name='paylab_app' AND dp.permission_name='CONTROL';")

    rc_upd, out_upd, err_upd = as_app(
        "UPDATE paylab.LedgerEntry SET Amount = Amount WHERE EntryId = "
        "(SELECT MIN(EntryId) FROM paylab.LedgerEntry);")
    rc_del, out_del, err_del = as_app("DELETE TOP (1) FROM paylab.LedgerEntry;")
    audit_before = scalar("SELECT COUNT(*) FROM paylab.SecurityLog;")

    print(f"  CONTROL grants={control_before} update_rc={rc_upd} delete_rc={rc_del} audit_rows={audit_before}")
    check("S1", "application can rewrite a ledger row", "0", rc_upd)
    check("S2", "application can delete a ledger row", "0", rc_del)
    check("S3", "no in-database audit evidence of the change", "0", audit_before)
    check("S4", "baseline grants CONTROL on the schema", "1", control_before)

    print("== apply least privilege and audit ==")
    apply_file("sql-server/security/10_least_privilege_fix.sql")

    control_after = scalar(
        "SELECT COUNT(*) FROM sys.database_permissions dp JOIN sys.database_principals p "
        "ON p.principal_id=dp.grantee_principal_id WHERE p.name='paylab_app' AND dp.permission_name='CONTROL';")
    deny_after = scalar(
        "SELECT COUNT(*) FROM sys.database_permissions dp JOIN sys.database_principals p "
        "ON p.principal_id=dp.grantee_principal_id WHERE p.name='paylab_app' AND dp.state_desc='DENY';")

    rc_upd2, out_upd2, err_upd2 = as_app(
        "UPDATE paylab.LedgerEntry SET Amount = Amount WHERE EntryId = "
        "(SELECT MIN(EntryId) FROM paylab.LedgerEntry);")
    rc_del2, out_del2, err_del2 = as_app("DELETE TOP (1) FROM paylab.LedgerEntry;")
    denial_text = (err_upd2 + out_upd2 + err_del2 + out_del2).lower()
    denied = "229" in denial_text or "permission was denied" in denial_text
    print(f"  after: CONTROL={control_after} DENY rows={deny_after} update_rc={rc_upd2} delete_rc={rc_del2}")
    check("S5", "CONTROL grant removed", "0", control_after)
    check("S6", "explicit DENY permissions present", "yes", "yes" if int(deny_after) >= 2 else "no")
    check("S7", "direct ledger update denied", "yes", "yes" if rc_upd2 != 0 and denied else "no")
    check("S8", "direct ledger delete denied", "yes", "yes" if rc_del2 != 0 and denied else "no")

    # the application still works through the API, and that path is audited
    rc_api, out_api, err_api = as_app(
        "DECLARE @pid bigint, @res int, @rid uniqueidentifier = NEWID();"
        "EXEC paylab.usp_Submit_Safe @IdempotencyKey='p04-app', @RequestId=@rid, "
        "@DebitAccountId=3, @CreditAccountId=4, @Amount=25.00, "
        "@PaymentId=@pid OUTPUT, @Result=@res OUTPUT;")
    app_events = scalar("SELECT COUNT(*) FROM paylab.SecurityLog WHERE PrincipalName='paylab_app';")
    ledger_rows = scalar("SELECT COUNT(*) FROM paylab.LedgerEntry;")
    print(f"  api_rc={rc_api} app_audit_rows={app_events} ledger_rows={ledger_rows}")
    check("S9", "application can post through the procedure", "0", rc_api)
    check("S10", "ledger write is attributed to the application", "yes", "yes" if int(app_events) >= 1 else "no")

    # failed-login pattern over the existing security events
    failed_total = scalar("SELECT COUNT(*) FROM AFS_Audit.security.SecurityEvent WHERE Success=0;", "master")
    failed_principal = scalar(
        "SELECT TOP 1 PrincipalName FROM AFS_Audit.security.SecurityEvent WHERE Success=0 "
        "GROUP BY PrincipalName ORDER BY COUNT(*) DESC;", "master")
    print(f"  failed events={failed_total} top principal={failed_principal}")
    check("S11", "failed-login events are detectable", "yes", "yes" if int(failed_total) > 0 else "no")

    # restore the lab to a clean state (does not remove the control or its evidence)
    sqlcmd("EXEC paylab.usp_Reset @DropIdempotencyIndex = 0;")

    passed = sum(1 for a in ASSERTIONS if a["passed"])
    payload = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "database": "AFS_Payments", "schema": "paylab",
        "baseline": {"control_grants": int(control_before), "update_allowed": rc_upd == 0,
                     "delete_allowed": rc_del == 0, "audit_rows": int(audit_before)},
        "after": {"control_grants": int(control_after), "deny_rows": int(deny_after),
                  "update_denied": rc_upd2 != 0, "delete_denied": rc_del2 != 0,
                  "api_still_works": rc_api == 0, "app_audit_rows": int(app_events)},
        "failed_logins": {"total": int(failed_total), "top_principal": failed_principal},
        "assertions": ASSERTIONS, "summary": {"passed": passed, "total": len(ASSERTIONS)},
    }
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    (EVIDENCE / f"p04-run-{stamp}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    (EVIDENCE / "p04-latest.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

    md = [
        "# P-04 privileged access and audit — executed results", "",
        f"Generated {payload['generated_at_utc']} against `AFS_Payments` schema `paylab`.", "",
        "## Baseline", "",
        f"- `paylab_app` held **CONTROL** on the schema ({control_before} grant)",
        f"- Ledger UPDATE allowed: {'yes' if rc_upd == 0 else 'no'}; DELETE allowed: {'yes' if rc_del == 0 else 'no'}",
        f"- Audit rows produced by those changes: **{audit_before}**", "",
        "## After least privilege", "",
        f"- CONTROL grants: **{control_after}**; explicit DENY rows: **{deny_after}**",
        f"- Ledger UPDATE denied: {'yes' if rc_upd2 != 0 else 'no'}; DELETE denied: {'yes' if rc_del2 != 0 else 'no'}",
        f"- Payment through the procedure succeeded: {'yes' if rc_api == 0 else 'no'}",
        f"- Ledger writes attributed to `paylab_app` in the audit log: **{app_events}**", "",
        "## Failed-login detection", "",
        f"- Failed events: {failed_total}; most frequent principal: `{failed_principal}`", "",
        "## Assertions", "", "| ID | Check | Expected | Actual | Result |", "|---|---|---|---|---|",
        *[f"| {a['id']} | {a['description']} | `{a['expected']}` | `{a['actual']}` | "
          f"{'PASS' if a['passed'] else 'FAIL'} |" for a in ASSERTIONS], "",
        f"**{passed}/{len(ASSERTIONS)} assertions passed.**", "",
        "The audit trail is an in-database trigger, not SQL Server Audit or a SIEM feed. Denied statements",
        "never execute, so they are evidenced by the engine error, not by the trigger.",
    ]
    (EVIDENCE / "RESULTS.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print(f"{passed}/{len(ASSERTIONS)} assertions passed")
    return 0 if passed == len(ASSERTIONS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
