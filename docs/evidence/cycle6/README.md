# Improvement cycle 6 (17 November 2026)

Acts on a fresh independent shadow assessment of the cycle-5 head (`3166885`, whose CI run
44090286551 succeeded with 4 of 4 jobs, including the new MariaDB 11.8.9 job and the native Windows
DLL). Each finding was checked in the source before anything was changed. Raw outputs are unedited;
all runs were made locally on the project owner's PC.

| Finding | Change |
|---|---|
| 1.2.1 bounded only the wait for the plugin's own mutex. An update function still opened files and wrote records itself while the server held `LOCK_global_system_variables` | **plugin 1.2.2**. Check functions run before that lock (`set_var.cc:231-246`), so they open the file a new `campus_audit_file_path` or `campus_audit_reopen_now = ON` needs, and the update function swaps it in (`LogSink::swap`). `config_change` records are formatted in the update function and written by the same statement's STATUS event. Remaining: the `audit_gap` record after a recovery is written by the update function, into the file just opened |
| While the log was busy, a configuration change was applied with no trace: its record was dropped, and format, allocation and exception drops were counted but never announced by an `audit_gap` record | configuration records are no longer dropped; records lost without an I/O error are counted lock-free and merged into the count the next `audit_gap` record announces |
| The docs said each record is written "before the statement answers" | not true for statement records: MariaDB sends the GENERAL STATUS event after `protocol->end_statement()` (`sql_parse.cc:1914-1921`). Corrected in the README, `docs/plugin-api-notes.md` (section 9) and `docs/experiments.md` |
| Experiment 32b cited evidence files that do not exist under those names | corrected |
| The README's clone command used `&&`, which Windows PowerShell 5.1 does not have; a CI step name omitted two of its tests | corrected |

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test` | 7 programs, 192 checks (new: `GapAccounting::events_lost`, `LogSink::swap`), exit 0 |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` | 67 of 67 mutants killed |
| `03-plugin-build.txt` | `make -C plugin clean plugin`, MariaDB 13.0.2 headers, `-Wall -Wextra` | exit 0, no warnings |
| `04-repository-checks.txt` | `python3 scripts/check_repo.py && python3 tests/test_source_distribution.py` | both pass |
| `10-server-13.0.2.txt` | `bash scripts/test_server_version.sh mariadb:13.0.2-resolute@sha256:0e4bb0f3…` | plugin **1.2.2**: harness 134 passed, 0 failed, 0 skipped; thread pool 30 passed; stalled log 19 passed |
| `11-server-11.8.9.txt` | the same with `mariadb:11.8@sha256:d36f18d6…` (11.8.9) | plugin 1.2.2: 134 / 30 / 19 passed, 0 failed |

The stalled-log test now also sends `SET GLOBAL campus_audit_log_reads = ON` while the log is stalled.
The `SET` returns and the value is in effect at once; after draining, its `config_change` record is
in the log and no record was dropped. A first run of the new check sent `SHOW WARNINGS` on the same
connection after the `SET`. That second statement waited, because the thread was still writing the
`SET`'s STATUS record, which is the behaviour described above, so the check was changed to send the
`SET` alone (both runs: `10-server-13.0.2.txt` holds the second).

Not run in this cycle: the web application, database and browser suites (no code of theirs changed;
CI runs them on push); native Windows (CI job `windows-native` on push).
