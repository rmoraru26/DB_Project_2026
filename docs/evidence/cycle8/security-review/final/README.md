# Cycle 8, security review: final verification (20-21 November 2026)

The `campus_audit_file_path` protection after two independent reviews (`../README.md`): decisions on
the opened descriptor or handle; Linux and Windows rules in `docs/security.md`, "Which files the
audit log may be". Tree: `38aa30c` (plugin 1.2.4). Raw outputs are unedited.

## GitHub Actions

Run 44842611321 for `38aa30c`, **4 of 4 jobs successful** (read through the public API):

| Job | Result |
|---|---|
| Unit tests and static checks (unit tests and mutation check as a normal user) | success |
| make up / demo / test / browser tests on MariaDB 13.0.2 (Docker), incl. `make test-integration` with the stalled-log and log-path-safety tests | success |
| Plugin tests on MariaDB 11.8.9 (audit API 0x0302) | success |
| Build the DLL and load it into native Windows MariaDB 13.0.2: unit tests incl. the Windows attack cases, setup, demo, harness | success |

The runs before it failed, each for a reason that was then fixed:

| Commit | Failed | Cause |
|---|---|---|
| `d147cdc` | native Windows | not readable then; most likely the harness quoting bug below |
| `a1cf54c` | mutation check | the owner test needed root, so mutant S08 survived as a normal user |
| `9a25115` | native Windows unit tests | the Windows symbolic-link message did not match its test (the second review predicted this) |
| `bbf1077` | mutation check | S09: with two layers refusing symbolic links, removing one changed nothing; one shared `kNoFollow` constant now |
| `7fe440e` | native Windows end to end | first public annotations; the annotation step itself stopped at an empty `grep` |
| `e4814e1` | native Windows end to end | the harness wrote its foreign test file with a Windows path inside an SQL literal, so `C:\mdbdata\f...` was read as escapes; the plugin then rightly created a new log. Fixed with `QUOTE()` |

## Local runs (Linux, Docker)

| File | Run | Result |
|---|---|---|
| `01-unit-tests-normal-user.txt` | `make -C plugin clean test` as uid 1000 | 217 passed, 0 failed, 1 skipped (giving a file to another user needs root; the same rule is tested through `expect_owner_for_test`) |
| `02-unit-tests-root.txt` | the same as root | 219 passed, 0 failed, 0 skipped |
| `03-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` as uid 1000 | 77 of 77 killed |
| `10-server-13.0.2.txt` | `bash scripts/test_server_version.sh mariadb:13.0.2-resolute@sha256:0e4bb0f3…` | harness 141/0/0; thread pool 30/0; stalled log 19/0; log path safety 39/0 and, after a restart, 2/0 |
| `11-server-11.8.9.txt` | the same with `mariadb:11.8@sha256:d36f18d6…`, tree `38aa30c` | the same counts, 0 failed |
| `12-…`, `13-thread-pool-13.0.2-run*.txt` | `tests/plugin/test_thread_pool.sh` on 13.0.2, twice | 30/0 each. Before, it twice failed with ERROR 2002: its wait could end while the image's temporary initialisation server was running; it now also waits for a TCP login |

Native Windows did not run locally: Smart App Control blocks the freshly built, unsigned test programs
and DLL (`../20-native-windows-blocked.txt`). It was not disabled or bypassed. The Windows evidence
is the CI job above. The Windows code was also compiled locally with Zig 0.16.0 for both
`x86_64-windows-gnu` and `x86_64-linux-gnu` (`-Wall -Wextra`): no errors, no warnings.

## Remaining limitations

As in `docs/security.md`: the log directory is not restricted (any directory the server may write; a
symbolic link in a directory component is followed); an existing campus_audit log of the same OS user
is accepted (an older one, another instance's); the owner is not checked on Windows; rotation by
renaming the open log does not work on Windows; refusal messages reveal facts about reachable files;
owner and content checks are strict at startup; an existing log is never made readable later; a
FIFO's reader controls the plugin; the device/inode and `O_PATH` comparisons have no test.
