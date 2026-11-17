# Improvement cycle 1 after the first merge (17 November 2026)

Raw outputs of the runs for the first improvement cycle after PR #5 was merged into `main`
(`abdfa3a`). Tested source: the working tree of `improvement/area11-post-merge-cycle1`, exported as
a commit of it is checked out (Git tree `e4886d99717bb55f18052bf5163b0c1e0e7eae1d`). Outputs are
unedited except that local scratch paths read `<scratch-root>` / `<scratch-p1>`. Every
`# exit status` line is the status of the command itself. All runs were made locally by the AI
assistant on the project owner's PC; the CI runs of the pushed commit are the separate evidence.

## What changed in this cycle

| Change | Why |
|---|---|
| `tests/plugin/change_user.c --prepared` and 6 harness checks | Prepared statements over the **binary protocol** (`COM_STMT_PREPARE` / `COM_STMT_EXECUTE`, what a driver sends) were the last untested statement-correlation path. The mariadb client sends `PREPARE`/`EXECUTE` only as SQL text |
| Random passwords in the evidence driver scripts | They contained literal throw-away container passwords, which read like hardcoded credentials |
| `plugin/tests/exploratory/` → `plugin/exploratory/` | Two early programs without checks no longer sit in the test tree |

## Results

| Files | Run | Result |
|---|---|---|
| `01-rerun-catalogue-race.txt` | `post-audit/scripts/catalogue_race.sh` with random passwords, pre-fix `catalogue.sql` | same as `post-audit/14`: REPEATABLE READ 5 rooms, READ COMMITTED 10 rooms (5 names) |
| `02-rerun-p1-1-recovery.txt` | `closeout/scripts/p1_1_recovery.sh` with random passwords | 10 passed, 0 failed (as `closeout/06`) |
| `03-rerun-server-probes.txt` | `post-audit/scripts/server_probes.sh` with random passwords | same as `post-audit/06`: all 16 probes recorded; same `LOAD_FILE`/`max_allowed_packet` and CHECK results |
| `05-rerun-catalogue-race-after-format-fix.txt` | the same driver after correcting the formatting of its `rand_pw` line (01 to 03 were recorded with that line broken over two lines; it removed the same characters) | same result |
| `04-iteration-harness-run.txt` | the harness against a throw-away server, helper built from this tree | 134 passed, 0 failed, 0 skipped |
| `linux/01-…` to `04-…` | unit tests, shell suites, repository checks, mutation (fresh export, no `.env`) | all exit 0; 187 unit checks; 31, 35, 21; 67 of 67 mutants killed |
| `linux/10-…` to `13-…` | `make up` on empty volumes (project `frt-c1-e4886d99`), `make doctor`, `make demo`, installation state | all exit 0 |
| `linux/20-make-test.txt` | `make test` | 8 of 8 suites; harness **134**/0/0 (incl. the 6 binary-protocol checks); database 18, 22, 24, 36, 24, 16, 3, 10; application 332 passed, 1 skipped |
| `linux/21-…`, `22-…`, `23-…` | `make examples`, `make test-integration`, `make test-app` | exit 0; 19, 8, 13, 30; 331 passed, 2 skipped |
| `native-windows/04-…` | Zig-built DLL in native MariaDB 13.0.2 | `campus_audit, ACTIVE, AUDIT, campus_audit.dll, 1.2.0, Beta, BSD` |
| `native-windows/02-…` | the helper (now with `--prepared`), `zig cc` as in CI | built |
| `native-windows/07-plugin-harness.txt` | the harness with a real denied path | 125 passed, 0 failed, 1 skipped (`/dev/full`, Linux only); the 6 binary-protocol checks pass natively |
| `native-windows/08-db-*.txt` | the nine database scripts | all exit 0 (one part of `test_log_import` skipped: it needs an absolute log path) |
| `native-windows/01-build-windows-ps1.txt` | `build_windows.ps1` with unit tests | DLL built; exit 1 because Smart App Control **blocked** `test_automatic_errors.exe` (not a test result; the CI Windows job runs all seven programs) |

Not run in this cycle: the Windows launcher suites (no launcher code changed), browser tests (no
web code changed).
