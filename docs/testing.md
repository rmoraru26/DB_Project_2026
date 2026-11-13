# Test plan and results

Status legend: **PASS** = executed, passed; **WRITTEN** = implemented but not executed;
**N/A** = not covered, with the reason.

Executed rounds, all against MariaDB 13.0.2:

- 2026-10-25, plugin 1.0.0, native Windows 11 (official zip): `docs/evidence/*-windows.txt`.
- 2026-11-03, plugin 1.1.0, native Windows 11: `docs/evidence/windows-2026-11-03/`, including the
  reproduction of the failures seen in Docker and the original code as a baseline (files 04 and 05
  re-run with 1.1.1; see its `environment.txt`).
- **2026-11-03, plugin 1.1.1 (as validated in that run), CI:** `.github/workflows/ci.yml` on GitHub-hosted runners,
  Linux (`ubuntu-24.04`, the project's Docker images) and Windows (`windows-2022`, official zip):
  `docs/evidence/linux-ci-2026-11-03/`. Runs 1-3 found two plugin bugs that only Linux shows
  (experiments 18 and 19) and two set-up problems; run 8, on the delivered code, passed every job, and
  each result below was read in its log, not taken from the step status (every run and what it found:
  that directory's README).

Before this round a team member had run the Docker path once: the images built, but every login failed
with ERROR 1045 (`docs/docker.md`).

## Test suites

| Suite | What it proves | How to run | Status |
|---|---|---|---|
| Plugin unit tests (six Linux programs: `test_record_format`, `test_log_sink`, `test_automatic_errors`, `test_error_reporter`, `test_runtime_config`, `test_gap_accounting`; native Windows currently builds the first four) | JSON escaping and UTF-8 validation, digest masking, list parsing, timestamps, path validation, open/write failures, file permissions incl. `readable_by_all`, the `NO_BACKSLASH_ESCAPES` rule of the digest, privilege-error detection, account parsing, runtime configuration and gap accounting | `make -C plugin test` (Linux; six programs) / `plugin\build_windows.ps1` (native Windows; four programs) | The 2026-11-03 logs show four programs: **97 Linux checks** and **93 Windows checks** (the four-check difference is POSIX-only). These totals do not cover all six programs in the current Linux target. The 2026-11-09 Windows Docker Desktop summary reports all test programs passed but provides no aggregate check count. |
| Mutation check `scripts/mutation_check.py` | the unit tests fail when any of 47 deliberately injected plugin bugs is present | `make mutation` | **PASS**: 47 of 47 killed (CI `static`, `09-static-job.txt`); earlier 43 of 43 for 1.0.0 (`linux/mutation-check.txt`) |
| End-to-end plugin tests `tests/plugin/run_plugin_tests.sh` | the loaded plugin, through SQL only: install, configuration validation, the first SET GLOBAL of a connection, reading the log with `LOAD_FILE()`, every event type, filters, special input incl. a real `NO_BACKSLASH_ESCAPES` session, **refused statements**, **CHANGE_USER via the C API**, concurrency, fail-open, rotation, trigger interplay, uninstall/reinstall | `make test-e2e` | **PASS**: Linux **98 passed, 0 failed, 0 skipped** (CI, `02-make-test.txt`); Windows **90 passed, 0 failed, 2 skipped** (`05-plugin-e2e-tests.txt`, and CI `10-windows-job.txt`); the 2 skips are the Linux-only blocks (`/dev/full` fail-open, permission-denied path) |
| Web app tests `frontend/tests/test_app.py` and Audit Lab tests `frontend/tests/test_lab.py` | validation, access control, CSRF, throttles, 503 instead of 500 on database failures; with `RUN_DB_TESTS=1`: login with seed hashes, registration, bookings and loans, triggers, least privilege, **every lab action with the real plugin records and trigger rows**, ownership, explorer scoping, `next=` allow-list | `make test-app` | **PASS**: **104 passed** with database in the Docker web container (CI, `02-make-test.txt`) and in a manual Windows run (`06-…`, plugin 1.1.0); **80 passed** without database (CI `static`; manual Windows run `07-…`) |
| Browser tests `frontend/tests/browser/` (Playwright) | registration and login through the forms; tour navigation (Next/Back/Skip/Restart, keyboard, progress kept across reload); live plugin state; insert, CHECK violation and refused statement with their real records; explorer filters; no horizontal scroll at 390 px | `make test-browser` (first use bootstraps `.venv-browser`; or run `make browser-setup` explicitly) | **PASS**: **11 passed** in Chromium against the Docker stack (CI, `04-make-test-browser.txt`) and in a manual Microsoft Edge run on Windows (`08-browser-tests.txt`); `docs/screenshots/` come from CI run 8 |
| Administrator credential and diagnostic tests `tests/shell/test_admin_auth.sh` | `scripts/mariadb_admin_auth.sh` and its callers (`post_start.sh`, `demo.sh`, `provision_local_admin_db.sh`, `doctor.sh`) with a fake client: every `MYSQL_PWD` / `MARIADB_ROOT_PASSWORD` combination (absent, empty, equal, conflicting, non-root admin), refusal before the client runs, `set -u`, and the distinct diagnoses for `using password: NO`, `using password: YES`, unreachable server, other errors and a missing client; no dummy password in any output | `make test-unit`; also a suite of `make test` / `frantastic.cmd test` | **PASS**: 31/31 under Git Bash 5.2 on Windows 11 (2026-11-11); the original 28 fail 20/28 against the scripts of commit `3563dab`. Not yet run under Linux bash |
| Windows launcher tests `tests/windows/test_launcher_hardening.ps1` | `.env` validation following Compose's documented syntax (comments outside quotes, `#` inside quoted and unquoted values, quotes, escapes, whitespace, `=`/`:`; missing, empty, whitespace-only, duplicate and unparsable definitions; `${NAME}`, `"${NAME}"`, `$NAME` and unset references rejected, `'${NAME}'` accepted literally), removal and restoration of secret overrides, forwarding and restoration of process variables, refusal of empty values, native stderr vs. exit code, argument quoting, a hanging process and a hanging parent with its child terminated at the time limit, Docker CLI/Compose checks, bounded readiness with per-probe limits, and distinct messages for Docker Desktop, `DOCKER_HOST` and other contexts | `.\frantastic.cmd test`, or `powershell.exe -NoProfile -File tests\windows\test_launcher_hardening.ps1` | **PASS**: 98/98 under Windows PowerShell 5.1.26100 (2026-11-11) |
| Windows launcher end-to-end test `tests/windows/test_launcher_end_to_end.ps1` | `frantastic.cmd` → `frantastic.ps1` in a temporary copy with a fake `docker.cmd`: command dispatch (`help`, `demo`, `down`), `.env` checks before any container command, the exact Docker arguments (no password forwarded), removal and restoration of a session secret, native stderr with exit 0, propagation of a non-zero exit code, no secret in the output | `.\frantastic.cmd test`, or `powershell.exe -NoProfile -File tests\windows\test_launcher_end_to_end.ps1` | **PASS**: 12/12 under Windows PowerShell 5.1.26100 (2026-11-11); against the launcher of commit `3563dab` it fails |
| Password hash helper `tests/database/test_native_password_hash.sh` | `database/native_password_hash.sh` equals the server's `PASSWORD()` for random passwords with quotes, backslashes, `%`; an account created from the hash accepts the password | `make test-db` | **PASS**: 3/3 with 100 random passwords (Linux CI); 200 random passwords (manual Windows run, `09-…`) |
| Database installation order `tests/shell/test_database_setup.sh` (no server) | `scripts/setup_database.sh` with a stub client: fresh order (schema, 001–003, triggers, seed, 004–006, account) and `SKIP_SEED=1` order; refusal of an unlisted migration; the Dockerfile initdb order equals it; `database/app_account.sh` prints the expected grants (column UPDATE on `full_name`/`password_hash` only, DELETE only on `audit_lab_notes`, no FILE); `database/seed.sql` never assigns `role` in its `ON DUPLICATE KEY UPDATE` | `make test-unit`; also a suite of `make test` / `frantastic.cmd test` | **PASS**: 19/19 under Git Bash on Windows 11 (2026-11-12); against the previous setup script, Dockerfile and account script 7 of 18 fail, and against the previous seed the seed check fails. Not yet run under Linux bash |
| Shared demo administrator and seed re-run `tests/database/test_legacy_admin_migration.sh` | in one rolled-back transaction: seed, migration 004 (twice) demotes `dana.admin@example.edu` and keeps an unrelated administrator and all user rows; a second `seed.sql` run keeps Dana a student, keeps a locally promoted seed user (`bob.student@example.edu`) an administrator and leaves both local administrators' rows byte-for-byte unchanged | `make test-db` | Migration 004 part: see "Database credential/migration tests" below (earlier version). Seed re-run part: **NOT YET RUN** against a server |
| Migration 006 `tests/database/test_cancelled_loan_migration.sh` | on a scratch copy of `database/schema.sql`: `cancelled` added, default `active`, loan rows unchanged, a future loan can be cancelled with `returned_at = NULL`, the returned/not-returned CHECK still rejects inconsistent rows, re-run is a no-op, an unexpected column definition stops the migration | `make test-db` | **NOT YET RUN** against a server |
| Audit triggers `tests/database/test_audit_triggers.sh` (+ the team's `database/tests/test_audit_triggers.sql`) | the six legacy trigger names are absent; one AFTER trigger per table and event; one history row per booking/loan INSERT/UPDATE/DELETE with `connection_id`, `database_user`, `application_user_id`, `event_source`; a loan cancellation is one UPDATE row | `make test-db` | **NOT YET RUN** against a server |
| Application account grants `tests/database/test_app_account_grants.sh` | a throwaway account given `database/app_account.sh`'s SQL has exactly the expected privileges (also after an old table-wide `users` grant and on re-run); registration INSERT and `full_name`/`password_hash` UPDATE allowed; `role`/`is_active`/`email` UPDATE, audit-table writes and DELETE on `loans` refused; DELETE on `audit_lab_notes` and `import_current_log()` allowed; the installed `campus_app` has the same privileges | `make test-db` | **NOT YET RUN** against a server |
| Team's database checks `database/database_tests.sql`, checked by `tests/database/run_database_tests.sh` | constraints and joins: the tables, the sample rows, and each annotated error (code and constraint, in order), with no other error | `make test-db` | **PASS**: 10/10 (CI, `02-make-test.txt`; manual Windows run, `13-database-tests.txt`); before, the errors were checked by eye (`database-tests-windows.txt`, 2026-10-25) |
| Demo `scripts/demo.sh` | the newcomer path works end to end | `make demo` | **PASS** in Docker CI (`01-make-demo.txt`) and in the native-Windows CI demo step; a separate manual Windows run also recorded the original-code baseline (`03-…`) |
| Repository checks `scripts/check_repo.py` | README first line, links and paths, make targets named in docs, Dockerfile sources, migrations numbered, no tracked secrets | `make check` | **PASS** (CI and locally, 2026-11-03) |
| Clean environment | a fresh checkout or an empty data directory, set up only by the repository's scripts | Docker: `make up` on a new runner; native: the commands of `make up` / `make test` without Docker | **PASS**: Docker (CI, `00-make-up-and-doctor.txt`); manual Windows run: 87/0/2, 3/3, 104, 11 with plugin 1.1.0 (`10-clean-environment-run.txt`) |
| Overhead benchmark `scripts/benchmark.sh` | the cost of each audit configuration on 2 000 single-row INSERTs, two passes | `make bench` | **EXECUTED** in a manual native-Windows run (it measures, it does not pass or fail): `11-benchmark.txt`, `.csv`; interpretation in experiment 3b |
| Tutorial plugin `examples/skeleton_plugin` + `examples/06_skeleton_plugin.sql` | a minimal audit plugin builds, loads next to campus_audit and counts events; the EXPERIMENTAL build is refused with ER 1126 | `make examples` | **PASS**: built in the Docker image and loaded by `make examples` (CI, `03-make-examples.txt`); manual Windows run incl. the ER 1126 refusal (`12-skeleton-plugin.txt`) |
| Upgrade and recovery | `scripts/post_start.sh` upgrades a database created by the original code (data kept, idempotent); `make repair-credentials` restores the logins of a volume created with other passwords (data kept) | `make up`, `make repair-credentials` | **PASS**: the upgrade and repair SQL in a manual Windows run (`09-…`); the whole stale-volume repair through Docker (CI, `05-restart-and-regression.txt`) |
| CI `.github/workflows/ci.yml` | `static` on Ubuntu (plugin Makefile unit tests, mutation and repository checks); `docker-integration` on Ubuntu (full Docker, application, browser, restart and stale-volume regression); `windows-native` on Windows Server 2022 (DLL build, four native unit programs, MariaDB setup, demo and plugin integration tests) | push or pull request | **PASS**: run 8, all three jobs, as recorded in the dated evidence (`docs/evidence/linux-ci-2026-11-03/README.md`). The Windows application and browser results above are manual runs, not steps in `windows-native`. |

### Windows Docker Desktop manual validation (2026-11-09)

The project owner manually tested the final source ZIP on Windows 11 Pro, build `26100.6899`, with
Windows PowerShell 5.1, Docker Desktop `4.99.0.245822` (WSL2 backend, Linux-container mode), and
MariaDB `13.0.2`. The ZIP was freshly extracted into a path containing spaces. This was manual
Windows-hosted Docker Desktop testing, not CI; the containers and native plugin were Linux-based.

The `frantastic.cmd test` command runs the same Linux `test-runner` container as `make test`; it is
Windows-hosted Docker validation, not native-Windows compilation. The owner reported successful
`frantastic.cmd up` and `demo`: MariaDB and Flask became healthy; migrations 001–005 ran;
`campus_app` was provisioned; `campus_audit` became `ACTIVE`; local administrator provisioning and
verification succeeded, with credentials saved locally and not
displayed. With `MARIADB_PORT=13317` and `WEB_PORT=15081`, Compose published `127.0.0.1:15081` and
the launcher printed `http://127.0.0.1:15081/lab`. The demo recorded a booking, a rejected SQL
statement (4025), and a failed login (1045); 15 JSONL records were imported, with 0 invalid records,
0 dropped events and 0 write failures.

| Windows check | User-supplied result |
|---|---|
| ACL checks | 8 passed |
| Launcher URL regressions under Windows PowerShell 5.1 | 10 passed; all 10 also passed against the freshly extracted ZIP |
| Plugin C++ unit tests | All test programs passed; no aggregate check count was supplied |
| Repository checks | PASS |
| Plugin integration tests | 100 passed, 0 failed, 0 skipped |
| Database credential/migration tests | 3 passed, 0 failed |
| Database schema tests | 10 passed, 0 failed |
| Application and Audit Lab tests | 109 passed, 1 individual test skipped |
| Aggregate `frantastic.cmd test` | 5 suites passed, 0 failed, 0 skipped suites; overall PASS |

The tested host required a local WSL bootstrap checksum workaround. The installed ISO digest did not
match its `.sha256` sidecar; the original sidecar was preserved in a timestamped backup, and the local
sidecar was changed to match the observed ISO digest. The Docker Desktop executable and downloaded
installer signatures were valid Authenticode signatures from Docker Inc. The ISO was not independently
authenticated. This host-specific circumstance is not normal setup guidance and is not a FRANtastic
requirement. See the [dated evidence summary](evidence/windows-docker-desktop-2026-11-09/README.md).

## Current frontend suite (2026-11-12, without MariaDB and without a browser)

The counts in the table above (**104 passed** with a database, **80 passed** without, 109 passed and
1 skipped on 2026-11-09) are the dated results of earlier versions of the suite and are kept as
recorded. The suite has grown since: it now also contains `frontend/tests/test_fakedb.py`,
`frontend/tests/test_seed.py` and `frontend/tests/test_admin_bootstrap.py`, and many tests of
`test_app.py` and `test_lab.py` run the real routes against the in-memory fake database of
`frontend/tests/fakedb.py` (fixtures in `frontend/tests/conftest.py`). The numbers below are a
different run of a different suite and do not replace the earlier ones.

| | |
|---|---|
| Date | 12 November 2026 |
| Command | `python -m pytest -q` in `frontend/` |
| Python | 3.12.11 (Windows 11, virtual environment with pytest and the application's dependencies) |
| MariaDB integration tests | **disabled** (`RUN_DB_TESTS` not set; no server was started) |
| Playwright | **not installed** |
| Result | **259 passed, 24 skipped, 0 failed** |

Collected per file: `test_app.py` 161 (151 passed, 10 skipped), `test_lab.py` 80 (67 passed,
13 skipped), `test_fakedb.py` 24 passed, `test_seed.py` 15 passed, `test_admin_bootstrap.py`
2 passed, `browser/test_lab_browser.py` 1 skipped.

The 24 skipped tests were **not executed**, and nothing in this run says whether they pass:

| Skipped | Where | Reason reported by pytest |
|---|---|---|
| 10 | `frontend/tests/test_app.py`, the MariaDB tests | `set RUN_DB_TESTS=1 to run against MariaDB` |
| 13 | `frontend/tests/test_lab.py`, the MariaDB tests | `set RUN_DB_TESTS=1 to run against MariaDB` |
| 1 | `frontend/tests/browser/test_lab_browser.py` | `could not import 'playwright.sync_api'`: the whole module is skipped at import and counted once, so none of its browser tests ran |

What this run therefore does **not** show for the current code: anything that needs the real server
(login with the seed hashes, the triggers and the rows they write, the grants of `campus_app`, the
Audit Lab actions with real plugin records) and anything in the browser. The fake database
reproduces the application account's privileges and the statements the app sends; it does not
execute triggers, so stored values such as `event_source` are not checked here. These tests run
with `make test-app` / `frantastic.cmd test` (database) and `make test-browser` (browser); they have
not been run against the current working tree, and the database-side suites marked **NOT YET RUN**
above are still not run.

The same command on 13 November 2026, after the documentation and packaging changes of that day,
gave the same 259 passed, 24 skipped, 0 failed with the same skip reasons.

## Required cases → where they are covered

| Area | Case | Covered by | Status |
|---|---|---|---|
| Build | clean build | `build_windows.ps1`; Docker build stage `make -C plugin clean test plugin` | PASS (Windows; Linux image in CI) |
| Build | missing headers → clear failure | `build_windows.ps1 -MariaDBDir C:\does\not\exist`; Makefile `check-headers` (CI step) | PASS (Windows; Makefile in CI) |
| Install | load, ACTIVE in `information_schema.PLUGINS`; unload; missing library; twice | harness | PASS |
| Events | TABLE create/write/read/alter/rename, CONNECTION connect/connect_failed/disconnect, GENERAL STATUS ok/error | harness | PASS |
| Events | **CHANGE_USER** success and failure, which account is named | harness via `campus_change_user` (C API) | PASS (Linux and Windows) |
| Events | **refused statements** (ER 1142, 1227), default schema watched / not watched, excluded user | harness "refused statements"; lab action "forbidden statement" | PASS |
| Filtering | unwatched schema, reads off/on, excluded user, `*` excludes system schemas, connections NONE/FAILED/ALL | harness | PASS |
| Input | quotes/backslash/UTF-8 in names, 200 kB literal, truncation flag, newline/tab/emoji literals, `NO_BACKSLASH_ESCAPES` literals | harness + unit tests, experiment 20 | PASS |
| Errors | invalid paths and values, write failure at runtime | harness, experiments 4–6 | PASS (Windows; Linux incl. `/dev/full` fail-open) |
| Platform | the first accepted SET GLOBAL of a connection returns (Linux deadlock); `LOAD_FILE()` can read the log (Linux file mode) | harness, experiments 18 and 19 | PASS (Linux and Windows) |
| Lifecycle | restart, reinstall → new instance, log rotation | harness, experiment 7, CI restart step | PASS |
| Concurrency | 8 × 50 concurrent inserts, no torn lines, unique seq | harness | PASS |
| Integration | triggers vs plugin, rollback, app identity, lab actions | harness, app and lab tests, browser tests | PASS |
| Web app | registration and login, wrong password, database down / wrong password → 503 not 500 | app, lab and browser tests | PASS |
| Reproducibility | clean checkout on Docker; old volume with other passwords | CI `docker-integration` | PASS |

## Not verified

1. macOS Docker Desktop; Windows Docker Desktop was manually validated on 2026-11-09, not in CI.
2. Native Linux without Docker (README path C) and native macOS.
3. The benchmark on Linux or on a quiet machine (experiment 3b ran on the development laptop).
4. The workflow in the team's own repository: it ran in a private copy, with the same file.

## Windows validation source ZIP

From the maintainer checkout, run `python3 scripts/package_windows_source.py` to create
`windows-test-transfer/FRANtastic-Windows-Validation-Fix.zip`. The packager uses the current
working-tree contents of tracked files plus an explicit allowlist of intentional uncommitted
remediation files. It keeps `docs/evidence/sample-records.jsonl` because the README and examples
link to it, while excluding generated JSONL logs, local credentials, caches, and prior archives.

The ZIP is a runnable source tree and **includes the tests**: `frantastic.cmd test` builds the
`test-runner` image from the extracted tree and runs `pytest frontend/tests` in it
(`scripts/run_test_suites.sh`). All of `frontend/tests/` is therefore packaged, including the helper
modules `conftest.py` and `fakedb.py`, which `test_app.py` and `test_lab.py` need merely to be
collected, and `test_fakedb.py` and `test_seed.py`. While these four files are uncommitted they are
named in the packager's allowlist. `tests/test_source_distribution.py` fails if any file under
`frontend/tests/` in the working tree is missing from the archive, and, when pytest and the
application's dependencies are installed for the interpreter running it, also collects the frontend
tests from the extracted archive (collection only; it does not run them, and reports when it could
not check this).
