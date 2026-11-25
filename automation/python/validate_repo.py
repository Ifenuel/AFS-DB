#!/usr/bin/env python3

"""AFS-DBA-001 repository validation.



Read-only checks that can run locally and in CI without a database:

  * required files and directories exist;

  * JSON files parse;

  * Python files compile;

  * SQL files have the project header and are non-empty;

  * Markdown relative links resolve (external links are not fetched);

  * obvious committed secret patterns are absent;

  * no populated .env file is present.



Exit code: 0 on success, 1 on validation failure, 2 on an unexpected error.

"""

from __future__ import annotations



import json

import re

import sys

from pathlib import Path



ROOT = Path(__file__).resolve().parents[2]



REQUIRED_FILES = [

    "README.md",









    ".gitignore",

    ".gitattributes",

    ".env.example",














    "sql-server/databases/01_create_databases.sql",

    "sql-server/schemas/02_create_schemas.sql",

    "sql-server/tables/03_create_tables_core.sql",

    "sql-server/tables/03_create_tables_payments.sql",

    "sql-server/tables/03_create_tables_customer_service.sql",

    "sql-server/tables/03_create_tables_audit.sql",

    "sql-server/tables/03_create_tables_reporting.sql",

    "sql-server/tables/03_create_tables_fraud.sql",

    "sql-server/tables/04_seed_reference.sql",

    "sql-server/procedures/05_transfer_engine.sql",

    "sql-server/procedures/05_payment_procedures.sql",

    "sql-server/security/08_create_logins.sql",

    "sql-server/security/09_create_users_roles.sql",

    "sql-server/tests/01_schema_tests.sql",

    "sql-server/tests/02_transfer_tests.sql",

    "sql-server/tests/03_security_tests.sql",

    "sql-server/tests/04_payment_tests.sql",

    "sql-server/installation/Deploy-AfsSqlServer.ps1",

    "automation/powershell/Test-AfsEnvironment.ps1",

    "automation/python/generate_data.py",

]



REQUIRED_DIRS = [






    "sql-server",

    "mysql",

    "oracle",

    "automation",


    "evidence",


    ".github/workflows",]



SECRET_PATTERNS = [

    re.compile(r"(?i)\bpassword\s*[:=]\s*['\"](?!\$\(|\$env:|__|changeme|example|<)[^'\"]{6,}['\"]"),

    re.compile(r"(?i)\b(pwd|secret|token|api[_-]?key)\s*[:=]\s*['\"](?!\$\(|\$env:|__|example|<)[^'\"]{8,}['\"]"),

]



SKIP_SECRET_SCAN = {

    ".env.example",

    "README.md",

    "docs/OVERVIEW.md",

    "docs/PROJECT_CHARTER.md",

    "docs/REQUIREMENTS.md",

    "docs/PROJECT_TRACKER.md",

    "docs/AFS_MASTER_PRIVATE_GUIDE.md",

    "docs/START-HERE.md",

}





def fail(errors: list[str], message: str) -> None:

    errors.append(message)





def check_required(errors: list[str]) -> None:

    for relative in REQUIRED_FILES:

        if not (ROOT / relative).is_file():

            fail(errors, f"missing required file: {relative}")

    for relative in REQUIRED_DIRS:

        if not (ROOT / relative).is_dir():

            fail(errors, f"missing required directory: {relative}")





def check_json(errors: list[str], checked: list[str]) -> None:

    for path in ROOT.rglob("*.json"):

        if ".git" in path.parts or "node_modules" in path.parts:

            continue

        try:

            with path.open("r", encoding="utf-8") as handle:

                json.load(handle)

            checked.append(str(path.relative_to(ROOT)))

        except Exception as exc:  # noqa: BLE001 - report the actual parser error

            fail(errors, f"invalid JSON {path.relative_to(ROOT)}: {exc}")





def check_python(errors: list[str], checked: list[str]) -> None:

    for path in (ROOT / "automation" / "python").glob("*.py"):

        try:

            compile(path.read_text(encoding="utf-8"), str(path), "exec")

            checked.append(str(path.relative_to(ROOT)))

        except SyntaxError as exc:

            fail(errors, f"Python syntax error {path.relative_to(ROOT)}: {exc}")





def check_sql(errors: list[str], checked: list[str]) -> None:

    sql_files = sorted((ROOT / "sql-server").rglob("*.sql"))

    if len(sql_files) < 10:

        fail(errors, f"expected at least 10 SQL files, found {len(sql_files)}")

    for path in sql_files:

        text = path.read_text(encoding="utf-8")

        if not text.strip():

            fail(errors, f"empty SQL file: {path.relative_to(ROOT)}")

            continue

        if "AFS-DBA-001" not in text[:800]:

            fail(errors, f"SQL file missing AFS-DBA-001 header: {path.relative_to(ROOT)}")

        if "\x00" in text:

            fail(errors, f"SQL file contains a NUL byte: {path.relative_to(ROOT)}")

        checked.append(str(path.relative_to(ROOT)))





LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")

SKIP_SCHEMES = ("http://", "https://", "mailto:", "#")





def check_markdown_links(errors: list[str], checked: list[str]) -> None:

    """Check the Markdown that is actually published, not local ignored notes."""

    import subprocess



    tracked = subprocess.run(["git", "ls-files", "-z", "*.md"], cwd=ROOT,

                             capture_output=True).stdout.decode("utf-8")

    paths = [ROOT / name for name in tracked.split(chr(0)) if name] or list(ROOT.rglob("*.md"))

    for path in paths:

        if any(part.startswith((".", "_")) or part == "node_modules" for part in path.relative_to(ROOT).parts):

            continue

        text = path.read_text(encoding="utf-8")

        for target in LINK_RE.findall(text):

            if target.startswith(SKIP_SCHEMES):

                continue

            target = target.split("#", 1)[0].strip()

            if not target:

                continue

            if target.startswith("/"):

                fail(errors, f"absolute local link in {path.relative_to(ROOT)}: {target}")

                continue

            resolved = (path.parent / target).resolve()

            if not resolved.exists():

                fail(errors, f"broken link in {path.relative_to(ROOT)}: {target}")

        checked.append(str(path.relative_to(ROOT)))





def check_secrets(errors: list[str], checked: list[str]) -> None:

    for path in ROOT.rglob("*"):

        if not path.is_file():

            continue

        if any(part.startswith((".", "_")) or part in {"node_modules", "test-data"} for part in path.relative_to(ROOT).parts):

            continue

        if path.name.startswith(".env") and path.name != ".env.example":

            fail(errors, f"populated environment file present: {path.relative_to(ROOT)}")

            continue

        if path.suffix.lower() not in {".py", ".ps1", ".sql", ".json", ".yml", ".yaml", ".md"}:

            continue

        relative = str(path.relative_to(ROOT))

        if relative in SKIP_SECRET_SCAN:

            continue

        try:

            text = path.read_text(encoding="utf-8")

        except UnicodeDecodeError:

            continue

        for pattern in SECRET_PATTERNS:

            match = pattern.search(text)

            if match:

                fail(errors, f"possible committed secret in {relative}: {match.group(0)[:60]}")

        checked.append(relative)





def main() -> int:

    errors: list[str] = []

    checked: dict[str, list[str]] = {}



    check_required(errors)

    for name, function in (

        ("json", check_json),

        ("python", check_python),

        ("sql", check_sql),

        ("markdown", check_markdown_links),

        ("secrets", check_secrets),

    ):

        bucket: list[str] = []

        function(errors, bucket)

        checked[name] = bucket



    print("AFS repository validation")

    print(f"Root: {ROOT}")

    for name, paths in checked.items():

        print(f"  {name}: {len(paths)} file(s) checked")



    if errors:

        print(f"\nFAILED with {len(errors)} issue(s):")

        for error in errors:

            print(f"  - {error}")

        return 1



    print("\nPASS: structure, JSON, Python syntax, SQL headers, links and secret scan.")

    return 0





if __name__ == "__main__":

    try:

        raise SystemExit(main())

    except SystemExit:

        raise

    except Exception as exc:  # noqa: BLE001

        print(f"Unexpected validation error: {exc}", file=sys.stderr)

        raise SystemExit(2)

