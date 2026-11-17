# Final local verification (17 November 2026)

Raw outputs of the last complete verification before the Phase 1 changes were committed. The
tested source is the working tree of `improvement/frantastic-37plus` (baseline
`19fd0a219930dd986eab5f9d53c1fe18c6ecd698` plus all Phase 1 and post-audit changes), exported
exactly as a commit of it is checked out: Git tree `28f2fc096d2e8c883866f45e8e88d84fedfc7975`,
LF endings for Linux, a Git-for-Windows (CRLF) checkout for Windows. Outputs are unedited except
that local scratch paths are replaced by `<scratch>`, `<scratch-root>` and `<scratch-p1>`.
Every `# exit status` line is the status of the command itself. All runs were made locally by the
AI assistant on the project owner's PC; none is a GitHub Actions run.

Two defects were found during this pass and fixed before the commit; the failing runs are kept:

* `scripts/rotate_log.sh`: after a failed reopen it renamed the archive back but left the plugin
  `DEGRADED` (no new records until a later retry), while claiming the plugin "still writes".
  Found by `../closeout/06a-…`; fixed (it now reopens the original file at once and reports the
  state); `../closeout/06-…` 10 of 10.
* `tests/integration/test_log_rotation.sh` compared all rows of the plugin instance with only the
  two newest files, so it failed whenever that instance had been rotated before (`linux/27a-…`:
  "files 277, table 286"; all 288 records of the instance were in fact imported exactly once).
  Fixed to compare exactly the `seq` values of the two files; `linux/27-…run1`, `run2`: 8 of 8.

Tree `28f2fc09` was tested before these two fixes; the files they touched were re-tested
afterwards (`linux/26-…`, `linux/27-…`, `../closeout/06-…`). No other source file changed after
the full runs.

## Environments

| Label | Environment |
|---|---|
| Linux | Compose project `frt-final-28f2fc09` (own images, volumes, ports 27307/27080), driven from a container with GNU bash 5.2, GNU make 4.4.1, g++ 14.2, Python 3.12, Docker CLI 27.5.1, Compose 2.33.0, talking to Docker Desktop 29.9.3 on Windows 11 10.0.26200; server `13.0.2-MariaDB-ubu2604` |
| Windows launcher | Windows PowerShell 5.1, Compose project `frt-finalw-28f2fc09` (ports 23327/25091) in a copy in a path with a space |
| Native Windows | official `mariadb-13.0.2-winx64.zip` and Zig 0.16.0 (SHA-256 equal to the values in `.github/workflows/ci.yml`, `native-windows/00-…`), throw-away data directories, loopback only; MSYS2 g++ 15.2 for the extra unit-program builds |
| Browser | `mcr.microsoft.com/playwright/python:v1.55.0-noble`, Chromium headless, on the network of `frt-final-28f2fc09` |

The two recovered stacks `frt-p1-79c0601b` and `frt-p1w-79c0601b` were not used or changed.

## Results

| Files | Run | Result |
|---|---|---|
| `linux/01-unit-tests.txt` | `make -C plugin clean test` | **PASSED**: 7 programs, 187 checks (75, 23, 13, 1, 4, 8, 63) |
| `linux/02-shell-tests.txt` | shell suites | **PASSED**: 31, 35, 21 |
| `linux/03-repository-checks.txt` | `check_repo.py`, `test_source_distribution.py` (clean export, no `.env`) | **PASSED**; frontend test collection from the archive **NOT RUN** (no pytest in that interpreter; the test says so) |
| `linux/04-mutation-check.txt` | `scripts/mutation_check.py -j 6` | **PASSED**: 67 of 67 killed |
| `linux/10-…` to `13-…` | `make up` on empty volumes, `make doctor`, `make demo`, installation state | **PASSED**: credential files mode 600; demo student logs in, `/admin/audit` 403; administrator 200; 54 catalogue items; plugin `ACTIVE 1.2.0 Beta BSD` |
| `linux/20-make-test.txt` | `make test` | **PASSED**: 8 of 8 suites; harness 128/0/0; database 18, 22, 24, 36, 24, 16, 3, 10; application 332 passed, 1 skipped (the browser module) |
| `linux/21-make-examples.txt` | `make examples` | **PASSED** (only the deliberate errors) |
| `linux/22-make-test-integration.txt`, `linux/lifecycle/` | `make test-integration` | **PASSED**: demo life cycle 19, log rotation 8, log import limits 13, thread pool 30 |
| `linux/23-make-test-app.txt` | `make test-app` (web container) | **PASSED**: 331 passed, 2 skipped |
| `linux/26-…` | `test_log_import_limits.sh` after the `rotate_log.sh` fix | **PASSED**: 13 of 13 |
| `linux/27a-…`, `27-…run1`, `run2` | `test_log_rotation.sh` on the same stack, before and after the test fix | 27a **FAILED** (test defect, above); run1, run2 **PASSED** 8 of 8 |
| `browser/24-browser-tests.txt` | `pytest tests/browser` | **PASSED**: 11 of 11 (`browser/failed-attempt-1/`: the driver had not installed PyMySQL; not a product result) |
| `browser/25-pages-three-widths.txt` | 16 pages at 1280, 768, 390 px | **PASSED**: 48 page views, expected status on each (403 and 404 pages included), 0 px horizontal overflow, 0 console errors |
| `windows-launcher/01-…` to `05-…`, `10-summary.txt` | `frantastic.cmd up` (fresh), ACLs, logins, `up` again, `demo`, `test`, `reset-demo` | **PASSED**: owner-only DACL on `.env` and both credential files; demo login (admin 403), administrator login; second `up` rotates nothing; `test`: ACL 8, URL 10, hardening 98, end-to-end 14, demo credentials 37, then 8 of 8 suites (harness 128/0/0, application 332 passed, 1 skipped); `reset-demo`: new file, owner-only, login works, administrator file unchanged. The last line of `10-summary.txt` is an error of the step script itself (its secret check read a file that `Tee-Object` held open); the secret check was repeated separately: 0 of 18 secrets in any output |
| `native-windows/01-build-windows-ps1.txt`, `01c-…` | `plugin\build_windows.ps1` (DLL and unit tests, as in CI) | DLL **built**; exit 1 because Smart App Control **BLOCKED** `test_error_reporter.exe`, after which the script stops; `test_automatic_errors` **PASSED** (13) |
| `native-windows/02-…` | CHANGE_USER helper (`zig cc`, as in CI) | **built** |
| `native-windows/04-install-soname.txt` | `INSTALL SONAME 'campus_audit'` in native MariaDB 13.0.2 | **PASSED**: `campus_audit, ACTIVE, AUDIT, campus_audit.dll, 1.2.0, Beta, BSD` |
| `native-windows/05-…`, `06-…` | `scripts/setup_database.sh`, `scripts/demo.sh` | **PASSED** |
| `native-windows/07-plugin-harness.txt` | end-to-end harness | **PASSED**: 118 passed, 0 failed, 2 skipped (permission-denied path without `AUDIT_TEST_DENIED_PATH`; `/dev/full`) |
| `native-windows/10-plugin-harness-denied-path.txt` | the harness again with `AUDIT_TEST_DENIED_PATH` in `C:\Windows\System32` (not writable, non-elevated) | **PASSED**: 119 passed, 0 failed, 1 skipped (`/dev/full`, Linux only) |
| `native-windows/08-db-*.txt` | the nine database test scripts against native Windows MariaDB (first native run) | **PASSED**: legacy admin migration (2 statements, exit 0), cancelled loans 18, triggers 22, grants 24, demo student 35 (no installed demo account natively, so one check less than on Linux), catalogue 24, log import 14 + 1 skipped (the invalid-line part needs an absolute log path; the native server uses a relative one), password-hash helper 3, constraint checks 10 |
| `native-windows/unit-programs/*.txt` | each unit program built separately with Zig (CI flags) and MSYS2 g++ `-O2`, then run | see the next table |
| `native-windows/11-smart-app-control-blocks.txt` | Windows Code Integrity log (`Get-WinEvent`) | 12 blocks (events 3077/3033, policy `{0283ac0f-fff1-49ae-ada1-8a933130cad6}`, Smart App Control "On"), all test executables built in this run; **0** events for `campus_audit.dll`, `mariadbd.exe`, the clients or the CHANGE_USER helper |

### Native Windows unit programs

A program counts as passed only if one of its native builds actually ran and passed. Smart App
Control blocks unsigned executables without reputation; it was neither disabled nor bypassed.

| Program | Zig (CI flags) | MSYS2 g++ -O2 | Other build | Native result |
|---|---|---|---|---|
| `test_record_format` | ran, 75 PASS | BLOCKED | – | **PASSED** (75) |
| `test_log_sink` | BLOCKED | ran, 19 PASS (4 POSIX-only checks not compiled on Windows) | – | **PASSED** (19) |
| `test_automatic_errors` | ran, 13 PASS (also in `build_windows.ps1`) | BLOCKED | – | **PASSED** (13) |
| `test_error_reporter` | ran, 1 PASS; BLOCKED inside `build_windows.ps1` (a separate binary) | BLOCKED | – | **PASSED** (1) |
| `test_runtime_config` | ran, 4 PASS | BLOCKED | – | **PASSED** (4) |
| `test_gap_accounting` | BLOCKED | ran, 8 PASS | – | **PASSED** (8) |
| `test_statement_scope` | BLOCKED | BLOCKED | g++ `-O0` BLOCKED, g++ `-O1` ran, 63 PASS | **PASSED** (63), only in the `-O1` build |

Every blocked binary, with its path, parent process and SHA-256, is listed in
`native-windows/11-smart-app-control-blocks.txt`. Blocked: the build script's
`test_error_reporter.exe` (parent `powershell.exe`); `zig-test_log_sink`, `zig-test_gap_accounting`,
`zig-test_statement_scope`, `gxx-test_record_format`, `gxx-test_automatic_errors`,
`gxx-test_error_reporter`, `gxx-test_runtime_config`, `gxx-test_statement_scope`, `st-gxx-O0`
(parent Git Bash `bash.exe`). The build commands are in `scripts/native.sh` and
`scripts/native_unit.sh`. The Zig builds of all seven programs are run by `build_windows.ps1` in
the `windows-native` job of `.github/workflows/ci.yml` (hosted `windows-2022` runner, where Smart
App Control does not apply); that run is the evidence for the Zig binaries that were blocked here.

## Not run

GitHub Actions for these changes (they run on push); macOS; a Linux host without Docker;
`/dev/full` on Windows (no such device); `make bench`.

`scripts/` holds the drivers as they were run.
