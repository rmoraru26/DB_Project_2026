# Evidence of the Phase 1 verification (15 and 16 November 2026)

Raw outputs of the runs made while the Phase 1 changes were implemented. They are unedited except
that local paths are replaced by `<scratch>` and `<home>`.

**What was tested.** The working tree of the branch `improvement/frantastic-37plus`: commit
`19fd0a219930dd986eab5f9d53c1fe18c6ecd698` plus the Phase 1 changes, which were **not committed**
when these runs were made. The tree was exported exactly as a commit of it would be checked out
(tracked and new files, ignore rules and line-ending attributes applied) and tested from that copy.
The final regression in `linux/` and the first `windows-launcher/` run (files `01` to `05`) used
the export with Git tree id `3e58ad5b0d5258359c2eab64e93d69b378d8667b`. Afterwards the Windows
source packager (`scripts/package_windows_source.py`) and its test (`tests/test_source_distribution.py`)
were changed so that the archive contains the new documents; the runs in `linux-rerun-2026-11-17/`
and `windows-launcher/06-…`, `07-…` are of that state (Git trees `9ee2339…` on Linux and `0cd9e5a…`
on Windows, which differ only in documentation and evidence files).

**Read the status lines with care.** The scratch script that drove the Linux runs wrote
`# exit status: 0` into every file of `linux/` and into `linux-rerun-2026-11-17/01` to `04`: it
recorded the status of an `echo`, not of the command. Each step was therefore checked again by its
output (`checks/step-verification-by-content.txt`). That check found one failure, step 03 (below).

**The host restarted** between 16 and 17 November (the Windows build changed from 10.0.26100 to
10.0.26200). Docker Desktop was stopped and all test containers exited with status 255; every volume
survived. Docker Desktop was started again; `make up` and `frantastic.cmd up` restarted the same two
test projects without rotating a credential (`linux-rerun-2026-11-17/33-…`, `windows-launcher/06-…`).

**Who ran it.** All runs here were made locally by the AI assistant that implemented the changes,
on the project owner's PC. None of them is a GitHub Actions run, and none was repeated by a team
member. The only CI evidence is for the commit *before* these changes
(`checks/github-actions-runs-for-19fd0a2.txt`).

## Environments

| Label | Environment |
|---|---|
| Linux host | a container (Alpine, GNU bash 5.2, GNU make 4.4.1, g++ 14.2, Python 3.12) with the Docker CLI 27.5.1 and Compose 2.33.0, driving the engine of Docker Desktop 29.9.3 on Windows 11 through its socket, exactly as a Linux developer machine drives its engine. The project ran as its own Compose project (`frt-p1-79c0601b`) with its own images, volumes and ports. Server: `13.0.2-MariaDB-ubu2604` from the pinned image |
| Windows launcher | Windows 11 Pro 10.0.26100, Windows PowerShell 5.1.26100, Docker Desktop 29.9.3 (Linux containers); a default Git-for-Windows checkout (CRLF) in a path with a space; Compose project `frt-p1w-79c0601b` |
| Native Windows | the official `mariadb-13.0.2-winx64.zip` and Zig 0.16.0, both downloaded from the URLs and verified against the SHA-256 values of `.github/workflows/ci.yml`; a throw-away data directory, server bound to 127.0.0.1 |
| Browser | `mcr.microsoft.com/playwright/python:v1.55.0-noble` (Chromium, headless) on the Compose network of the Linux-host stack |

Smart App Control is enforced on the PC. It refused to start some freshly built, unsigned
executables. This affected only the native unit-test executables (see `windows-native/`); it was
not circumvented.

## Results

| Files | Run | Result |
|---|---|---|
| `linux/01-unit-tests.txt` | `make -C plugin clean test`, g++ | 7 programs, 184 checks (72, 23, 13, 1, 4, 8, 63), all pass |
| `linux/02-shell-tests.txt` | the three shell suites on a Linux file system | 31, 35 and 21 pass |
| `linux/03-repository-checks.txt`, `linux-rerun-2026-11-17/03-repository-checks.txt` | `scripts/check_repo.py`, `tests/test_source_distribution.py`, run in the directory of the running test installation | **FAIL** in both runs: "credential-like file is tracked: .env, .demo-credentials, .admin-credentials, .env.previous". The directory has no `.git`, so the check falls back to listing the files present, and that installation's secrets are present. The check behaves as designed; the step ran in the wrong place. Repeated correctly on a clean export without secrets: **pass** (`linux-rerun-2026-11-17/03-repository-checks-clean-export.txt`). The same checks also pass inside the test-runner container (`20-make-test.txt`, both runs) and in the Git worktree on Windows |
| `linux/04-mutation-check.txt` | `scripts/mutation_check.py` | 65 of 65 mutants killed |
| `linux/10-make-up-fresh.txt` to `13-fresh-install-checks.txt` | `make up` on empty volumes, `make doctor`, `make demo`, state of the installation | all exit 0; both credential files mode 600; demo student logs in (student, `/admin/audit` 403), administrator logs in (200); 54 catalogue items, 18 types, 5 catalogue rooms; plugin `ACTIVE 1.2.0 Beta BSD` |
| `linux/20-make-test.txt`, `linux-rerun-2026-11-17/20-make-test.txt` | `make test` | 8 of 8 suites pass in both runs (a first re-run failed in "Repository checks" on an assertion added that day which named the test run's own override file `compose.p1.yaml`; the assertion was corrected, not the tree): plugin harness 128 passed, 0 failed, 0 skipped; database scripts 18, 22, 24, 30, 18, 16, 3, 10; web application 332 passed, 1 skipped |
| `linux/21-make-examples.txt` | `make examples` | 7 examples ran; only the deliberate errors |
| `linux/22-make-test-integration.txt`, `linux/lifecycle/` | `make test-integration` | demo-credential life cycle 19, log rotation 8, thread pool 30 checks pass |
| `linux/23-make-test-app.txt` | `make test-app` (web container) | 331 passed, 2 skipped |
| `linux/24-browser-tests.txt` | Playwright browser tests | 11 passed |
| `linux/25-pages-three-widths.txt` | 16 pages at 1280, 768 and 390 px | expected status everywhere; 0 px horizontal overflow; 0 console errors (basis of `docs/visual-qa.md`) |
| `linux/30-restart.txt` | `docker compose restart mariadb`, `make up`, `make doctor` | pass; both credential files unchanged; both logins work |
| `linux/31-volume-recreated.txt` | `make reset`, then `make up` with the saved credential files | both accounts created in the new database with the saved passwords; files unchanged; logins work; catalogue present |
| `linux/32-stale-env.txt` | a new `.env` against the existing volume, `make repair-credentials` | refused and explained; repaired; 5 user rows before and after; `make test-app` 331 passed |
| `linux/40-benchmark.txt`, `.csv` | `make bench`, 2 000 INSERTs, 2 passes x 5 runs | campus_audit +17.9 % and +29.5 %, server_audit +36.0 % and -17.1 % against no plugin: on this machine the noise is larger than any difference; 553 bytes of log per audited INSERT |
| `linux/90-secret-scan.txt` | search of every Linux output for the 8 generated secrets | 0 found |
| `windows-launcher/06-…`, `07-…` | after the host restart and the packager change: `frantastic.cmd up`, `frantastic.cmd test` | both exit 0; no rotation; 8 of 8 suites; ACL, URL, hardening (98), launcher end-to-end (14) and demo-credential (37) tests pass |
| `checks/step-verification-by-content.txt` | every recorded step checked by its output instead of its status line | all OK except the two step-03 files described above |
| `windows-launcher/01-…` to `05-…`, `10-summary.txt` | `frantastic.cmd up` (fresh), `up` again, `demo`, `test`, `reset-demo` | all exit 0. Owner-only ACL on `.env` and both credential files; second `up`: no rotation, files unchanged; `test`: ACL 8, URL 10, hardening 98, launcher end-to-end 14, demo credentials 37 checks, then 8 of 8 suites (128 harness checks, 332 application tests); `reset-demo`: new file, login works, administrator file unchanged; none of 5 secrets in any output |
| `windows-native/02-…`, `04-…` | `plugin\build_windows.ps1 -SkipTests`; the seven test programs compiled with Zig | DLL built, exit 0, no output on stderr; all seven compile and link |
| `windows-native/01-…excerpt.txt` | the first run of the build script *with* tests | the DLL was built; the first Zig-built test executable was refused by Smart App Control ("An Application Control policy has blocked this file"), so the script exited 1. Not a build or test failure |
| `windows-native/05-unit-tests-windows-gxx.txt` | the seven programs built with MSYS2 g++ 15.2 and run natively, as `-O2` and as `-O2 -DNDEBUG` | every program ran and passed in at least one of the two builds (72, 19, 13, 1, 4, 8, 63 checks); four of the fourteen executables were refused by Smart App Control (exit 126), which is not a test result |
| `windows-native/06-…`, `07-…` to `10-…` | the Zig-built DLL in a native MariaDB 13.0.2: `INSTALL SONAME`, `scripts/setup_database.sh`, `scripts/demo.sh`, the end-to-end harness | `campus_audit, ACTIVE, AUDIT, campus_audit.dll, 1.2.0, Beta, BSD`; setup and demo exit 0; harness **110 passed, 0 failed, 3 skipped** (the permission-denied path, CHANGE_USER without its helper, `/dev/full`) |
| `checks/repository-guards-mutation.txt` | 12 ways of breaking what `scripts/check_repo.py` guards | 12 of 12 detected |
| `checks/git-history-secret-scan.txt` | all 46 commits of all 19 refs | no credential file was ever committed; the flagged assignments are references to variables in scripts; the private-key markers are the detection strings of a test; hashes of the formerly published demo password exist only in the history of the private staging repository |
| `checks/github-actions-runs-for-19fd0a2.txt` | GitHub API, 16 November 2026 | runs 43534005238 (push) and 43534008497 (pull request): completed, success, three successful jobs each, both for `19fd0a2` |
| `experiments/` | the measurements behind experiments 21 to 29 of `docs/experiments.md` | see there |
| `stack-logs/` | the MariaDB server logs of the two test stacks (`frt-p1-…` Linux host, `frt-p1w-…` Windows launcher) at the end of all runs, and each stack's final plugin state | no `[ERROR]` line; warnings only for the Beta maturity, `loose_` options read before the first `INSTALL SONAME`, the harness's deliberate failed login and Docker Desktop's `io_uring` restriction; plugin `ACTIVE`, 0 events dropped, 0 write failures; the two generated accounts with the roles admin and student. The web containers wrote no log lines |
| `linux/20-make-test.txt`, `linux-rerun-2026-11-17/03-repository-checks-clean-export.txt`, `windows-launcher/04-…`, `07-…` | `tests/test_source_distribution.py` (inside "Repository checks") | passed: documented JSONL included, exclusions enforced, frontend test files complete, ZIP extracted in a path with a space, removal of the sample detected. **Not verified in any of these runs:** collection of the frontend tests from the extracted archive (the interpreter that ran the check had no pytest, Flask, PyMySQL, python-dotenv or Werkzeug; the check says so in its own output). *Correction (post-audit, 17 November 2026):* an earlier version of this row cited `linux/26-source-distribution.txt` and an archive of "310 files"; that file was never recorded and the count is withdrawn. For the post-audit run see `post-audit/` |

**Post-audit remediation (17 November 2026):** the fixes made after the independent audit and
their runs are in `post-audit/` (own README); the final staging-readiness check is in
`closeout/` (own README); the last full run of the finished tree before the commit is in
`final-verification/` (own README). The counts in the table above are those of the
Phase 1 runs and were not changed, except the withdrawn archive count (see the source-distribution
row).

Not in this folder because it was not done: any run on macOS, on a Linux machine without Docker,
or in GitHub Actions for the Phase 1 tree; CHANGE_USER on native Windows (its helper was not built);
the `windows-native/` run of the database test scripts.

Two files in `experiments/` record states that no longer exist and are kept on purpose:
`23-scope-session-first-version.txt` and `25-trigger-body-and-quit-before-the-rule-was-tightened.txt`
show the first version of the scope `SESSION`, which recorded a trigger's body statement and the
`Quit` command; the rule was changed because of them.

## Reproducing

```bash
make up && make doctor && make demo
make test
make test-integration
make test-browser
make mutation
```

On Windows: `.\frantastic.cmd up`, `demo`, `test`, `reset-demo`. Native: the commands of the
`windows-native` job in `.github/workflows/ci.yml`.
