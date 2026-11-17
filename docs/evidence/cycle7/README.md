# Improvement cycle 7 (17 November 2026)

Acts on a fresh independent shadow assessment of the cycle-6 head (`61a0814`, plugin 1.2.2, whose CI
run 44094440392 succeeded with 4 of 4 jobs). Each finding was checked in the source first. Raw
outputs are unedited; all runs were made locally on the project owner's PC.

| Finding | Change |
|---|---|
| The README, `docs/testing.md`, `plugin/docs/error_handling.md` and `docs/plugin-api-notes.md` said update functions "do no log I/O at all"; two cases remain | each now says "normally" and names both: the `audit_gap` record after a recovery, and an open when another statement replaced the staged file in between (`docs/plugin-api-notes.md`, section 9) |
| Experiments 32a and 32c cited evidence files under names that do not exist | they cite `docs/evidence/cycle5/21-…` and `20-…` |
| Pending configuration records and the `log_this_statement` flag are thread-local; a connection that ended before its STATUS event could leave them to the next connection on the same thread | **plugin 1.2.3**: the DISCONNECT event (same thread) writes pending records and clears the flag |
| A file opened by the check function of `campus_audit_reopen_now` stayed open when the update gave up | closed at once (`discard_staged_sink`) |
| The plugin-only path was hard to find | a "15 minutes, plugin only" row in the README's "Start here" guide |

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test` | 192 checks, exit 0 |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` | 67 of 67 mutants killed |
| `03-plugin-build.txt` | `make -C plugin clean plugin`, MariaDB 13.0.2 headers | exit 0, no warnings |
| `04-repository-checks.txt` | `python3 scripts/check_repo.py && python3 tests/test_source_distribution.py` | both pass |
| `10-server-13.0.2.txt` | `bash scripts/test_server_version.sh mariadb:13.0.2-resolute@sha256:0e4bb0f3…` | plugin **1.2.3**: harness 134/0/0, thread pool 30/0, stalled log 19/0 |
| `11-server-11.8.9.txt` | the same with `mariadb:11.8@sha256:d36f18d6…` | plugin 1.2.3: 134 / 30 / 19 passed, 0 failed |

Not tested directly: a connection that ends between a `SET` and its STATUS event (no client can
reliably produce that order). Not run in this cycle: the web application, database, browser suites
and native Windows; CI runs them on push.
