# Improvement cycle 5 (17 November 2026)

Acts on a fresh independent shadow assessment of the cycle-4 head (`3208c75`). Each finding was
checked in the source before anything was changed. Raw outputs are unedited; all runs were made
locally on the project owner's PC.

| Finding | Change |
|---|---|
| An exception could leave a system-variable check or update function, or `init`, and terminate `mariadbd`; only the event callback was guarded | every function the server calls is registered through a guard (`guarded_check<>`, `guarded_update<>`, wrappers for `init` / `deinit`); a failure is counted in `Campus_audit_events_unexpected` and reported (`plugin/docs/error_handling.md`) |
| The cost of one global log mutex and a blocking `write()` inside the callback was never measured; nothing said what a log that stalls (rather than fails) does | experiment 32 (below). It found a defect: a stalled log spread from audited statements to the whole server through `SET GLOBAL campus_audit_*`. Fixed in **plugin 1.2.1**: functions that run under a server lock wait for the log at most 2 s (update) or 0.2 s (status), then give up with a warning or show `BUSY`. New test `tests/plugin/test_stalled_log.sh` |
| 11.8.9 support rested on a manual run only | `scripts/test_server_version.sh` (`make test-server-version MARIADB_IMAGE=...`) builds the project's image FROM any official image and runs the harness, the thread-pool test and the stalled-log test; CI job `server-11-8` runs it for 11.8.9 on every push |
| `docs/design-decisions.md` named interface `0x0303` only; `docs/experiments.md` said one environment applied to "every experiment below" | corrected |
| The README's test table did not say which tree each row ran on, and named green CI only for older commits | each row names its cycle; the CI row names the latest recorded run |

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test` | 7 programs, 184 checks, exit 0 |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` | 67 of 67 mutants killed |
| `03-plugin-build.txt` | `make -C plugin clean plugin`, MariaDB 13.0.2 headers, `-Wall -Wextra` | exit 0, no warnings |
| `04-repository-checks.txt` | `python3 scripts/check_repo.py && python3 tests/test_source_distribution.py` | both pass |
| `10-server-13.0.2.txt` | `bash scripts/test_server_version.sh mariadb:13.0.2-resolute@sha256:0e4bb0f3…` | plugin **1.2.1**: harness 134 passed, 0 failed, 0 skipped; thread pool 30 passed; stalled log 17 passed |
| `11-server-11.8.9.txt` | the same with `mariadb:11.8@sha256:d36f18d6…` (11.8.9) | plugin 1.2.1: 134 / 30 / 17 passed, 0 failed |
| `20-stall-and-contention.txt` | `scripts/stall_and_contention.sh` (an earlier version of the driver in `scripts/`; part 2 is unchanged), image of this tree **before** the bounded waits (version string 1.2.0) | part 1 as in 21 but without the global-variable probes; part 2: experiment 32c |
| `21-stall-lock-spread-1.2.0.txt` | `scripts/stall_and_contention.sh <image> 1`, the same image | experiment 32a: after `SET GLOBAL campus_audit_reopen_now` waited, global variables, `SET GLOBAL` and new connections got no answer for 5 s; everything recovered once the log was read again |
| `22-test-stalled-log-on-1.2.0.txt` | `tests/plugin/test_stalled_log.sh` against the image of the cycle-3 tree (plugin 1.2.0) | 7 passed, 10 failed: the test detects the defect |

A first run of the experiment driver was discarded: its 400 parallel clients exceeded
`max_connections`, so its probes measured refused connections, and its `mariadb-slap` parsing printed
the unit instead of the number. The driver was corrected before any result was recorded.

Not run in this cycle: the web application, database and browser suites (no code of theirs changed;
CI runs them on push); native Windows (CI job `windows-native` builds the DLL with the new
`TryAcquireSRWLockExclusive` path and runs the harness on push).
