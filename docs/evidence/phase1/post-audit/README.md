# Post-audit remediation evidence (17 November 2026)

Raw outputs of the runs made while the findings of the independent Phase 1 audit were fixed. They
are unedited; each file starts with a line saying what was run, when (UTC) and on what. Every
`# exit status` line here records the status of the command itself (`cmd; echo $?` with the
command last), unlike the Phase 1 `linux/` files described in `../README.md`.

**What was tested.** The uncommitted working tree of `improvement/frantastic-37plus` (baseline
`19fd0a219930dd986eab5f9d53c1fe18c6ecd698` plus the Phase 1 and post-audit changes). **Who ran
it:** the AI assistant that made the changes, locally on the project owner's PC. None of these is
a GitHub Actions run.

**Environments.** Docker Desktop on Windows 11 (10.0.26200). Server runs use throw-away containers
from the Phase 1 stack's MariaDB image `frt-p1-79c0601b-mariadb:13.0.2` (13.0.2-MariaDB-ubu2604,
`lower_case_table_names=0`), each with its own anonymous volume, removed afterwards; where the
plugin matters, the image's `campus_audit.so` was replaced by one built from this tree in the
test-runner image (`make -C plugin plugin`). Builds and the mutation check ran in
`frt-p1-79c0601b-test-runner:latest` on a copy of the tree. Repository checks ran in the Git
worktree with MSYS2 Python 3.12.11. File 09 is the only run against the running Linux-host test
stack `frt-p1-79c0601b`; its MariaDB container was given this tree's `scripts/rotate_log.sh` for it
(the image's copy is saved inside that container as `/tmp/rotate_log.sh.image-copy`; re-creating
the container restores the image's version). No volume of any other project was touched.

**Controls.** Files 05, 08 and 14 run the new tests or the experiment against the *pre-fix* files,
taken from the filesystem backup made before the remediation
(`FRANtastic-P1-backup-20261117-024313`, outside the repository). They are expected to fail and
show that the tests detect the defects.

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test`, g++ 14 | 7 programs, 187 checks (75, 23, 13, 1, 4, 8, 63), exit 0 |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py` | 67 of 67 killed, exit 0 |
| `03-system-schema-case.txt` | `scripts/schema_case.sh`: `databases='*'`, user schemas `MySQL` and `Sys`, before and after the fix | name resolution: `INFORMATION_SCHEMA`/`Performance_Schema` resolve in any case, `MYSQL.user`/`SYS.version` do not exist. Image plugin: 0 records for `MySQL` and `Sys`. Plugin of this tree: 1 each; `mysql`, `sys`, `performance_schema` still 0 |
| `04-harness-and-database-tests.txt` | `scripts/db_suites.sh`: plugin harness and the 8 database scripts of this tree, after applying 007, 008 and `catalogue.sql` | harness 128 passed, 0 failed, 0 skipped; database 18, 22, 24, 35, 24, 16, 3, 10; overall exit 0 |
| `05-control-new-db-tests-against-prefix-sql.txt` | the new `test_demo_student.sh` and `test_catalogue.sh` against the pre-fix `database/` | 30 passed / 5 failed and 21 passed / 3 failed: the old procedures commit the caller's transaction; two overlapping catalogue runs leave 10 rooms (5 names) |
| `06-server-behaviour-and-p2-1-probes.txt` | `scripts/server_probes.sh` | A: SESSION `max_allowed_packet` is read-only (ER 1621); SET GLOBAL affects new connections only; `LOAD_FILE()` returns NULL with warning 1301 for size >= limit (2048 and 3000 bytes NULL, 2047 read); GLOBAL clamped to 1024..1073741824, rounded down to a multiple of 1024. B: the CHECK refuses root's ordinary UPDATE (ER 4025), not one after `SET SESSION check_constraint_checks = 0`; a non-SUPER account may set that variable. C: 16 event sequences, probe recorded after every one (P2-1 not reproduced) |
| `07-log-import-limits.txt` | `tests/integration/test_log_import_limits.sh`, three consecutive runs | 13 of 13 each, exit 0 |
| `07a-log-import-limits-first-run-test-defect.txt` | the first run of that test | 3 checks failed, then the script stopped on an unbound variable before its summary (exit 1): the test rotated twice within one UTC second, which `rotate_log.sh` refuses by design. A defect of the test, fixed (`sleep 1.1`); kept because it happened |
| `08-control-log-import-limits-against-prefix-scripts.txt` | the same test against the pre-fix `rotate_log.sh` and 008 | 6 passed, 7 failed, exit 1 (among them: after rotating an oversized log, 515 records in the files but 65 rows in `plugin_events`) |
| `09-log-rotation-running-stack.txt` | `tests/integration/test_log_rotation.sh` on the running stack with the new `rotate_log.sh` | 8 of 8, exit 0 |
| `10-repository-checks.txt` | `check_repo.py`, `test_source_distribution.py`, `git diff --check`, trailing blanks in untracked files outside `docs/evidence/` | all exit 0; grep found nothing (`xargs` reports 123 when every grep finds nothing); frontend collection from the archive not checked (no pytest in that interpreter) |
| `11-shell-frontend-syntax.txt` | shell suites, `pytest tests/test_seed.py tests/test_demo_bootstrap.py`, `bash -n`, exploratory programs | 31, 35, 21 passed; 39 passed; syntax ok; both exploratory programs compile |
| `12-windows-gxx-test-record-format.txt` | `test_record_format` built and run natively with MSYS2 g++ 15.2 | 75 checks, exit 0 |
| `13-website-files-untouched.txt` | `git status` and `git diff 19fd0a2` of `frontend/templates`, `frontend/static`, `frontend/app.py`, every `.html/.css/.js` | nothing changed |
| `15-final-repository-checks.txt` | file 10's checks again on the finished tree (after this folder, its README and the doc updates were written) | all exit 0; no trailing blanks in non-evidence untracked files or in this README and `scripts/` |
| `14-catalogue-race-prefix.txt` | `scripts/catalogue_race.sh` with the pre-fix `catalogue.sql` | REPEATABLE READ: 5 rooms; READ COMMITTED: 10 rooms, 5 distinct names |

`scripts/` holds the drivers of files 03 to 06 and 14 as they were run. The passwords in them
(`expRootPw12345`, `expAppPw123456`, `expUserPw1234`) exist only inside the throw-away containers
those scripts start and remove.

Not run after the remediation: GitHub Actions; the native Windows DLL build and harness; the Windows
launcher suites; `make test` / `make test-app` as a whole; browser tests; the demo-credential life
cycle and thread-pool tests. See `docs/testing.md`, "Not run, skipped or not verified".
