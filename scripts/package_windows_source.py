#!/usr/bin/env python3
"""Build the source ZIP used for Windows validation from this working tree.

Tracked files come from the local Git index; the explicit extras below are the
intentional remediation files that are not committed yet. Credentials, local
state, caches, prior archives and generated JSONL logs are excluded. The
documented sample-records fixture is deliberately retained.

The archive is a runnable source tree, tests included: `frantastic.cmd test`
builds its test-runner image from the extracted tree and runs
`pytest frontend/tests` there (scripts/run_test_suites.sh).  Every file under
frontend/tests must therefore be packaged: test_app.py and test_lab.py import
fakedb.py and use the fixtures of conftest.py, so an archive without them
cannot even collect its tests.  tests/test_source_distribution.py enforces it.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import zipfile


EXTRA_SOURCE_FILES = (
    "database/migrations/004_remove_shared_admin.sql",
    "database/migrations/005_local_admin_bootstrap_state.sql",
    "database/migrations/006_cancelled_loan_status.sql",
    "frantastic.cmd",
    "frantastic.ps1",
    "frontend/bootstrap_admin.py",
    "frontend/tests/conftest.py",
    "frontend/tests/fakedb.py",
    "frontend/tests/test_admin_bootstrap.py",
    "frontend/tests/test_fakedb.py",
    "frontend/tests/test_seed.py",
    "plugin/src/gap_accounting.h",
    "plugin/src/runtime_config.h",
    "plugin/tests/test_gap_accounting.cpp",
    "plugin/tests/test_runtime_config.cpp",
    "scripts/bootstrap_admin.sh",
    "scripts/mariadb_admin_auth.sh",
    "scripts/provision_local_admin_db.sh",
    "scripts/run_test_suites.sh",
    "scripts/windows_security.ps1",
    "scripts/windows_compose_url.ps1",
    "scripts/windows_launcher.ps1",
    "scripts/package_windows_source.py",
    "docs/evidence/windows-docker-desktop-2026-11-09/README.md",
    "tests/database/test_legacy_admin_migration.sh",
    "tests/database/test_cancelled_loan_migration.sh",
    "tests/database/test_audit_triggers.sh",
    "tests/database/test_app_account_grants.sh",
    "tests/shell/test_database_setup.sh",
    "tests/windows/test_local_file_acl.ps1",
    "tests/windows/test_launcher_url.ps1",
    "tests/windows/test_launcher_hardening.ps1",
    "tests/windows/test_launcher_end_to_end.ps1",
    "tests/shell/test_admin_auth.sh",
    "tests/test_source_distribution.py",
)

REQUIRED_JSONL = "docs/evidence/sample-records.jsonl"
EXCLUDED_PARTS = {
    ".git", ".agents", ".aws", "windows-test-transfer", "secrets", "credentials",
    "build", "cmake-build-debug", "cmake-build-release", "__pycache__",
    ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".venv",
    ".venv-browser", "venv", "env", "node_modules", "htmlcov", "tmp", "temp",
    "mariadb-data", "mysql-data",
}
EXCLUDED_SUFFIXES = {
    ".pem", ".key", ".p12", ".pfx", ".sqlite", ".sqlite3", ".db", ".dump",
    ".sql.gz", ".log", ".tmp", ".bak", ".zip", ".pyc", ".pyo", ".o", ".obj",
    ".a", ".lib", ".so", ".dll", ".dylib", ".exe", ".pdb", ".ilk", ".pch",
}


def is_excluded(name: str) -> bool:
    path = pathlib.PurePosixPath(name)
    if any(part in EXCLUDED_PARTS or part.startswith(".venv") for part in path.parts):
        return True
    if path.name == ".env" or (path.name.startswith(".env.") and name != ".env.example"):
        return True
    if path.name == ".admin-credentials" or path.name.startswith(".admin-credentials."):
        return True
    if (path.suffix.lower() in EXCLUDED_SUFFIXES or name.lower().endswith(".sql.gz")
            or path.name == ".coverage"):
        return True
    if path.suffix.lower() == ".jsonl" and name != REQUIRED_JSONL:
        return True
    return False


def git_source_paths(root: pathlib.Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "-z"], cwd=root,
        check=True, stdout=subprocess.PIPE,
    )
    tracked = [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]
    return sorted(set(tracked).union(EXTRA_SOURCE_FILES))


def select_source_files(root: pathlib.Path, candidates: list[str]) -> list[str]:
    selected = []
    missing = []
    for name in sorted(set(candidates)):
        if is_excluded(name):
            continue
        path = root / pathlib.PurePosixPath(name)
        if not path.exists() or not path.is_file():
            missing.append(name)
            continue
        if path.is_symlink():
            raise ValueError("Refusing to package symbolic link: " + name)
        selected.append(name)
    if missing:
        raise FileNotFoundError("Required source files are missing: " + ", ".join(missing))
    if REQUIRED_JSONL not in selected:
        raise FileNotFoundError("Required documented sample artifact is missing: " + REQUIRED_JSONL)
    return selected


def create_archive(root: pathlib.Path, destination: pathlib.Path, candidates: list[str]) -> list[str]:
    files = select_source_files(root, candidates)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in files:
            archive.write(root / pathlib.PurePosixPath(name), arcname=name)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=pathlib.Path,
        default=pathlib.Path("windows-test-transfer/FRANtastic-Windows-Validation-Fix.zip"),
    )
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    destination = args.output if args.output.is_absolute() else root / args.output
    files = create_archive(root, destination, git_source_paths(root))
    print("Created %s (%d files, %d bytes)" % (destination, len(files), destination.stat().st_size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
