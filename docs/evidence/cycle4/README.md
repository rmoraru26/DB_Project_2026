# Improvement cycle 4 (17 November 2026)

Acts on a fresh independent shadow assessment of the cycle-3 head (`0cb8866`). Each finding was
checked in the source before anything was changed. Raw outputs are unedited; all runs were made
locally by the AI assistant on the project owner's PC.

| Finding | Change |
|---|---|
| `try_open_log()` was compiled into the plugin but never called by it; only three unit-test cases used it | removed with those three cases (the plugin's real open path, `LogSink::open()` with `validate_log_path()`, has its own tests); the original program is `plugin/exploratory/interactive_open_log.cpp`. `docs/design-decisions.md` said the log sink used it; corrected |
| The check function of `campus_audit_file_path` creates the file it probes | kept, now documented with the reason (`plugin/docs/error_handling.md`): deleting a file from inside the server after an existence check could delete a file another process created in between |
| Experiment 31's row was cut off from its table; section "7a" stood before "7" | fixed; the section is now 8 |
| `examples/06_skeleton_plugin.sql` still said "about 60 lines" | about 50 lines of code |
| `docs/database_testing.md` reported results without a source | names `database/database_tests.sql`, how `tests/database/run_database_tests.sh` checks it, and the latest run |
| A newcomer has to find the plugin inside a large README | a three-line "Start here" guide (5 minutes / 15 minutes / 1 hour) under the first screenshot |

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test` | 7 programs, 184 checks (75, 23, 10, 1, 4, 8, 63), exit 0 |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` | 67 of 67 mutants killed, exit 0 |
| `03-plugin-build.txt` | `make -C plugin clean plugin` against the MariaDB 13.0.2 headers | exit 0; `try_open_log` is not among the library's symbols |

The full suites run in GitHub Actions on push (Docker end to end and native Windows).
