#!/usr/bin/env python3
"""Generate synthetic AFS data as CSV.

No real people, accounts or payments are represented. Names are drawn from small
fictional pools, emails use the reserved .invalid domain, and identifiers are
synthetic. Output is deliberately streamed to keep memory bounded.

Profiles:
  smoke  - quick verification (default)
  dev    - moderate local development data
  target - stated portfolio target; only run after checking disk/time

Example:
  python automation/python/generate_data.py --profile smoke --output test-data/generated/smoke
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import shutil
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

PROFILES = {
    "smoke": {
        "customers": 100,
        "accounts": 200,
        "transfers": 1_000,
        "payments": 300,
        "cases": 50,
        "audit_events": 500,
    },
    "dev": {
        "customers": 5_000,
        "accounts": 10_000,
        "transfers": 50_000,
        "payments": 15_000,
        "cases": 2_500,
        "audit_events": 25_000,
    },
    "target": {
        "customers": 100_000,
        "accounts": 200_000,
        "transfers": 1_000_000,
        "payments": 300_000,
        "cases": 50_000,
        "audit_events": 500_000,
    },
}

FIRST_NAMES = [
    "Amina", "Daniel", "Chiara", "Kwame", "Lerato", "Mateo", "Nia", "Omar",
    "Priya", "Sofia", "Tariq", "Zanele", "Ethan", "Fatima", "Grace", "Hassan",
    "Isabel", "Jonas", "Kemi", "Lucas", "Maya", "Noah", "Olivia", "Ravi",
]
LAST_NAMES = [
    "Adeyemi", "Bennett", "Chen", "Diallo", "Evans", "Fischer", "Garcia",
    "Hughes", "Ibrahim", "Jensen", "Khan", "Lopez", "Mensah", "Nwosu",
    "Okafor", "Patel", "Quinn", "Rahman", "Silva", "Thompson", "Ueda",
    "Vargas", "Williams", "Yilmaz",
]
COUNTRIES = ["US", "GB", "CA", "DE", "FR", "NG", "ZA", "KE", "AU", "IN"]
COUNTRY_CURRENCY = {
    "US": "USD", "GB": "GBP", "CA": "CAD", "DE": "EUR", "FR": "EUR",
    "NG": "NGN", "ZA": "ZAR", "KE": "KES", "AU": "AUD", "IN": "INR",
}
ACCOUNT_TYPES = ["CHECKING", "SAVINGS", "BUSINESS_CHECKING", "BUSINESS_SAVINGS"]
ACCOUNT_STATUSES = ["ACTIVE"] * 94 + ["DORMANT"] * 3 + ["FROZEN"] * 2 + ["CLOSED"]
CASE_CATEGORIES = ["ACCOUNT_ACCESS", "PAYMENT_ISSUE", "FRAUD", "STATEMENT", "OTHER"]
CASE_PRIORITIES = ["LOW", "NORMAL", "NORMAL", "HIGH", "URGENT"]
CASE_STATUSES = ["OPEN", "IN_PROGRESS", "PENDING_CUSTOMER", "RESOLVED", "CLOSED"]
PAYMENT_METHODS = ["INTERNAL"] * 65 + ["ACH"] * 20 + ["WIRE"] * 10 + ["CARD"] * 5
PAYMENT_STATUSES = ["COMPLETED"] * 95 + ["PENDING"] * 3 + ["FAILED"] * 2
AUDIT_EVENTS = [
    "LOGIN_SUCCESS", "LOGIN_FAILURE", "TRANSFER_COMPLETED", "TRANSFER_FAILED",
    "PAYMENT_COMPLETED", "PAYMENT_FAILED", "PERMISSION_CHANGED", "BACKUP_COMPLETED",
    "JOB_FAILED", "FRAUD_ALERT_CREATED",
]

BASE_START = datetime(2025, 1, 1, tzinfo=timezone.utc)
BASE_END = datetime(2025, 12, 31, 23, 59, 59, tzinfo=timezone.utc)
CUSTOMER_START = datetime(2018, 1, 1, tzinfo=timezone.utc)
CUSTOMER_END = datetime(2022, 12, 31, tzinfo=timezone.utc)
ACCOUNT_START = datetime(2023, 1, 1, tzinfo=timezone.utc)
ACCOUNT_END = datetime(2024, 12, 31, tzinfo=timezone.utc)


def ts(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def money(value: Decimal | int | float) -> str:
    return f"{Decimal(value):.4f}"


def random_dt(rng: random.Random, start: datetime = BASE_START, end: datetime = BASE_END) -> datetime:
    seconds = int((end - start).total_seconds())
    return start + timedelta(seconds=rng.randint(0, max(seconds, 0)))


def make_uuid(rng: random.Random) -> uuid.UUID:
    return uuid.UUID(int=rng.getrandbits(128), version=4)


def estimate_required_gb(profile: dict[str, int]) -> float:
    # Rough conservative estimate: transfers + ledger + payments + audit.
    bytes_per_transfer = 450
    bytes_per_ledger = 220
    bytes_per_audit = 350
    total = (
        profile["transfers"] * (bytes_per_transfer + 2 * bytes_per_ledger)
        + profile["payments"] * 300
        + profile["audit_events"] * bytes_per_audit
        + profile["customers"] * 250
        + profile["accounts"] * 220
        + profile["cases"] * 400
    )
    return total / (1024**3)


def open_writer(path: Path, fieldnames: list[str]):
    handle = path.open("w", encoding="utf-8", newline="")
    writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    return handle, writer


def generate(profile_name: str, counts: dict[str, int], output: Path, seed: int, force: bool) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / "manifest.json"
    if manifest_path.exists() and not force:
        raise SystemExit(
            f"{output} already contains a generated dataset. Use --force to replace it."
        )

    required_gb = estimate_required_gb(counts)
    free_gb = shutil.disk_usage(output).free / (1024**3)
    if free_gb < required_gb + 2:
        raise SystemExit(
            f"Insufficient free space: need about {required_gb + 2:.1f} GB, "
            f"have {free_gb:.1f} GB. Choose a smaller profile or free space."
        )

    rng = random.Random(seed)
    started = time.time()
    actual = {
        "customers": 0, "accounts": 0, "transfers": 0, "ledger_entries": 0,
        "payments": 0, "cases": 0, "audit_events": 0,
    }

    # Customers are kept in memory because accounts reference them. This is
    # small compared with the transaction stream (100k target).
    customers: list[dict] = []
    customer_handle, customer_writer = open_writer(
        output / "customers.csv",
        ["CustomerNumber", "FirstName", "LastName", "DateOfBirth", "Email",
         "Phone", "CustomerStatus", "RiskRating", "CreatedAt", "UpdatedAt"],
    )
    with customer_handle:
        for index in range(1, counts["customers"] + 1):
            number = f"C{index:09d}"
            first = rng.choice(FIRST_NAMES)
            last = rng.choice(LAST_NAMES)
            country = rng.choice(COUNTRIES)
            created = random_dt(rng, CUSTOMER_START, CUSTOMER_END)
            row = {
                "CustomerNumber": number,
                "FirstName": first,
                "LastName": last,
                "DateOfBirth": f"{rng.randint(1950, 2003):04d}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}",
                "Email": f"{first.lower()}.{last.lower()}.{index}@example.invalid",
                "Phone": f"+1{rng.randint(2000000000, 9999999999)}",
                "CustomerStatus": "ACTIVE" if rng.random() > 0.03 else "DORMANT",
                "RiskRating": rng.choices(["LOW", "MEDIUM", "HIGH"], weights=[75, 20, 5])[0],
                "CreatedAt": ts(created),
                "UpdatedAt": ts(created),
            }
            customer_writer.writerow(row)
            customers.append({
                "number": number,
                "country": country,
                "currency": COUNTRY_CURRENCY[country],
                "created": created,
            })
            actual["customers"] += 1

    # Accounts. A customer may own several accounts; the requested account count
    # controls the generated total.
    accounts: list[dict] = []
    account_rows: list[dict] = []
    for index in range(1, counts["accounts"] + 1):
        customer = customers[(index - 1) % len(customers)]
        account_type = rng.choice(ACCOUNT_TYPES)
        status = rng.choice(ACCOUNT_STATUSES)
        opened = random_dt(rng, ACCOUNT_START, ACCOUNT_END)
        opening_balance = Decimal(rng.randint(0, 5_000_000)) / 100
        balance = opening_balance
        overdraft = Decimal(0) if account_type == "SAVINGS" else Decimal(rng.choice([0, 0, 250, 500]))
        row = {
            "AccountNumber": f"ACC{index:09d}",
            "CustomerNumber": customer["number"],
            "AccountTypeCode": account_type,
            "AccountStatusCode": status,
            "CurrencyCode": customer["currency"],
            "Balance": money(balance),
            "OpeningBalance": money(opening_balance),
            "OverdraftLimit": money(overdraft),
            "PerTransferLimit": money(10000),
            "DailyTransferLimit": money(50000),
            "OpenedAt": ts(opened),
            "ClosedAt": ts(opened + timedelta(days=30)) if status == "CLOSED" else "",
            "UpdatedAt": ts(opened),
        }
        account_rows.append(row)
        accounts.append({
            "number": row["AccountNumber"],
            "customer": customer["number"],
            "currency": customer["currency"],
            "status": status,
            "balance": balance,
            "overdraft": overdraft,
            "type": account_type,
            "opened": opened,
            "row": row,
        })
        actual["accounts"] += 1

    active_by_currency: dict[str, list[int]] = {}
    for idx, account in enumerate(accounts):
        if account["status"] == "ACTIVE":
            active_by_currency.setdefault(account["currency"], []).append(idx)

    transfer_handle, transfer_writer = open_writer(
        output / "transfers.csv",
        ["TransferId", "RequestId", "FromAccountNumber", "ToAccountNumber", "Amount",
         "CurrencyCode", "Status", "Description", "CorrelationId", "CreatedAt", "CompletedAt"],
    )
    ledger_handle, ledger_writer = open_writer(
        output / "ledger_entries.csv",
        ["TransferId", "AccountNumber", "EntryType", "Amount", "BalanceAfter",
         "CurrencyCode", "OccurredAt", "Description"],
    )
    payment_candidates: list[dict] = []

    with transfer_handle, ledger_handle:
        for index in range(1, counts["transfers"] + 1):
            currencies = [c for c, members in active_by_currency.items() if len(members) >= 2]
            if not currencies:
                break
            currency = rng.choice(currencies)
            members = active_by_currency[currency]
            from_idx, to_idx = rng.sample(members, 2)
            sender = accounts[from_idx]
            recipient = accounts[to_idx]
            amount = Decimal(rng.randint(100, 50000)) / 100
            if sender["balance"] - amount < -sender["overdraft"]:
                continue
            transfer_id = make_uuid(rng)
            request_id = make_uuid(rng)
            occurred = random_dt(rng)
            description = f"Synthetic transfer {index}"
            sender_before = sender["balance"]
            sender["balance"] -= amount
            recipient["balance"] += amount
            sender["row"]["Balance"] = money(sender["balance"])
            sender["row"]["UpdatedAt"] = ts(occurred)
            recipient["row"]["Balance"] = money(recipient["balance"])
            recipient["row"]["UpdatedAt"] = ts(occurred)
            transfer_writer.writerow({
                "TransferId": str(transfer_id),
                "RequestId": str(request_id),
                "FromAccountNumber": sender["number"],
                "ToAccountNumber": recipient["number"],
                "Amount": money(amount),
                "CurrencyCode": currency,
                "Status": "COMPLETED",
                "Description": description,
                "CorrelationId": str(make_uuid(rng)),
                "CreatedAt": ts(occurred),
                "CompletedAt": ts(occurred),
            })
            ledger_writer.writerow({
                "TransferId": str(transfer_id),
                "AccountNumber": sender["number"],
                "EntryType": "DEBIT",
                "Amount": money(-amount),
                "BalanceAfter": money(sender["balance"]),
                "CurrencyCode": currency,
                "OccurredAt": ts(occurred),
                "Description": description,
            })
            ledger_writer.writerow({
                "TransferId": str(transfer_id),
                "AccountNumber": recipient["number"],
                "EntryType": "CREDIT",
                "Amount": money(amount),
                "BalanceAfter": money(recipient["balance"]),
                "CurrencyCode": currency,
                "OccurredAt": ts(occurred),
                "Description": description,
            })
            actual["transfers"] += 1
            actual["ledger_entries"] += 2
            if len(payment_candidates) < counts["payments"] and index <= counts["payments"]:
                payment_candidates.append({
                    "transfer_id": transfer_id,
                    "from": sender["number"],
                    "to": recipient["number"],
                    "amount": amount,
                    "currency": currency,
                    "occurred": occurred,
                    "sender_before": sender_before,
                })
            if index % 100_000 == 0:
                print(f"  generated {index:,} transfers...", flush=True)

    # Payments reference the first transfers for completed instructions; pending
    # and failed payments deliberately have no transfer.
    payment_handle, payment_writer = open_writer(
        output / "payments.csv",
        ["PaymentReference", "RequestId", "DebitAccountNumber", "BeneficiaryAccountNumber",
         "BeneficiaryName", "BeneficiaryAccountNumberValue", "Amount", "CurrencyCode",
         "PaymentMethodCode", "PaymentStatusCode", "TransferId", "CreatedAt", "ProcessedAt"],
    )
    with payment_handle:
        for index in range(1, counts["payments"] + 1):
            candidate = payment_candidates[(index - 1) % len(payment_candidates)] if payment_candidates else None
            status = rng.choice(PAYMENT_STATUSES)
            if candidate is None:
                continue
            created = candidate["occurred"] + timedelta(seconds=rng.randint(0, 300))
            reference = "PAY" + created.strftime("%Y%m%d") + f"{index:08d}"
            row = {
                "PaymentReference": reference[:24],
                "RequestId": str(make_uuid(rng)),
                "DebitAccountNumber": candidate["from"],
                "BeneficiaryAccountNumber": candidate["to"],
                "BeneficiaryName": "Synthetic Beneficiary " + str(index),
                "BeneficiaryAccountNumberValue": candidate["to"],
                "Amount": money(candidate["amount"]),
                "CurrencyCode": candidate["currency"],
                "PaymentMethodCode": rng.choice(PAYMENT_METHODS),
                "PaymentStatusCode": status,
                "TransferId": str(candidate["transfer_id"]) if status == "COMPLETED" else "",
                "CreatedAt": ts(created),
                "ProcessedAt": ts(created + timedelta(seconds=rng.randint(1, 60))) if status != "PENDING" else "",
            }
            payment_writer.writerow(row)
            actual["payments"] += 1

    case_handle, case_writer = open_writer(
        output / "support_cases.csv",
        ["CaseNumber", "CustomerNumber", "CategoryCode", "Priority", "Status",
         "Subject", "Description", "OpenedAt", "ClosedAt", "AssignedTo"],
    )
    with case_handle:
        for index in range(1, counts["cases"] + 1):
            customer = customers[rng.randrange(len(customers))]
            opened = random_dt(rng)
            status = rng.choice(CASE_STATUSES)
            closed = opened + timedelta(hours=rng.randint(1, 240)) if status in {"RESOLVED", "CLOSED"} else None
            case_writer.writerow({
                "CaseNumber": f"CS{index:08d}",
                "CustomerNumber": customer["number"],
                "CategoryCode": rng.choice(CASE_CATEGORIES),
                "Priority": rng.choice(CASE_PRIORITIES),
                "Status": status,
                "Subject": f"Synthetic support case {index}",
                "Description": "Synthetic case for DBA lab testing; no real customer.",
                "OpenedAt": ts(opened),
                "ClosedAt": ts(closed) if closed else "",
                "AssignedTo": f"agent{rng.randint(1, 50):03d}",
            })
            actual["cases"] += 1

    audit_handle, audit_writer = open_writer(
        output / "audit_events.csv",
        ["EventType", "EntityType", "EntityId", "Actor", "CorrelationId", "EventData", "CreatedAt"],
    )
    with audit_handle:
        for index in range(1, counts["audit_events"] + 1):
            event_type = rng.choice(AUDIT_EVENTS)
            entity_type = "Transfer" if "TRANSFER" in event_type else "Payment" if "PAYMENT" in event_type else "Security"
            audit_writer.writerow({
                "EventType": event_type,
                "EntityType": entity_type,
                "EntityId": str(make_uuid(rng)),
                "Actor": f"synthetic_actor_{rng.randint(1, 100):03d}",
                "CorrelationId": str(make_uuid(rng)),
                "EventData": json.dumps({"synthetic": True, "sequence": index}, separators=(",", ":")),
                "CreatedAt": ts(random_dt(rng)),
            })
            actual["audit_events"] += 1

    account_handle, account_writer = open_writer(
        output / "accounts.csv",
        ["AccountNumber", "CustomerNumber", "AccountTypeCode", "AccountStatusCode",
         "CurrencyCode", "Balance", "OpeningBalance", "OverdraftLimit", "PerTransferLimit",
         "DailyTransferLimit", "OpenedAt", "ClosedAt", "UpdatedAt"],
    )
    with account_handle:
        for row in account_rows:
            account_writer.writerow(row)

    files = {}
    for path in sorted(output.glob("*.csv")):
        files[path.name] = {
            "bytes": path.stat().st_size,
            "megabytes": round(path.stat().st_size / (1024**2), 2),
        }

    elapsed = time.time() - started
    manifest = {
        "project": "AFS-DBA-001",
        "profile": profile_name,
        "seed": seed,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "requested": counts,
        "actual": actual,
        "elapsed_seconds": round(elapsed, 3),
        "files": files,
        "notes": [
            "All data is synthetic; emails use the reserved .invalid domain.",
            "Transfers and ledger entries are generated together with running balances.",
            "Account OpeningBalance is initial funding; Balance equals OpeningBalance + ledger sum.",
            "Completed payment rows reference generated transfers.",
            "This manifest is the authoritative record of the achieved volume.",
        ],
    }
    with manifest_path.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")

    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate synthetic AFS CSV data.")
    parser.add_argument("--profile", choices=sorted(PROFILES), default="smoke")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--seed", type=int, default=20261120)
    parser.add_argument("--force", action="store_true", help="replace an existing generated dataset")
    args = parser.parse_args()

    counts = dict(PROFILES[args.profile])
    output = args.output or (ROOT / "test-data" / "generated" / args.profile)
    manifest = generate(args.profile, counts, output, args.seed, args.force)
    print(json.dumps({
        "profile": manifest["profile"],
        "output": str(output),
        "actual": manifest["actual"],
        "elapsed_seconds": manifest["elapsed_seconds"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"Data generation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
