# Test plan and results

This document says what each test suite proves, how to run it, and **where and when it was really
run**. Results from different sources are kept apart on purpose:

| Source | What it is | Tested code |
|---|---|---|
| **P1** | Local runs of the Phase 1 verification, 15 and 16 November 2026, by the AI assistant that implemented the Phase 1 changes, on the project owner's PC. Raw outputs: `docs/evidence/phase1/` | commit `19fd0a2` **plus the uncommitted Phase 1 changes** (plugin 1.2.0) |
| **P0** | Local runs of the baseline assessment, 13 and 14 November 2026, by an AI assistant. Raw outputs: `docs/evidence/phase0-2026-11-13/` | exactly commit `19fd0a2` (plugin 1.1.1) |
| **CI** | GitHub Actions, workflow `.github/workflows/ci.yml` | see "GitHub Actions" below: green for the Phase 1 commit `5d48de0` and for the baseline `19fd0a2` |
| **Manual** | Runs by the project owner | as dated |
| **History** | Earlier dated evidence, kept as recorded: `docs/evidence/*-windows.txt` (2026-10-25, plugin 1.0.0), `docs/evidence/windows-2026-11-03/` (plugin 1.1.0), `docs/evidence/linux-ci-2026-11-03/` (plugin 1.1.1, CI in the private development repository) | older versions; the counts differ because the suites have grown |

Status words: **PASS** = executed and passed in the named source; **not run** = not executed, with
the reason. A count from one source is never used as the result of another.

P1 environments (details in `docs/evidence/phase1/README.md`): **L** = a Linux host (container
with GNU make and the Docker CLI) driving Docker Desktop's engine, project started from empty
volumes; **W** = Windows 11, Windows PowerShell 5.1, Docker Desktop, through `frantastic.cmd`;
**N** = native Windows MariaDB 13.0.2 (official zip) with the DLL built by Zig 0.16.0; **B** =
Chromium in the Playwright container.

## Current state (plugin 1.2.5, 21 November 2026)

**Read this section for the current results.** Everything below it is dated history, kept as it was
recorded: the suite table further down gives the Phase 1 counts (184 unit checks, 65 mutants and
so on), not the current ones.

| Suite | Current result | Raw output (`docs/evidence/cycle9/`) |
|---|---|---|
| Plugin unit tests, 7 programs | 225 passed as root; 223 passed and 1 skipped as a normal user | `07-unit-tests-root.txt`, `06-unit-tests-normal-user.txt` |
| Mutation check | 80 of 80 killed | `08-mutation-check.txt` |
| End-to-end harness; thread pool; stalled log; log path safety, on 13.0.2 and on 11.8.9 | 144/0/0, 30/0, 19/0, 39/0 + 2/0 on both | `16-server-13.0.2-plugin-1.2.5-two-assignments.txt`, `17-server-11.8.9-plugin-1.2.5-two-assignments.txt` |
| Plugin lab; permanent load | 25 / 0; 5 / 0 | `14-…`, `15-…`, `05-…` |
| Windows PowerShell tests | 10, 98 (the suite's own count; 99 PASS lines), 18, 37; ACL 8 | `09-windows-powershell-tests.txt` |
| GitHub Actions | four jobs on every push: static checks, Docker end to end (with `make plugin-lab` and `make test-permanent-load` on the clean checkout), MariaDB 11.8.9, native Windows | the runs of each commit are named in the cycle 9 section |

## GitHub Actions

**Merge commit `abdfa3a` on `main`** (PR #5 merged on 17 November 2026): run
[44034444030](https://github.com/rmoraru26/DB_Project_2026/actions/runs/44034444030) (push to `main`),
completed, success, 3 of 3 jobs, 41 of 41 steps (GitHub API, read 17 November 2026).

**Phase 1 commit `5d48de0`** (pushed to PR #5 on 17 November 2026), verified through the GitHub
API (`docs/evidence/phase1/checks/github-actions-runs-for-5d48de0.txt`): run
[44028367232](https://github.com/rmoraru26/DB_Project_2026/actions/runs/44028367232) (push) and run
[44028373377](https://github.com/rmoraru26/DB_Project_2026/actions/runs/44028373377) (pull request),
both completed, success; 3 of 3 jobs each (`ubuntu-24.04`, `ubuntu-24.04`, `windows-2022`), 82 of
82 steps successful, among them the new Phase 1 steps: the shell and demo-bootstrap tests, the
fresh-install check, `make test-integration`, the four PowerShell suites, and
`plugin\build_windows.ps1` with all seven unit-test programs on the hosted Windows runner (the
script stops with an error if any of them fails or cannot run). The job logs themselves were not
downloaded (they need an authenticated request); this record rests on the job and step results.

The baseline `19fd0a2`, verified through the GitHub API on 16 November 2026
(`docs/evidence/phase1/checks/github-actions-runs-for-19fd0a2.txt`):

| Run | Event | Commit | Result | Jobs |
|---|---|---|---|---|
| [43534005238](https://github.com/rmoraru26/DB_Project_2026/actions/runs/43534005238) | push to `submission/frantastic-final-review-isolated` | `19fd0a219930dd986eab5f9d53c1fe18c6ecd698` | completed, success (2026-11-14) | 3 of 3 successful |
| [43534008497](https://github.com/rmoraru26/DB_Project_2026/actions/runs/43534008497) | pull request | the same commit | completed, success (2026-11-14) | 3 of 3 successful: "Unit tests and static checks (no server)" (`ubuntu-24.04`), "make up / demo / test / browser tests on MariaDB 13.0.2 (Docker)" (`ubuntu-24.04`), "Build the DLL and load it into native Windows MariaDB 13.0.2" (`windows-2022`) |

What the baseline runs do **not** show:

- anything about the Phase 1 changes (see the runs for `5d48de0` above);
- the two administrator tests. Until Phase 1 the `make test` and `make test-app` recipes read the
  administrator credential from standard input instead of from `.admin-credentials`. In CI standard
  input is empty, so `test_generated_local_administrator_can_authenticate` and
  `test_administrators_can_explore_every_record` were skipped in every CI run although the step was
  green (reproduced: `docs/evidence/phase1/experiments/makefile-credentials-read-from-stdin.txt`,
  326 passed and 7 skipped with the old recipe against 331 and 2 with the corrected one).
  `scripts/check_repo.py` now refuses a recipe that reads them without the file.

## Test suites

| Suite | What it proves | How to run | P1 result | Other sources |
|---|---|---|---|---|
| Plugin unit tests, 7 programs: `test_record_format`, `test_log_sink`, `test_automatic_errors`, `test_error_reporter`, `test_runtime_config`, `test_gap_accounting`, `test_statement_scope` | JSON escaping and UTF-8 validation, digest masking incl. `NO_BACKSLASH_ESCAPES`, list parsing, system-schema detection, timestamps, path validation, open and write failures, file modes, privilege-error detection, atomic settings under concurrent readers, outage accounting, and the statement-scope rules with the event sequences observed on the server | `make -C plugin test`; Windows: `plugin\build_windows.ps1` | **PASS (L)**: 184 checks (72, 23, 13, 1, 4, 8, 63); **post-audit: 187** (75, 23, 13, 1, 4, 8, 63; three new system-schema checks; `post-audit/01-unit-tests.txt`). Post-audit, `test_record_format` alone also built and passed natively with MSYS2 g++ 15.2 (75 checks, `post-audit/12-…`). **PASS (native Windows, g++ 15.2)**: 180 checks (72, 19, 13, 1, 4, 8, 63; four are POSIX-only), **aggregated across two build configurations**: no single build ran all seven programs. `-O2` ran six (`test_statement_scope` refused by application control); `-O2 -DNDEBUG` ran four (`test_automatic_errors`, `test_error_reporter`, `test_gap_accounting` refused); so `test_statement_scope` passed only in the NDEBUG build and those three only in the `-O2` build (`windows-native/05-unit-tests-windows-gxx.txt`). The Zig builds of all seven **compile and link**; they were **not run** on the PC, whose application-control policy refuses them | P0: 6 programs pass. CI (`19fd0a2`): the Linux job ran 6 programs, the Windows job 4 (two were missing from the Windows script, and the two built on `assert()` checked nothing in an optimised build; both corrected in Phase 1) |
| Mutation check `scripts/mutation_check.py` | every one of the deliberately injected bugs in the plugin code (67 since the post-audit; 65 in Phase 1) makes a unit test fail | `make mutation` | **PASS (L)**: 65 of 65 killed; **post-audit: 67 of 67** (N07 and C10 rewritten for the new system-schema code, N12 and N13 added; `post-audit/02-mutation-check.txt`) | CI (`19fd0a2`): 47 of 47 |
| End-to-end plugin harness `tests/plugin/run_plugin_tests.sh` | the loaded plugin through SQL only: install, configuration validation, every event type, filters, special input, refused statements, CHANGE_USER via the C API, **statements without table events in both scopes (28 checks)**, concurrency, fail-open, rotation, trigger interplay, uninstall and reinstall | `make test-e2e` | **PASS (L)**: 128 passed, 0 failed, 0 skipped. **PASS (W)**: the same 128. **PASS (N)**: 110 passed, 0 failed, 3 skipped (permission-denied path, `/dev/full`, and CHANGE_USER because its helper was not built). Each SKIP line stands for a whole block, so 18 of the 128 Linux checks did not run natively: CHANGE_USER 8 (switch and wrong password, `change_user`/`change_user_failed` records under `connections=ALL` and `FAILED`, accounts named before and after, no password in the log), the permission-denied path 1, the write failure via `/dev/full` 9 (statement still succeeds, `DEGRADED`, `write_failures`, `last_error`, `audit_gap`, recovery to `ACTIVE`, the failed recovery marker). 110 + 18 = 128; "113" is 110 PASS lines plus 3 SKIP lines (comparison of `linux/20-make-test.txt` with `windows-native/09-plugin-e2e.txt`) | P0: 100 passed. CI (`19fd0a2`): Linux and Windows jobs green |
| Thread pool `tests/plugin/test_thread_pool.sh` | attribution of `SET GLOBAL`, of table events and of scope `SESSION` when 12 connections are served by `thread_pool_size=2` (two thread groups; the pool grew to 14 workers) (an observation for 13.0.2, not an API guarantee) | `make test-threadpool` | **PASS (L)**: 30 checks | P0: the first, manual version of phase 1 of this test |
| Database tests, 8 scripts in `tests/database/` | migration 004 and seed re-run; migration 006; triggers; exact grants of the application account; **migration 007 and its procedures (30)**; **the booking catalogue on a fresh and on a changed database (18)**; **the log import and its error paths (16)**; the password-hash helper; the team's constraint checks | `make test-db` | **PASS (L, W)**: 2 statements, then 18, 22, 24, 30, 18, 16, 3 and 10 checks. **Post-audit (throw-away 13.0.2 server, `post-audit/04-…`)**: 2 statements, then 18, 22, 24, **35**, **24**, 16, 3, 10 — migration 007 gained the open-transaction refusal (4 checks + 1) and the documented `check_constraint_checks` bypass (1), and lost the check that needs an installed demo account (none in a bare server); the catalogue gained 6 concurrency checks | P0: the first five and the last two pass. CI (`19fd0a2`): green |
| Web application and Audit Lab `frontend/tests/` | validation, access control, CSRF, throttles, booking rules and transactions against the in-memory database; with MariaDB: registration, bookings, triggers, least privilege, every lab action with real plugin records, **login of the generated demo student and administrator, the demo student's lack of administrator access, the booking catalogue through the real URLs** | `make test-app`, or as a suite of `make test` | **PASS (L, W)**: 332 passed, 1 skipped (the browser module) in the test-runner container; 331 passed, 2 skipped in the web container (additionally the catalogue comparison, which needs the repository tree). A run without a database was not recorded in Phase 1 (an earlier "294 passed, 39 skipped" had no evidence and was withdrawn) | P0: 292 passed, 3 skipped. CI (`19fd0a2`): green, with the administrator tests skipped (above) |
| Browser tests `frontend/tests/browser/` | registration and login through the forms, the tour's navigation, live plugin state, insert, CHECK violation, explorer filters, no horizontal scroll at 390 px | `make test-browser` | **PASS (B)**: 11 passed. `make test-browser` itself (a local virtual environment on the host) was **not run** | CI (`19fd0a2`): green |
| Shell tests `tests/shell/` | administrator password handling and diagnostics with a fake client (31); **the demo-credential state machine: first start, restart, missing file, re-created database, rotation, interrupted runs, unsafe files, no secret in any output (35)**; installation order, catalogue safety and grants (21) | `make test-unit` | **PASS (L)**: 31, 35, 21. Under Git Bash on Windows the demo test reports SKIP by design (no POSIX file modes) | P0: 31 and 19 |
| Host-level integration `tests/integration/` | against the running stack with real HTTP logins: the demo credential's life cycle (19); log rotation without loss or duplication (8) | `make test-integration` (also runs the thread-pool test) | **PASS (L)**: 19, 8, 30. **Post-audit**: log rotation 8 again with the new `rotate_log.sh` on the running stack (`post-audit/09-…`); new `test_log_import_limits.sh` 13 of 13 in three consecutive runs (`post-audit/07-…`). The demo life cycle and thread pool were not re-run (unchanged code paths) | new in Phase 1 |
| Windows launcher `tests/windows/` | file ACLs (8), the ready URL (10), `.env` validation and Docker readiness (98), the launcher end to end with a fake Docker (14), **the demo-credential state machine with real protected files (37)** | `.\frantastic.cmd test`, or each file with `powershell.exe -NoProfile -File` | **PASS (W)**: 8, 10, 98, 14, 37 | P0: 8, 10, 98, 12 |
| Windows launcher against Docker Desktop | `frantastic.cmd up` from an empty volume, `up` again, `demo`, `test`, `reset-demo` | as written | **PASS (W)**: all exit 0; owner-only ACL on `.env` and both credential files; no rotation on the second `up`; no secret in any output | Manual, 2026-11-09 (below), with an earlier version |
| Repository checks `scripts/check_repo.py`, `tests/test_source_distribution.py` | README first line, sections, commands and links; paths and make targets named in the documents; installation order; ignore rules for every generated secret; no tracked credential; the test recipes read credentials from files; every unit-test source is built on both platforms and none uses `assert()`; the formerly published password is not advertised; the Windows source archive contains the required files and none of the excluded kinds | `make check` | **PASS (L)** on a clean export and in the test-runner container; **PASS (W)** in the Git worktree and in the test-runner container. **FAIL (L)** when run in the directory of a running installation without `.git`: the check then sees `.env` and the credential files and reports them, as designed (`docs/evidence/phase1/README.md`). 12 of 12 deliberately broken states detected (`checks/repository-guards-mutation.txt`). The archive test checks a list of required files (about 25 named files, the documented JSONL sample and every frontend test file) and the absence of excluded kinds (`.env`, credential files, launcher temporaries, logs, build output, private-key markers), validates the ZIP, extracts it in a path with a space and runs the repository checks there; it does **not** check that the archive holds exactly the intended set; **collection of the frontend tests from the extracted archive was not verified** in any recorded run, because the interpreter had no pytest (the test reports this itself). An earlier "310 files" count had no recorded evidence and was withdrawn | CI (`19fd0a2`): green with the old README, which is why the README checks were added |
| Demo and examples | the newcomer path; seven SQL examples | `make demo`, `make examples` | **PASS (L)**; demo also **(W)** and **(N)** | CI (`19fd0a2`): green (six examples) |
| Fresh installation, restart, re-created volume, stale `.env` | `make up` on empty volumes; restart of the server; `make reset` and `make up` with the saved credential files; a new `.env` against an old volume and `make repair-credentials` | as written | **PASS (L)**: `linux/10` to `13`, `30`, `31`, `32` in the evidence folder | CI (`19fd0a2`): fresh start, restart and stale `.env` |
| Overhead benchmark `scripts/benchmark.sh` | the cost of each audit configuration on 2 000 single-row INSERTs; it measures, it does not pass or fail | `make bench` | **executed (L)**: +17.9 % and +29.5 % for campus_audit, +36.0 % and -17.1 % for server_audit: noise larger than any difference | History: native Windows, 2026-11-03 |

## Earlier manual validation

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

## Required cases and where they are covered

| Area | Case | Covered by | P1 |
|---|---|---|---|
| Build | clean build on Linux and Windows; missing headers fail clearly | image build; `plugin\build_windows.ps1`; Makefile `check-headers` (CI step) | PASS (L, N build); the missing-headers step runs in CI only |
| Install | load, `ACTIVE`, unload, missing library, twice | harness | PASS (L, N) |
| Events | TABLE, CONNECTION, GENERAL STATUS; CHANGE_USER; refused statements | harness | PASS (L); N without CHANGE_USER |
| Coverage limits | DML under `LOCK TABLES`; trigger, view and routine DDL; trigger bodies; scope `SESSION`; the remaining blind spot | harness "statements without table events"; `test_statement_scope`; example 07 | PASS (L, N) |
| Filtering | schemas, reads, excluded users, connection modes | harness | PASS (L, N) |
| Input | quoting, UTF-8, long literals, `NO_BACKSLASH_ESCAPES` | harness, unit tests | PASS (L, N) |
| Errors | invalid configuration; write failure at run time; plugin refuses to start | harness; `scripts/post_start.sh` prints the reason (experiment 28) | PASS (L) |
| Concurrency | 8 x 50 concurrent inserts; the thread pool | harness; `test_thread_pool.sh` | PASS (L) |
| Log import | repeat, invalid and unterminated lines, missing file, too large, failure in the middle, rotation | `test_log_import.sh`, `test_log_rotation.sh` | PASS (L) |
| Credentials | fresh start, restart, existing database without file, re-created volume, rotation, interrupted runs, role enforcement, secrecy | shell, PowerShell, database, application and integration tests named above | PASS (L, W) |
| Booking | every catalogue room and item exists and can be booked after a plain installation | `test_catalogue.sh`; application tests | PASS (L, W) |
| Web | registration, login, wrong password, database down, CSRF, throttling | application and browser tests | PASS (L, B) |
| Reproducibility | a clean checkout; an old volume with other passwords | fresh-install and stale-`.env` runs | PASS (L, W fresh start) |

## Not run, skipped or not verified

1. **GitHub Actions job logs.** The Phase 1 commit `5d48de0` ran green in CI (above); its job logs
   were not downloaded, so test counts inside the CI jobs are not recorded here.
2. **macOS**, in any form. The Linux host scripts use GNU `stat -c` and `mv -T`.
3. **A physical Linux machine without Docker.** The by-hand path itself (distribution headers,
   build, install, restart, setup, demo, harness, web app) was run in cycle 2 on Ubuntu with the
   MariaDB 13.0.2 packages inside a plain container (`docs/evidence/cycle2/01-native-linux-install.txt`).
4. **`make` on a real Linux installation.** The P1 "Linux host" is a Linux container with GNU make
   that drives Docker Desktop's engine; the commands and file-system semantics are Linux, the
   kernel and Docker engine are Docker Desktop's.
5. **The Zig-built unit-test executables** on the development PC (refused by Smart App Control);
   they run in the `windows-native` CI job, which has not run for the Phase 1 tree.
6. **CHANGE_USER on native Windows** in P1 (the C helper was not built); covered on Linux.
7. **`make test-browser` as a command**; the same tests ran from the Playwright container.
8. **The Audit Lab and the booking pages by a human**, and any visual review after the website
   team's pending changes (`docs/visual-qa.md`).
9. **The `# exit status` lines of `docs/evidence/phase1/linux/`** are not results (the harness
   recorded the status of an `echo`); every step was re-checked by its output.
10. **Skipped tests in P1:** the browser module inside the application suite (it has its own run),
   and the catalogue comparison inside the web container (it needs files that image does not hold;
   it runs in the test-runner container).
11. The benchmark on a quiet machine.
12. **Collection of the frontend tests from the extracted source archive**: in every recorded run
   of `tests/test_source_distribution.py` the interpreter had no pytest, so the test skipped that
   step and said so.
13. **Post-audit, not re-run:** the native Windows DLL build and harness (the system-schema change
   in `plugin/src/record_format.cpp` was tested on Linux, plus `test_record_format` with MSYS2 g++
   on Windows); the Windows launcher suites; `make test` and `make test-app` as a whole; the browser
   tests; the demo-credential life cycle and thread-pool tests. None of their code changed except
   comments, the plugin source and the SQL files covered above.
14. **Post-audit P2-1** (a "pending statement" left set without a STATUS event): 16 event
   sequences were tried, none left it set (`post-audit/06-…`). Prepared statements over the binary
   protocol (`COM_STMT_PREPARE`/`COM_STMT_EXECUTE` through the C API) were added to the harness
   after the first merge (6 checks, `docs/evidence/cycle1/`): nothing is left pending there either.

## Post-audit remediation (17 November 2026)

Evidence: `docs/evidence/phase1/post-audit/` (raw outputs; its README lists each file). All runs
were made locally by the AI assistant on the project owner's PC, from the uncommitted working
tree; none is a CI run.

| What | Run | Result |
|---|---|---|
| Plugin unit tests | `make -C plugin clean test` (Linux, test-runner image) | 7 programs, 187 checks, exit 0 |
| Mutation check | `python3 scripts/mutation_check.py` | 67 of 67 killed, exit 0 |
| Plugin harness + 8 database scripts | in a throw-away 13.0.2 server with this tree's plugin build, 007, 008 and catalogue applied | 128/0/0; 18, 22, 24, 35, 24, 16, 3, 10; overall exit 0 |
| Control: new database checks against the pre-fix SQL | same, with `database/` from the pre-remediation backup | 5 of 35 and 3 of 24 checks fail as intended (caller's transaction committed; 10 rooms) |
| Log import at and above the limit | `bash tests/integration/test_log_import_limits.sh`, three runs | 13 of 13 each, exit 0 (a first run failed on a defect of the new test itself, two rotations in one second: 3 checks failed and it stopped before its summary; kept as `07a-…`) |
| Control: the same test against the pre-fix scripts | pre-remediation `rotate_log.sh` and 008 | 6 passed, 7 failed, exit 1 |
| Log rotation on the running stack | `tests/integration/test_log_rotation.sh` with the new `rotate_log.sh` | 8 of 8, exit 0 |
| Repository checks, source distribution, `git diff --check` | Windows Git worktree, MSYS2 Python 3.12 | all exit 0 (frontend collection not checked: no pytest) |
| Shell suites, affected frontend tests, `bash -n` | test-runner image | 31, 35, 21; pytest 39 passed; syntax ok |
| Website files | `git status` / `git diff 19fd0a2` of templates, static, `app.py`, every `.html/.css/.js` | unchanged |

### Closeout check (17 November 2026)

Evidence: `docs/evidence/phase1/closeout/`. Observed:

| What | Result |
|---|---|
| Cited evidence paths (`01-evidence-paths.txt`) | every path exists; the three "missing" lines are two range references (`01` to `04`, `10` to `13`) and the correction note that says `linux/26-source-distribution.txt` was never recorded |
| Repository checks, source distribution, `git diff --check`, trailing blanks, website files, submission worktrees (`02-repository-checks.txt`) | all exit 0; website files unchanged; `DB_Project_2026-submission-review` clean at `19fd0a2` |
| Secret scan of the change set (`03-secret-scan.txt`) | none of 13 generated values of the two test stacks in any of 202 files; no private key, no real hash |
| Wording of the archive test | corrected: it checks required files and excluded kinds, not that the archive holds exactly the intended set |
| Extra P1-1 failure paths (`docs/evidence/phase1/closeout/scripts/p1_1_recovery.sh`: an archive left by the pre-fix script recovered with `--import`; failure in the middle of a parts import; failed reopen) | first **not run** (Docker Desktop's container store became read-only, `04-docker-store-read-only.txt`); after the Docker recovery: 9 passed, 1 failed (`06a-…`: after a failed reopen `rotate_log.sh` left the plugin `DEGRADED`), fixed, then **10 of 10** (`06-…`) |

## Final local verification (17 November 2026)

Everything above was run again on the finished tree before the commit, as a commit checks it out
(Git tree `28f2fc09`), on new stacks with their own volumes; raw outputs and a per-test
classification (passed, failed, blocked, not run) in `docs/evidence/phase1/final-verification/`.

| Suite | Result |
|---|---|
| Linux: unit tests, shell suites, repository checks, mutation | 187 checks; 31, 35, 21; pass; 67 of 67 killed |
| Linux: fresh `make up`, `make doctor`, `make demo`, `make examples` | pass; both logins work, the demo student gets 403 on `/admin/audit` |
| Linux: `make test` | 8 of 8 suites; harness 128/0/0; database 18, 22, 24, 36, 24, 16, 3, 10; application 332 passed, 1 skipped |
| Linux: `make test-integration`, `make test-app` | 19, 8, 13, 30; 331 passed, 2 skipped |
| Browser tests; pages at three widths | 11 passed; 48 page views, expected status, 0 px overflow, 0 console errors |
| Windows launcher: `frantastic.cmd up`, `test`, `reset-demo` | ACL 8, URL 10, hardening 98, end-to-end 14, demo credentials 37; 8 of 8 suites (harness 128/0/0, application 332 passed, 1 skipped); owner-only ACLs; no rotation on the second `up` |
| Native Windows: Zig DLL, `INSTALL SONAME` | built; `ACTIVE 1.2.0 Beta BSD` |
| Native Windows: setup, demo, harness | pass; harness 118/0/2, and 119/0/1 with a real denied path (only `/dev/full` skipped) |
| Native Windows: the nine database scripts (first native run) | all pass; one part of `test_log_import` skipped (needs an absolute log path) |
| Native Windows: unit programs | each of the 7 passed in at least one native build; Smart App Control **blocked** 10 of the binaries built for this (12 block events, listed with SHA-256); blocked binaries are not counted as passed; the Zig builds of all seven run in the `windows-native` CI job |

Two defects were found and fixed during this pass, and the affected tests re-run: `rotate_log.sh`
after a failed reopen (above), and `tests/integration/test_log_rotation.sh`, which failed when the
same plugin instance had been rotated before (it compared all rows of the instance with only the
two newest files; all records were in fact imported exactly once). The failing runs are kept.

## Improvement cycle 1 after the merge (17 November 2026)

Raw outputs in `docs/evidence/cycle1/`. New: prepared statements over the binary protocol
(`COM_STMT_PREPARE`/`COM_STMT_EXECUTE` through the C API, 6 harness checks); random passwords in the
evidence driver scripts (three of them re-run with the same results); the exploratory programs
moved out of the test tree.

| Suite | Result |
|---|---|
| Linux: unit, shell, repository checks, mutation | 187; 31, 35, 21; pass; 67 of 67 |
| Linux: `make test` | 8 of 8 suites; harness 134/0/0; database 18, 22, 24, 36, 24, 16, 3, 10; application 332 passed, 1 skipped |
| Linux: `make examples`, `make test-integration`, `make test-app` | pass; 19, 8, 13, 30; 331 passed, 2 skipped |
| Native Windows: DLL, harness, database scripts | `ACTIVE 1.2.0`; 125/0/1 (`/dev/full` only); all nine pass |
| Native Windows: `build_windows.ps1` unit programs | Smart App Control **blocked** `test_automatic_errors.exe` (not counted; CI runs all seven) |

## Improvement cycles 2 and 3 (17 November 2026)

Cycle 2 (`docs/evidence/cycle2/`): the README's Linux path without Docker run in full on Ubuntu with the
MariaDB 13.0.2 packages in a plain container: build, install, restart, setup, demo, verification SQL,
harness 134/0/0, web application (`/healthz` 200).

Cycle 3 (`docs/evidence/cycle3/`): the plugin built against MariaDB 11.8.9 (audit API `0x0302`) after
relaxing its version check; on a running 11.8.9 server the harness passed 134/0/0 and the thread-pool
test 30/30. The full Linux suite on 13.0.2 for the same tree: 187 unit checks, 67 of 67 mutants,
`make test` 8 of 8 (harness 134/0/0, database 18, 22, 24, 36, 24, 16, 3, 10, application 332/1),
integration 19, 8, 13, 30, `make test-app` 331/2. Not run: 10.11 and 11.4; native Windows for this
tree (CI runs it on push).

## Improvement cycles 4 and 5 (17 November 2026)

Cycle 4 (`docs/evidence/cycle4/`): the unused `try_open_log()` removed with its three unit-test
cases; 184 unit checks, 67 of 67 mutants. CI run 44071525891 for `3208c75`: 3 of 3 jobs successful.

Cycle 5 (`docs/evidence/cycle5/`), plugin 1.2.1: guards on every function the server calls; bounded
waits for the log under server locks (experiment 32). New `tests/plugin/test_stalled_log.sh`
(`make test-stalled-log`, also in `make test-integration`), 17 checks. On plugin 1.2.0 it gives
7 passed, 10 failed. New `scripts/test_server_version.sh` (`make test-server-version`), CI job
`server-11-8`. Local results: 184 unit checks; 67 of 67 mutants; on 13.0.2 and on 11.8.9 the harness
134/0/0, thread pool 30/0 and stalled log 17/0. Not run locally: the web application, database and
browser suites, and native Windows; CI runs them on push. CI run 44090286551 for `3166885`: 4 of 4
jobs successful (Docker, MariaDB 11.8.9, native Windows, static).

## Improvement cycle 6 (17 November 2026)

`docs/evidence/cycle6/`, plugin 1.2.2: update functions normally do no log I/O (check functions open the
files; `config_change` records are written by the statement's STATUS event); records lost without
an I/O error are announced by the next `audit_gap` record. Local results: 192 unit checks; 67 of 67
mutants; on 13.0.2 and on 11.8.9 the harness 134/0/0, thread pool 30/0 and stalled log 19/0 (two new
checks: a `SET GLOBAL campus_audit_log_reads` while the log is stalled returns, and its record is
written afterwards). Not run locally: the web application, database and browser suites, and native
Windows; CI runs them on push. CI run 44094440392 for `61a0814`: 4 of 4 jobs successful.

## Improvement cycle 7 (17 November 2026)

`docs/evidence/cycle7/`, plugin 1.2.3: the DISCONNECT event writes a connection's pending
configuration records; a staged file is closed when its update gives up; wording and citations
corrected. 192 unit checks; 67 of 67 mutants; on 13.0.2 and on 11.8.9 the harness 134/0/0, thread pool
30/0, stalled log 19/0. CI run 44097222910 for `dce0a16`: 4 of 4 jobs successful.

## Improvement cycle 8 (17 November 2026)

`docs/evidence/cycle8/`, plugin 1.2.4: `campus_audit_file_path` refuses an existing file that is not a
campus_audit log (`docs/security.md`, "Tamper evidence"). New: 7 unit checks, 4 mutants (S04-S07),
3 harness checks. Local results: 199 unit checks; 71 of 71 mutants; on 13.0.2 and on 11.8.9 the
harness 137/0/0, thread pool 30/0, stalled log 19/0. CI run 44121153458 for `d147cdc`: static, Docker
and 11.8.9 successful, native Windows failed (end-to-end step; log not readable without signing in).

Security review of the same protection (`docs/evidence/cycle8/security-review/`): decisions on the
opened descriptor or handle; no symbolic or hard links, owner check (Linux), `.jsonl` names only,
widening only of new files. New `tests/plugin/test_log_path_safety.sh` (`make test-log-path-safety`,
also in `make test-integration` and `make test-server-version`). 213 unit checks; 75 of 75 mutants; on
13.0.2 and 11.8.9 the harness 141/0/0, thread pool 30/0, stalled log 19/0, log path safety 33/0 + 2/0.
Native Windows: built; loading blocked locally by Smart App Control; CI job `windows-native`.

After the second independent review (`docs/evidence/cycle8/security-review/final/`): 219 unit checks
as root (217 and one skip as a normal user); 77 of 77 mutants as a normal user; on 13.0.2 and 11.8.9 the
harness 141/0/0, thread pool 30/0, stalled log 19/0, log path safety 39/0 + 2/0. CI run 44842611321 for
`38aa30c`: 4 of 4 jobs successful, including native Windows (unit tests with the Windows attack cases,
setup, demo, harness).

## Improvement cycle 9 (21 November 2026)

`docs/evidence/cycle9/`. First part, plugin code unchanged (1.2.4):

- **`make plugin-lab` / `.\frantastic.cmd plugin-lab`**: the plugin on its own, in a throw-away server
  built from the new Dockerfile stage `plugin-server`, with the guided tour `plugin/lab/tour.sh`.
  Results: 24 passed, 0 failed, through `scripts/plugin_lab.sh` in Git Bash against Docker Desktop on the development PC (`01-plugin-lab-docker-desktop.txt`; its image layers were cached, the clean build is CI's) and through
  the Windows launcher against Docker Desktop (`02-plugin-lab-windows-launcher.txt`). An earlier run
  through the launcher, before the maturity step existed, gave 23 of 23
  (`02-plugin-lab-windows-launcher-23-checks.txt`). The development PC has no GNU make; the
  `make plugin-lab` target itself ran in CI, on the clean checkout, before `make up`.
- **The skeleton plugin** has its own Makefile, which the image build now uses. The native Windows CI
  job builds `skeleton_audit.dll` with Zig and loads it next to campus_audit.
- **`test_local_file_acl.ps1` in CI.** It refuses an elevated session, and GitHub's runners are
  elevated, so `tests/windows/run_as_standard_user.ps1` runs it as a throw-away standard user. That
  user is a member of Users only and has a random, masked password; the user and its profile are
  removed afterwards. The script refuses to run anywhere but a GitHub-hosted runner. The test itself
  is unchanged and still refuses elevation, so a zero exit code shows a non-elevated run.
- **Harness literals.** `run_plugin_tests.sh` quoted values it does not choose itself (paths read
  from the server or the environment, the saved configuration) with `'${x//\\/\\\\}'`. That escaped
  backslashes only, so a `'` in a path broke the statement, and it depended on `NO_BACKSLASH_ESCAPES`.
  It now writes them as hex literals (`sql_str`). The throw-away test accounts' password was
  `t_<time>_<pid>_Pw` and could be guessed while a run lasted; it is now random.
- **Experiment 34** (`03-force-plus-permanent.txt`): loaded as `FORCE_PLUS_PERMANENT`, the plugin cannot be
  unloaded (ER 1702).
- **The launcher** test gained 4 checks for `plugin-lab` and `plugin-lab-down` (18 in all).

Local results of the first part (commit `9f87fe6`; CI runs 44872138609 and 44872142721, 4 of 4 jobs each): unit tests, all 7 programs passed as a normal user and as root
(`04-unit-tests-and-mutation.txt`); mutation check 77 of 77; on 13.0.2 the harness 141/0/0, thread pool
30/0, stalled log 19/0, log path safety 39/0 + 2/0 (`10-server-13.0.2.txt`); on 11.8.9 the same counts, 0 failed
(`11-server-11.8.9.txt`; a first attempt stopped before any test, when apt in the image build refused Ubuntu release files as "not valid yet": the Docker VM clock was about 6 minutes behind, `11-server-11.8.9-first-attempt-clock-skew.txt`); Windows PowerShell tests 10, 99, 18, 37 and the ACL test 8 (non-elevated);
`scripts/check_repo.py` passed.

Second part, after two independent evaluations of `4abb6ae` (they scored 33 and 28 of 40; the
starting point was 35, from another evaluator). The defensible deductions were acted on:

- **Plugin 1.2.5, redirect handover** (experiment 35): a change of `campus_audit_file_path` is now
  recorded in the log it leaves, not only in the new one. Two new harness checks; the plugin lab
  shows it (step 6, now 25 checks).
- **Plugin 1.2.5, executable comments** (experiment 36): `/*! ... */` and `/*M! ... */` are lexed,
  not dropped. Six new unit checks; mutants D17 to D19.
- **Experiment 34 as a test:** `tests/plugin/test_permanent_load.sh` (`make test-permanent-load`,
  also in CI).
- **Documentation corrections:** the thread-pool wording (the pool grew to 14 workers; the test
  does not show a statement moving between threads); the README SQL example now shows real output;
  stale statements in `docs/docker.md`, `docs/architecture.md`, `docs/plugin-api-notes.md` and
  `docs/experiments.md`; the skeleton walkthrough and the "Things to try" list work in the plugin
  lab; the plugin-lab evidence file is named for where it ran (Docker Desktop on the development PC).
- **Full raw outputs** instead of tails: unit tests as a normal user and as root, the mutation check,
  the Windows PowerShell tests.

Local results of the second part (plugin 1.2.5, commit `bf19156`; CI runs 44873899006 and 44873903594, 4 of 4 jobs each, native Windows included):

| Suite | Result | Raw output |
|---|---|---|
| Unit tests, 7 programs | 225 passed as root; 223 passed and 1 skipped as uid 1000 | `07-unit-tests-root.txt`, `06-unit-tests-normal-user.txt` |
| Mutation check | 80 of 80 killed (uid 1000) | `08-mutation-check.txt` |
| Harness / thread pool / stalled log / log path safety on 13.0.2 | 143/0/0, 30/0, 19/0, 39/0 + 2/0 | `12-server-13.0.2-plugin-1.2.5.txt` |
| The same on 11.8.9 | 143/0/0, 30/0, 19/0, 39/0 + 2/0 | `13-server-11.8.9-plugin-1.2.5.txt` |
| Plugin lab | 25 passed, 0 failed, through the script and through the Windows launcher | `14-…`, `15-…` |
| Permanent load (experiment 34) | 5 passed, 0 failed | `05-test-permanent-load.txt` |
| Windows PowerShell tests (non-elevated) | 10, 99, 18, 37; ACL 8 | `09-windows-powershell-tests.txt` |
| Repository checks | passed | |

Not done in this cycle: the screenshots still show plugin 1.2.0 (`03-plugin-state.png` lists 6 of
the 9 variables), because retaking them needs the browser tests against the full stack; no
mysql-test-run suite; `campus_audit.cpp` has no unit tests or mutants of its own.

Third part, after two further independent evaluations of `bf19156` (34 and 31 of 40). Their
verified findings were acted on:

- **Handover with two assignments in one `SET`** (`SET GLOBAL campus_audit_file_path = 'x.jsonl',
  GLOBAL campus_audit_file_path = '/dev/null'`). The second check function replaced the file staged
  by the first, and `LogSink::open` closed the log that was being read before it could be handed
  over. Now the file is opened beside the active one, and the first retired file, the log being
  read, keeps the handover. New harness check "two redirects in one SET are both recorded in the
  log they left"; reading the old code path, it would find 1 record instead of 3 (not run against
  the old code). Harness 144/0/0 on 13.0.2 and 11.8.9 (`16-…`, `17-…`).
- **Documentation corrections:**
  - which variables have check functions (four have none);
  - sample records now copied from committed evidence;
  - `database` is already in `0x0302`;
  - 10.11 and 11.4 were not run;
  - executable comments in `docs/security.md`;
  - `BUSY` in `plugin/docs/error_handling.md`;
  - the browser-test claim (CI checks 390 px; the three-width scan was local);
  - the hardening suite's own count (98);
  - the remaining log I/O under a server lock in recovery paths;
  - the real 11.8.9 digest;
  - a current-state table at the top of this file.
- **Limitations documented:**
  - the handover's gaps: the old log gets no account, and a `SET` without its own STATUS event is not covered;
  - excluded users' failed logins are not recorded;
  - schema names are matched case-insensitively.
- **Not done, and why:**
  - merging to `main` needs the team's approval;
  - screenshots;
  - no mysql-test-run suite or in-tree CMake build;
  - no unit tests or sanitizer builds for `campus_audit.cpp`;
  - the polling timed lock;
  - per-thread state on UNINSTALL;
  - the event-scheduler case was not tested.

**Screenshots, 21 November 2026 (after `a92ef8d`).** The ten README screenshots were regenerated
from the running application with plugin 1.2.5. This was a separate Compose project with the
Playwright browser tests (11 passed); the details are in `docs/visual-qa.md`, "Latest capture". The
remarks above that the screenshots still showed plugin 1.2.0 refer to the state before this capture.

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
collected, and `test_fakedb.py` and `test_seed.py`. Files that are not committed yet are
named in the packager's allowlist. `tests/test_source_distribution.py` fails if any file under
`frontend/tests/` in the working tree is missing from the archive, and, when pytest and the
application's dependencies are installed for the interpreter running it, also collects the frontend
tests from the extracted archive (collection only; it does not run them, and reports when it could
not check this).
