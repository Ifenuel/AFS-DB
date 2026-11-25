#!/usr/bin/env python3
"""P-02 fault-emitting collector.

Reads the real Modbus registers exposed by tools/ot/plc_sim.py and stages each
sample with a deterministic fault profile. Nothing is invented at the database
layer: values are read over Modbus TCP, then transport/quality faults are
injected on the way to telemetry.Staging.

Fault profile (applied by sample index):
    17  drop the sample                      -> missing
    23  re-send the previous timestamp       -> duplicate
    29  timestamp 8 s in the past            -> late arrival
    31  timestamp 3 s before the previous    -> out-of-order
    37  pressure reported in kPa             -> unit mismatch accepted after conversion
    41  pressure multiplied by 4             -> spike, quarantined as out of range
    43  pressure value NULL                  -> corrupt frame, quarantined
    47  same timestamp from gateway-b +0.5   -> conflicting source
    60+ slow drift added to pressure         -> sensor drift

Usage:
    python tools/ot/fault_collector.py --port 15020 --seconds 120
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SQLCMD = (
    os.environ.get("SQLCMD")
    or r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"
    or shutil.which("sqlcmd")
)

TAGS = [
    ("WELLHEAD_PRESS", 0, "bar"),
    ("FLOW_RATE", 1, "m3/h"),
    ("SEP_TEMP", 2, "C"),
]


def read_registers(host: str, port: int, start: int, count: int, timeout: float = 3.0) -> list[int]:
    """Modbus TCP function 3 (read holding registers)."""
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        request = struct.pack(">HHHB", 1, 0, 6, 1) + struct.pack(">BHH", 3, start, count)
        sock.sendall(request)
        header = sock.recv(7)
        if len(header) < 7:
            raise RuntimeError("short Modbus header")
        _tx, _proto, length, _unit = struct.unpack(">HHHB", header)
        body = b""
        while len(body) < length - 1:
            chunk = sock.recv(length - 1 - len(body))
            if not chunk:
                break
            body += chunk
        if not body or body[0] != 3:
            raise RuntimeError(f"unexpected Modbus response: {body[:4]!r}")
        byte_count = body[1]
        return list(struct.unpack(">" + "H" * (byte_count // 2), body[2:2 + byte_count]))


def sqlcmd(sql: str, db: str = "AFS_Archive") -> str:
    fd, name = tempfile.mkstemp(suffix=".sql", text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(sql)
    try:
        proc = subprocess.run(
            [SQLCMD, "-E", "-C", "-S", ".", "-d", db, "-b", "-I",
             "-h", "-1", "-W", "-s", "|", "-f", "65001", "-i", name],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    finally:
        os.unlink(name)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr or proc.stdout)
    return proc.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=15020)
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--interval-ms", type=int, default=1000)
    ap.add_argument("--run-label", default="P-02 fault run")
    args = ap.parse_args()

    run_id = sqlcmd(f"""
SET NOCOUNT ON;
INSERT INTO telemetry.CollectorRun (StartedAt, EndedAt, IntervalMs, ReadingsWritten, GapsDetected, Notes)
VALUES (SYSUTCDATETIME(), NULL, {args.interval_ms}, 0, 0, N'{args.run_label}');
SELECT CAST(SCOPE_IDENTITY() AS varchar(12));
""")
    run_id = int(run_id.splitlines()[-1].strip())

    started = datetime.now(timezone.utc).replace(microsecond=0)
    tick_start = time.perf_counter()
    rows: list[tuple] = []
    dropped = duplicates = late = out_of_order = unit_errors = spikes = corrupt = conflicts = 0

    for i in range(args.seconds):
        observed = started - timedelta(seconds=args.seconds - i)
        try:
            regs = read_registers(args.host, args.port, 0, 3)
        except OSError:
            continue  # plant unreachable: the gap is the observation

        values = {
            "WELLHEAD_PRESS": regs[0] / 100.0,
            "FLOW_RATE": regs[1] / 100.0,
            "SEP_TEMP": regs[2] / 100.0,
        }
        # slow sensor drift after 60 samples
        if i > 60:
            values["WELLHEAD_PRESS"] += 0.02 * (i - 60)

        if i % 17 == 0 and i > 0:
            dropped += 1
            continue

        for tag, _reg, unit in TAGS:
            value = values[tag]
            raw_unit = unit
            source = "plc-a"
            stamp = observed

            if tag == "WELLHEAD_PRESS":
                if i % 37 == 0 and i > 0:
                    value, raw_unit, unit_errors = value * 100.0, "kPa", unit_errors + 1
                if i % 41 == 0 and i > 0:
                    value, spikes = value * 4.0, spikes + 1
                if i % 43 == 0 and i > 0:
                    value, corrupt = None, corrupt + 1

            if i % 31 == 0 and i > 0:
                stamp, out_of_order = observed - timedelta(seconds=3), out_of_order + 1
            elif i % 29 == 0 and i > 0:
                stamp, late = observed - timedelta(seconds=8), late + 1

            rows.append((run_id, tag, source, stamp, observed, value, raw_unit, f"run={run_id} i={i}"))

            if i % 23 == 0 and i > 0:
                prev = observed - timedelta(seconds=1)
                rows.append((run_id, tag, source, prev, observed, value, raw_unit, "duplicate resend"))
                duplicates += 1

            if tag == "WELLHEAD_PRESS" and i % 47 == 0 and i > 0:
                rows.append((run_id, tag, "gateway-b", observed, observed, value + 0.5, raw_unit,
                             "conflicting source"))
                conflicts += 1

        # real 1 Hz pacing: a 90-second run must actually take 90 seconds
        target = (i + 1) * args.interval_ms / 1000.0
        remaining = target - (time.perf_counter() - tick_start)
        if remaining > 0:
            time.sleep(remaining)

    # stage in chunks
    def lit(v):
        if v is None:
            return "NULL"
        if isinstance(v, str):
            return "N'" + v.replace("'", "''") + "'"
        if isinstance(v, datetime):
            return "'" + v.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "'"
        return repr(v)

    for start in range(0, len(rows), 150):
        chunk = rows[start:start + 150]
        values_sql = ",\n".join(
            f"({r[0]}, N'{r[1]}', N'{r[2]}', {lit(r[3])}, {lit(r[4])}, {lit(r[5])}, N'{r[6]}', N'{r[7]}')"
            for r in chunk)
        sqlcmd(f"""
SET NOCOUNT ON;
INSERT INTO telemetry.Staging (RunId, TagCode, SourceId, ObservedAt, ReceivedAt, RawValue, RawUnit, Payload)
VALUES
{values_sql};
""")

    sqlcmd(f"""
SET NOCOUNT ON;
UPDATE telemetry.CollectorRun
   SET EndedAt = SYSUTCDATETIME(),
       ReadingsWritten = (SELECT COUNT(*) FROM telemetry.Staging WHERE RunId = {run_id}),
       GapsDetected = {dropped}
 WHERE RunId = {run_id};
""")

    print(json.dumps({
        "runId": run_id,
        "staged": len(rows),
        "dropped": dropped,
        "duplicates": duplicates,
        "late": late,
        "outOfOrder": out_of_order,
        "unitErrors": unit_errors,
        "spikes": spikes,
        "corrupt": corrupt,
        "conflictingSources": conflicts,
        "seconds": args.seconds,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
