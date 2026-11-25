#!/usr/bin/env python3
"""P-02 telemetry data-quality driver.

1. Ensures the Modbus simulator is running.
2. Runs the fault-emitting collector for N seconds (real Modbus reads).
3. Validates the staged batch: units, duplicates, ordering, plausibility.
4. Scores completeness from observed cadence.
5. Applies a correction and proves the original is preserved.
6. Writes JSON + Markdown evidence and exits non-zero if an assertion fails.

Usage: python tools/ot/run_quality.py --seconds 90
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DB = "AFS_Archive"
EVIDENCE = ROOT / "evidence" / "research" / "P-02"
SQLCMD = (
    os.environ.get("SQLCMD")
    or r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"
    or shutil.which("sqlcmd")
)
ASSERTIONS: list[dict] = []


def sqlcmd(sql: str, timeout: int = 180) -> tuple[int, str, str]:
    fd, name = tempfile.mkstemp(suffix=".sql", text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(sql)
    try:
        proc = subprocess.run(
            [SQLCMD, "-E", "-C", "-S", ".", "-d", DB, "-b", "-I",
             "-h", "-1", "-W", "-s", "|", "-f", "65001", "-i", name],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    finally:
        os.unlink(name)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def rows(sql: str) -> list[list[str]]:
    rc, out, err = sqlcmd(sql)
    if rc != 0:
        raise RuntimeError(err or out)
    return [line.split("|") for line in out.splitlines() if line.strip()]


def scalar(sql: str, default: str = "") -> str:
    r = rows(sql)
    return r[0][0] if r else default


def apply_file(rel: str) -> None:
    rc, out, err = sqlcmd((ROOT / rel).read_text(encoding="utf-8"))
    if rc != 0:
        raise RuntimeError(f"{rel}: {err or out}")


def check(aid: str, description: str, expected, actual) -> None:
    passed = str(expected) == str(actual)
    ASSERTIONS.append({"id": aid, "description": description,
                       "expected": expected, "actual": actual, "passed": passed})
    print(f"  {'PASS' if passed else 'FAIL'}  {aid}  {description} (expected {expected}, got {actual})")


def port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=90)
    ap.add_argument("--port", type=int, default=15020)
    args = ap.parse_args()

    EVIDENCE.mkdir(parents=True, exist_ok=True)
    print("== schema ==")
    apply_file("sql-server/telemetry/00_quality_schema.sql")
    apply_file("sql-server/telemetry/10_quality_pipeline.sql")

    # clear previous P-02 runs so the experiment is repeatable
    for (run_id,) in [(r[0],) for r in rows(
            "SET NOCOUNT ON; SELECT RunId FROM telemetry.CollectorRun WHERE Notes LIKE N'P-02%';")]:
        sqlcmd(f"EXEC telemetry.usp_ResetQualityRun @RunId = {run_id};")

    sim = None
    if not port_open(args.port):
        print(f"== starting Modbus simulator on {args.port} ==")
        sim = subprocess.Popen([sys.executable, str(ROOT / "tools/ot/plc_sim.py"),
                                "--port", str(args.port)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(40):
            if port_open(args.port):
                break
            time.sleep(0.25)
        if not port_open(args.port):
            raise SystemExit("simulator did not open the port")

    try:
        print(f"== collecting {args.seconds}s with injected faults ==")
        t0 = time.perf_counter()
        proc = subprocess.run(
            [sys.executable, str(ROOT / "tools/ot/fault_collector.py"),
             "--port", str(args.port), "--seconds", str(args.seconds)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=args.seconds + 120)
        collect_s = round(time.perf_counter() - t0, 2)
        if proc.returncode != 0:
            raise SystemExit(proc.stderr or proc.stdout)
        meta = json.loads(proc.stdout.strip().splitlines()[-1])
        run_id = meta["runId"]
        print(f"  run {run_id}: staged {meta['staged']} rows")

        print("== validate ==")
        sqlcmd(f"EXEC telemetry.usp_ValidateStaging @RunId = {run_id};")
        print("== score completeness ==")
        sqlcmd(f"EXEC telemetry.usp_ScoreCompleteness @RunId = {run_id};")

        outcomes = {r[0]: int(r[1]) for r in rows(
            f"SET NOCOUNT ON; SELECT ISNULL(Outcome,'PENDING'), COUNT(*) FROM telemetry.Staging "
            f"WHERE RunId={run_id} GROUP BY Outcome;")}
        reasons = {r[0]: int(r[1]) for r in rows(
            f"SET NOCOUNT ON; SELECT Reason, COUNT(*) FROM telemetry.Quarantine "
            f"WHERE RunId={run_id} GROUP BY Reason;")}
        scores = {r[0]: {"observed": int(r[1]), "expected": float(r[2]),
                         "ratio": float(r[3]), "maxGap": float(r[4]), "pGap": float(r[5])}
                  for r in rows(f"SET NOCOUNT ON; SELECT TagCode, Observed, Expected, "
                                f"CompletenessRatio, MaxGapSeconds, GapProbability "
                                f"FROM telemetry.CompletenessScore WHERE RunId={run_id};")}
        promoted = int(scalar(f"SELECT COUNT(*) FROM telemetry.Reading WHERE SourceRunId={run_id}"))
        raw_null = int(scalar(f"SELECT COUNT(*) FROM telemetry.Staging WHERE RunId={run_id} AND RawValue IS NULL"))

        valid = outcomes.get("VALID", 0) + outcomes.get("VALID_LATE", 0) + outcomes.get("VALID_OUT_OF_ORDER", 0)
        missing_total = sum(max(0, round(s["expected"] - s["observed"])) for s in scores.values())

        print(f"  outcomes={outcomes} reasons={reasons}")
        print(f"  promoted={promoted} missing={missing_total} scores={scores}")

        min_staged = int(args.seconds * 3 * 0.8)   # 3 tags at ~1 Hz, allowing for drops
        check("Q1", "staged rows received", "yes",
              "yes" if meta["staged"] > min_staged else "no")
        check("Q2", "duplicates detected and quarantined", "yes",
              "yes" if reasons.get("DUPLICATE", 0) >= 3 else "no")
        check("Q3", "invalid rows quarantined", "yes",
              "yes" if sum(v for k, v in reasons.items() if k != "DUPLICATE") >= 4 else "no")
        check("Q4", "null and out-of-range faults quarantined", "NULL_VALUE,OUT_OF_RANGE",
              ",".join(sorted(set(reasons) - {"DUPLICATE"})))
        kpa = int(scalar(f"SELECT COUNT(*) FROM telemetry.Staging WHERE RunId={run_id} "
                         f"AND RawUnit='kPa' AND Outcome IN ('VALID','VALID_LATE','VALID_OUT_OF_ORDER')"))
        kpa_value = float(scalar(f"SET NOCOUNT ON; SELECT TOP 1 r.Value FROM telemetry.Reading r "
                                 f"JOIN telemetry.Staging s ON s.ObservedAt=r.ObservedAt "
                                 f"AND s.RunId=r.SourceRunId AND s.TagCode='WELLHEAD_PRESS' "
                                 f"WHERE r.SourceRunId={run_id} AND s.RawUnit='kPa' ORDER BY s.StagingId;") or 0)
        check("Q4b", "kPa pressure converted to bar", "yes",
              "yes" if kpa >= 1 and 40 <= kpa_value <= 120 else "no")
        check("Q5", "every staged row classified (no pending)", "0", outcomes.get("PENDING", 0))
        check("Q6", "accepted rows equal promoted readings", valid, promoted)
        check("Q7", "missing readings estimated from cadence", "yes",
              "yes" if missing_total >= max(1, args.seconds // 30) else "no")
        check("Q8", "completeness below 1 for every tag", "yes",
              "yes" if all(s["ratio"] < 1 for s in scores.values()) else "no")
        check("Q9", "corrupt originals retained in staging", "yes", "yes" if raw_null >= 1 else "no")

        # correction: change the accepted value, keep the original
        target = rows(f"SET NOCOUNT ON; SELECT TOP 1 ReadingId, Value FROM telemetry.Reading "
                      f"WHERE SourceRunId={run_id} AND Quality=1 ORDER BY ReadingId;")[0]
        reading_id, original = target[0], float(target[1])
        corrected = round(original + 0.1, 3)
        sqlcmd(f"EXEC telemetry.usp_CorrectReading @ReadingId={reading_id}, @NewValue={corrected}, "
               f"@Reason=N'P-02 calibration check', @Actor=N'lab.engineer';")
        eff = rows(f"SET NOCOUNT ON; SELECT OriginalValue, EffectiveValue, IsCorrected "
                   f"FROM telemetry.vw_EffectiveReading WHERE ReadingId={reading_id};")[0]
        corrections = int(scalar(f"SELECT COUNT(*) FROM telemetry.Correction WHERE ReadingId={reading_id}"))
        print(f"  correction on {reading_id}: {eff}")
        check("Q10", "correction recorded once", "1", corrections)
        check("Q11", "original value preserved in the view", f"{original:.3f}", f"{float(eff[0]):.3f}")
        check("Q12", "effective value reflects the correction", f"{corrected:.3f}", f"{float(eff[1]):.3f}")

        # completeness evidence for the report
        comp_rows = [{"tag": k, **v} for k, v in sorted(scores.items())]
        passed = sum(1 for a in ASSERTIONS if a["passed"])

        payload = {
            "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "database": DB, "run_id": run_id, "collector": meta,
            "outcomes": outcomes, "quarantine_reasons": reasons,
            "promoted_readings": promoted, "estimated_missing": missing_total,
            "completeness": comp_rows,
            "correction": {"reading_id": int(reading_id), "original": original, "corrected": corrected},
            "assertions": ASSERTIONS, "summary": {"passed": passed, "total": len(ASSERTIONS)},
            "timings_seconds": {"collection": collect_s},
        }
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        (EVIDENCE / f"p02-run-{stamp}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
        (EVIDENCE / "p02-latest.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

        md = [
            "# P-02 telemetry quality — executed results", "",
            f"Run {run_id}, {payload['generated_at_utc']}, {args.seconds}s at ~1 Hz over Modbus TCP.", "",
            "## Received and staged", "",
            f"- Staged rows: **{meta['staged']}** (simulator dropped {meta['dropped']} samples)",
            f"- Duplicates injected: {meta['duplicates']}, late: {meta['late']}, out-of-order: {meta['outOfOrder']}, "
            f"unit errors: {meta['unitErrors']}, spikes: {meta['spikes']}, corrupt: {meta['corrupt']}, "
            f"conflicting source: {meta['conflictingSources']}", "",
            "## Classification", "", "| Outcome | Rows |", "|---|---:|",
            *[f"| {k} | {v} |" for k, v in sorted(outcomes.items())], "",
            "## Quarantine reasons", "", "| Reason | Rows |", "|---|---:|",
            *[f"| {k} | {v} |" for k, v in sorted(reasons.items())], "",
            "## Completeness", "",
            "| Tag | Observed | Expected | Ratio | Max gap (s) | Gap probability |",
            "|---|---:|---:|---:|---:|---:|",
            *[f"| {c['tag']} | {c['observed']} | {c['expected']:.1f} | {c['ratio']:.4f} | "
              f"{c['maxGap']:.1f} | {c['pGap']:.6f} |" for c in comp_rows], "",
            f"Estimated missing readings: **{missing_total}**.", "",
            "## Assertions", "", "| ID | Check | Expected | Actual | Result |", "|---|---|---|---|---|",
            *[f"| {a['id']} | {a['description']} | `{a['expected']}` | `{a['actual']}` | "
              f"{'PASS' if a['passed'] else 'FAIL'} |" for a in ASSERTIONS], "",
            f"**{passed}/{len(ASSERTIONS)} assertions passed.**", "",
            "The completeness probability is a simplified exponential gap-tail estimate using the run's",
            "configured cadence; it is not a reproduction of the BISE/Prophet model.",
        ]
        (EVIDENCE / "RESULTS.md").write_text("\n".join(md) + "\n", encoding="utf-8")

        print(f"\n{passed}/{len(ASSERTIONS)} assertions passed")

        # leave the historian as it was: the evidence captures the result, the
        # lab does not accumulate measurements into the published inventory
        sqlcmd(f"EXEC telemetry.usp_ResetQualityRun @RunId = {run_id};")
        print("  lab run reset; portfolio readings unchanged")
        return 0 if passed == len(ASSERTIONS) else 1
    finally:
        if sim is not None:
            sim.terminate()


if __name__ == "__main__":
    raise SystemExit(main())
