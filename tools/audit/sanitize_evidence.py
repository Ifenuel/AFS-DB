"""Create the public, sanitised copy of captured evidence.

The private originals in evidence/verify/live stay untouched. The website is
built from evidence/public, so a capture that contains a workstation path, a
Windows account, a certificate thumbprint or a process id is redacted before
it can reach a browser.

Redactions keep the technical meaning: engine versions, SQL error numbers,
object names, timestamps and measured values are preserved; identifiers that
describe the machine or the key material are replaced with a bracketed token.

Run: python tools/audit/sanitize_evidence.py
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "evidence" / "verify" / "live"
PUBLIC = ROOT / "evidence" / "public"

RULES: list[tuple[re.Pattern[str], str]] = [
    # Workspace and repository paths.
    (re.compile(r"C:\\Users\\[^\\\r\n]+\\\.config\\[^\\r\n]+\\local-projects\\[0-9a-fA-F-]{36}", re.I), "<workspace>"),
    (re.compile(r"C:\\Users\\[^\\\r\n]+", re.I), "<home>"),
    (re.compile(r"C:\\ProgramData\\AFS", re.I), "<backup-root>"),
    (re.compile(r"C:\\Keys\\AFS", re.I), "<custody-store>"),
    (re.compile(r"C:\\Backups\\certs", re.I), "<certificate-store>"),
    (re.compile(r"C:\\Backups", re.I), "<backup-store>"),
    (re.compile(r"C:\\AFS", re.I), "<afs-root>"),
    # Accounts and host names.
    (re.compile(r"ADEOLA\\ELITE X2", re.I), "<host>\\<user>"),
    (re.compile(r"\bELITE X2\b", re.I), "<user>"),
    (re.compile(r"\bAdeola\b", re.I), "<host>"),
    # Key material identifiers and file names.
    (re.compile(r"0x[0-9A-Fa-f]{32,64}"), "0x<redacted-thumbprint>"),
    (re.compile(r"[A-Za-z0-9_.-]+[_-]\d{14}\.(cer|pvk)\b"), r"<certificate>.\1"),
    (re.compile(r"AFS_BackupCert_[A-Za-z0-9_]+", re.I), "<certificate>"),
    (re.compile(r"[A-Za-z0-9_.-]+[_-]custody-\d{14}\.(cer|pvk)\b"), r"<certificate>.\1"),
    # Custody file names and passphrase metadata.
    (re.compile(r"[A-Za-z0-9_.-]*passphrase[A-Za-z0-9_.-]*", re.I), "<passphrase-file>"),
    (re.compile(r"\b\d{2}-character passphrase\b", re.I), "a passphrase"),
    # Process identifiers.
    (re.compile(r"\b(pid|PID)(\s*[:=]?\s*)\d{2,6}\b"), r"\1\2<redacted>"),
    (re.compile(r"\bpid\s+\d{2,6}\b"), "pid <redacted>"),
    # Internal workspace identifiers.
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I), "<uuid>"),
]

FORBIDDEN = [
    r"C:\\Users\\",
    r"C:\\ProgramData",
    r"C:\\Keys",
    r"C:\\Backups",
    r"C:\\AFS",
    r"ELITE X2",
    r"0x[0-9A-Fa-f]{32,}",
    r"local-projects",
]


def sanitise(text: str) -> tuple[str, int]:
    count = 0
    for pattern, replacement in RULES:
        text, n = pattern.subn(replacement, text)
        count += n
    return text, count


def main() -> int:
    PUBLIC.mkdir(parents=True, exist_ok=True)
    total_files = 0
    total_hits = 0
    problems = []

    for source in sorted(SOURCE.glob("*.txt")):
        text = source.read_text(encoding="utf-8-sig", errors="replace")
        clean, hits = sanitise(text.replace("\r\n", "\n"))
        (PUBLIC / source.name).write_text(clean, encoding="utf-8")
        total_files += 1
        total_hits += hits
        for pattern in FORBIDDEN:
            for match in re.finditer(pattern, clean, re.I):
                line = clean[:match.start()].count("\n") + 1
                problems.append(f"{source.name}:{line}: {match.group(0)}")

    # Any additional files shipped beside the captures are copied unchanged;
    # the private directory is never exposed directly.
    for extra in SOURCE.iterdir():
        if extra.is_file() and extra.suffix.lower() != ".txt":
            shutil.copy2(extra, PUBLIC / extra.name)

    print(f"sanitised {total_files} captures, {total_hits} substitutions -> {PUBLIC.relative_to(ROOT)}")
    if problems:
        print("REMAINING SENSITIVE MATCHES:")
        for problem in problems[:40]:
            print("  " + problem)
        return 1
    print("no workstation paths, accounts, thumbprints or workspace ids remain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
