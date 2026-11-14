#!/usr/bin/env python3
"""Regression checks for the Windows source archive and extracted tree."""
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import package_windows_source as package  # noqa: E402


# The archive is a runnable source tree: `frantastic.cmd test` runs
# `pytest frontend/tests` from it.  test_app.py and test_lab.py import fakedb.py
# and use conftest.py's fixtures, so these are named explicitly; the directory
# comparison below also catches test files added later.
FRONTEND_TEST_FILES = {
    "frontend/tests/conftest.py", "frontend/tests/fakedb.py",
    "frontend/tests/test_admin_bootstrap.py", "frontend/tests/test_app.py",
    "frontend/tests/test_fakedb.py", "frontend/tests/test_lab.py",
    "frontend/tests/test_seed.py", "frontend/tests/browser/test_lab_browser.py",
}
PYTEST_MODULES = ("pytest", "flask", "pymysql", "dotenv", "werkzeug")


def assert_frontend_tests_complete(names: list[str]) -> None:
    """Every frontend test file of the working tree is in the archive."""
    on_disk = {path.relative_to(ROOT).as_posix() for path in (ROOT / "frontend/tests").rglob("*")
               if path.is_file() and not package.is_excluded(path.relative_to(ROOT).as_posix())}
    missing = sorted(on_disk.union(FRONTEND_TEST_FILES).difference(names))
    assert not missing, "archive omitted frontend test files: " + ", ".join(missing)


def collect_extracted_frontend_tests(extracted: pathlib.Path) -> str:
    """Collects (does not run) the extracted frontend suite; a missing helper module fails here."""
    unavailable = [name for name in PYTEST_MODULES if importlib.util.find_spec(name) is None]
    if unavailable:
        return "frontend test collection not checked (%s not installed for this interpreter)" % ", ".join(unavailable)
    env = {key: value for key, value in os.environ.items() if key != "RUN_DB_TESTS"}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    collected = subprocess.run([sys.executable, "-m", "pytest", "--collect-only", "-q"],
                               cwd=extracted / "frontend", env=env, text=True, capture_output=True)
    assert collected.returncode == 0, \
        "extracted frontend tests cannot be collected:\n" + collected.stdout + collected.stderr
    for name in sorted(FRONTEND_TEST_FILES):
        if pathlib.PurePosixPath(name).name.startswith("test_") and "/browser/" not in name:
            assert name.replace("frontend/", "", 1) + "::" in collected.stdout, \
                "no test collected from " + name
    return "frontend tests collected from the extracted tree"


def assert_archive_files(names: list[str]) -> None:
    required = {
        "README.md", ".env.example", "examples/README.md", package.REQUIRED_JSONL,
        "frantastic.ps1", "scripts/windows_compose_url.ps1",
        "tests/windows/test_launcher_url.ps1", "tests/test_source_distribution.py",
        "scripts/windows_launcher.ps1", "scripts/mariadb_admin_auth.sh",
        "tests/windows/test_launcher_hardening.ps1", "tests/shell/test_admin_auth.sh",
        "tests/windows/test_launcher_end_to_end.ps1",
        "frontend/pytest.ini", "frontend/requirements-dev.txt", "scripts/run_test_suites.sh",
    }
    required.update(FRONTEND_TEST_FILES)
    missing = required.difference(names)
    assert not missing, "archive omitted required files: " + ", ".join(sorted(missing))
    assert not any(pathlib.PurePosixPath(name).name == ".env" or
                   (pathlib.PurePosixPath(name).name.startswith(".env.") and name != ".env.example")
                   for name in names)
    assert not any(pathlib.PurePosixPath(name).name == ".admin-credentials" or
                   pathlib.PurePosixPath(name).name.startswith(".admin-credentials.") for name in names)
    assert not any(part in package.EXCLUDED_PARTS or part.startswith(".venv")
                   for name in names for part in pathlib.PurePosixPath(name).parts)
    assert not any(pathlib.PurePosixPath(name).suffix.lower() in package.EXCLUDED_SUFFIXES for name in names)
    assert not any(name.lower().endswith(".sql.gz") for name in names)
    assert not any(pathlib.PurePosixPath(name).suffix.lower() == ".jsonl" and
                   name != package.REQUIRED_JSONL for name in names)


def main() -> int:
    assert not package.is_excluded(package.REQUIRED_JSONL)
    assert package.is_excluded("docs/evidence/local-run.jsonl")
    assert package.is_excluded(".env") and package.is_excluded(".admin-credentials")
    assert package.is_excluded(".agents/skills/private.md")
    dockerignore = (ROOT / ".dockerignore").read_text(encoding="utf-8").splitlines()
    assert "*.jsonl" in dockerignore and "!" + package.REQUIRED_JSONL in dockerignore
    assert dockerignore.index("!" + package.REQUIRED_JSONL) > dockerignore.index("*.jsonl"), \
        "Docker context must re-include the documented sample after excluding generated JSONL logs"

    artifact = ROOT / package.REQUIRED_JSONL
    lines = artifact.read_text(encoding="utf-8").splitlines()
    records = [json.loads(line) for line in lines if line.strip()]
    assert records and all(isinstance(record, dict) and isinstance(record.get("event"), str)
                           for record in records), "sample evidence must be nonempty JSONL event objects"

    try:
        candidates = package.git_source_paths(ROOT)
    except (subprocess.CalledProcessError, FileNotFoundError):
        # Docker's test-runner build context intentionally excludes .git.
        # Enumerate that already filtered source tree only for this temporary
        # regression archive; the maintainer-facing package command remains
        # restricted to tracked files plus its explicit safe extras.
        candidates = [path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*")
                      if path.is_file() and not path.is_symlink()]
    with tempfile.TemporaryDirectory(prefix="FRANtastic Windows Validation Test ") as temp:
        temp_root = pathlib.Path(temp)
        archive_path = temp_root / "working tree source.zip"
        package.create_archive(ROOT, archive_path, candidates)
        with zipfile.ZipFile(archive_path) as archive:
            assert archive.testzip() is None, "archive CRC validation failed"
            names = archive.namelist()
            assert_archive_files(names)
            assert_frontend_tests_complete(names)
            private_key_markers = (b"-----BEGIN " + b"PRIVATE KEY-----",
                                   b"-----BEGIN RSA " + b"PRIVATE KEY-----")
            for name in names:
                content = archive.read(name)
                assert all(marker not in content for marker in private_key_markers)
            bundled_records = [json.loads(line) for line in archive.read(package.REQUIRED_JSONL).decode("utf-8").splitlines() if line.strip()]
            assert bundled_records == records, "archive sample artifact differs from the working tree"
            archive.extractall(temp_root / "FRANtastic extracted source")

        extracted = temp_root / "FRANtastic extracted source"
        checker = extracted / "scripts/check_repo.py"
        passed = subprocess.run([sys.executable, str(checker)], cwd=extracted, text=True, capture_output=True)
        assert passed.returncode == 0, "extracted repository checks failed:\n" + passed.stdout + passed.stderr
        collection = collect_extracted_frontend_tests(extracted)

        (extracted / package.REQUIRED_JSONL).unlink()
        missing = subprocess.run([sys.executable, str(checker)], cwd=extracted, text=True, capture_output=True)
        assert missing.returncode != 0 and "broken link" in missing.stdout and "sample-records.jsonl" in missing.stdout, \
            "repository checks failed to detect a genuinely missing documented artifact"

    print("Source distribution checks passed: documented JSONL included, exclusions enforced, frontend test files complete, "
          "ZIP extracted in spaced path, " + collection + ", and checker detects removal of the sample.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
