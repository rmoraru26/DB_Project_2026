# CI runs on Linux (Docker) and Windows, 2026-11-03

The workflow `.github/workflows/ci.yml` ran on GitHub Actions in a private copy of this repository,
on GitHub-hosted runners:

- `ubuntu-24.04` (runner image 20261025.353.1) for the jobs `static` and `docker-integration`:
  Docker Engine with the project's own images (`docker/mariadb/Dockerfile` on
  `mariadb:13.0.2-resolute@sha256:0e4bb0f3…`, server `13.0.2-MariaDB-ubu2604`; `frontend/Dockerfile` on
  `python:3.13.17-slim`), browser tests with Playwright 1.55.0 and Chromium.
- `windows-2022` for `windows-native`: the official `mariadb-13.0.2-winx64.zip` and Zig 0.16.0, both
  pinned by URL and SHA-256.

Eight runs. The early ones found real problems, each fixed in the next commit:

| Run | Code | static | docker-integration | windows-native | Found |
|---|---|---|---|---|---|
| 1 | remediation as first pushed, plugin 1.1.0 | pass | hung in `make test`, cancelled after 70 min | fail: ERROR 2002 | a server-wide deadlock in `SET GLOBAL campus_audit_*` on Linux (experiment 18); a server started in one step of the Windows job was gone in the next |
| 2 | the deadlock fixed (thread-local mark), the Windows server started in the step that uses it, job time limits | pass | fail in the regression step; `make demo`, `make test` and `make test-browser` had also failed but showed as passed, because the steps piped into `tee` without `pipefail` | pass, 88/0/2 | `LOAD_FILE()` reads only files readable by all, so on Linux every import of the log failed (experiment 19); Docker Compose prefers exported shell variables over `.env` |
| 3 | the Makefile takes the secrets only from `.env`; `make doctor` names that cause | pass | fail: `make test-app` (the `LOAD_FILE()` cause) | pass | the `.env` fix worked |
| 4 | `campus_audit_readable_by_all` (ON in the Docker image); `pipefail` for every step | pass | pass | pass, 89/0/2 | nothing |
| 5 | documentation and evidence only | pass | pass | pass | nothing |
| 6 | the digest under `NO_BACKSLASH_ESCAPES` (a gap the independent review found in the code, experiment 20); `database_tests.sql` checked automatically | pass, 47/47 mutants | pass, 98/0/0 | fail before any project code ran: Zig's download index returned no entry for 0.16.0 | the Zig download is now pinned by URL and SHA-256, with retries |
| 7 | that change | - | - | - | no job ran: GitHub rejected the workflow file because of a YAML mistake in the edit |
| 8 | the YAML fixed; the delivered code (written afterwards: this directory, the documentation, and one corrected comment in `plugin/src/record_format.h`) | **pass** | **pass** | **pass**, 90/0/2 | nothing; every result below was read in the logs, not taken from the step status |

## Files (run 8 unless stated)

| File | What it shows |
|---|---|
| `00-make-up-and-doctor.txt` | fresh checkout: `make up` creates `.env`, builds both images, initialises the volume and installs the plugin; `make doctor`: all checks OK |
| `01-make-demo.txt` | `make demo`: `campus_audit.so` 1.1.1 ACTIVE, the events it causes, the import of the log, the views |
| `02-make-test.txt` | plugin unit tests (97 checks); `check_repo.py`; end-to-end tests **98 passed, 0 failed, 0 skipped**; password-hash helper 3/3; `database_tests.sql` with its expected errors 10/10; web app and Audit Lab tests with the database **104 passed, 1 skipped** (the browser module, Playwright is not installed in the web image) |
| `03-make-examples.txt` | examples 01-06 (02, 04 and 05 contain deliberate errors); 06 loads the tutorial plugin, built in the image, next to campus_audit |
| `04-make-test-browser.txt` | the 11 browser tests against the web container: **11 passed** |
| `05-restart-and-regression.txt` | `docker compose restart mariadb`: the plugin comes back; then the old `.env` stays exported, a new `.env` is created, `make up` refuses and explains, `make doctor` names the root ER 1045, `make repair-credentials`, `make doctor` all OK, the number of users is unchanged, app tests 104 passed |
| `06-…`, `07-…`, `08-…` | the three outputs of that regression step: the `make_env.sh` warning, the refusing `make up`, `make doctor` |
| `09-static-job.txt` | job `static`: unit tests, mutation check **47 of 47 killed**, the missing-headers failure, script syntax, app tests without a database (80 passed, 25 skipped), `check_repo.py` |
| `10-windows-job.txt` | job `windows-native`: Zig build of the DLL and the CHANGE_USER helper, unit tests, setup, demo, end-to-end tests **90 passed, 0 failed, 2 skipped**, server log |
| `11-earlier-runs.txt` | excerpts of runs 1-3: the hang, ERROR 2002, `LOAD_FILE()` returning NULL, the ER 1045 of the web container |
| `docs/screenshots/` | the ten screenshots this run's browser tests took against the Docker stack (server 13.0.2-MariaDB-ubu2604, `campus_audit.so`) |

Linux runs 8 end-to-end checks that Windows skips: the permission-denied path and the `/dev/full`
block (a statement succeeds while the log cannot be written, state DEGRADED, the failure counted and
explained, an `audit_gap` record after recovery). The 90 other checks are the same on both.

The secrets were random per run and never printed; every file here was scanned for strings of their
form. Paths of the private copy are replaced by `<repo>`, GitHub's timestamps removed, and the
warnings that Zig printed about its own bundled libc++ headers while compiling it on the runner's empty
cache (none about this project's files) removed from `10-windows-job.txt`; the file says how many.
