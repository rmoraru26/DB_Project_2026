# Improvement cycle 8 (17 November 2026)

Acts on the independent shadow assessment of the cycle-7 head (`dce0a16`, plugin 1.2.3, whose CI run
44097222910 succeeded with 4 of 4 jobs). Raw outputs are unedited; all runs were made locally on the
project owner's PC.

| Finding | Change |
|---|---|
| `SET GLOBAL campus_audit_file_path` accepted any existing file the server could write. The plugin appended JSON to it and, with `campus_audit_readable_by_all` (on in Docker), added read permission for every OS user, e.g. for `mysql/global_priv.MAD`. That needs `SYSTEM_VARIABLES_ADMIN`, not `FILE` | **plugin 1.2.4**: `LogSink::open` refuses an existing regular file unless it is empty or begins with a campus_audit record (`{"ts":"`, possibly after the newline of an `audit_gap` record). The refusal comes before any write or `fchmod`, with the reason; `SET GLOBAL` fails with ER 1231 and the old file stays active. A FIFO or a device is still accepted. Documented in `docs/security.md` ("Tamper evidence") |

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test` | 199 checks (new: a foreign file is refused, says why, stays unchanged and keeps mode 0600; an empty file and a log that begins with a newline are accepted), exit 0 |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` | 71 of 71 mutants killed (new S04-S07 on the check) |
| `03-plugin-build.txt` | `make -C plugin clean plugin`, MariaDB 13.0.2 headers | exit 0, no warnings |
| `04-repository-checks.txt` | `python3 scripts/check_repo.py && python3 tests/test_source_distribution.py` | both pass |
| `10-server-13.0.2.txt` | `bash scripts/test_server_version.sh mariadb:13.0.2-resolute@sha256:0e4bb0f3…` | plugin **1.2.4**: harness 137 passed, 0 failed, 0 skipped (3 new: a file made by `SELECT … INTO OUTFILE` in the test directory is refused with ER 1231 and the reason, and is unchanged); thread pool 30/0; stalled log 19/0 |
| `11-server-11.8.9.txt` | the same with `mariadb:11.8@sha256:d36f18d6…` | plugin 1.2.4: 137 / 30 / 19 passed, 0 failed |

The harness never points the plugin at a real data file: the foreign file is created by the server in
the test directory. Not run in this cycle: the web application, database and browser suites and native
Windows; CI runs them on push.
