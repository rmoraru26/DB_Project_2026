# Evidence of the baseline assessment (13 and 14 November 2026)

Raw outputs of the read-only assessment of commit `19fd0a219930dd986eab5f9d53c1fe18c6ecd698`,
before any Phase 1 change. They were produced locally by an AI assistant from a `git archive` copy
of that commit, in an isolated Compose project on Docker Desktop (Windows 11), and are unedited
except that local paths are replaced by `<scratch>` and `<home>`.

| File | Content | Result |
|---|---|---|
| `01-up.txt`, `02-post-start.txt` | image build (the plugin's unit tests run in it), start, migrations, plugin | plugin `ACTIVE` |
| `03-demo.txt` | `scripts/demo.sh` | exit 0 |
| `04-test-runner.txt` | `scripts/run_test_suites.sh` in the test-runner container | 7 of 7 suites; harness 100 passed; application 292 passed, 3 skipped. The administrator was not provisioned in this run, so the administrator tests were among the skips |
| `05-win-*.txt` | the four Windows PowerShell suites | 12, 98, 10 and 8 checks pass |
| `06-experiments-*`, `07-experiments-*` | first measurements of stored procedures, prepared statements, `LOCK TABLES` and trigger/view DDL with plugin 1.1.1 | the coverage limits later analysed as experiments 21 and 22 of `docs/experiments.md` |
| `08-experiment-thread-pool.txt` | 12 connections, thread pool of 2, 360 `SET GLOBAL` | 360 attributed, 0 stray; now `tests/plugin/test_thread_pool.sh` |
| `09-examples.txt` | `examples/01` to `06` | only the deliberate errors |

Findings of that assessment that these files document and Phase 1 addressed: the advertised demo
login was rejected (HTTP 401); `.admin-credentials` was not git-ignored; the README described an
unfinished project; the booking catalogue was not loaded. The interpretation in `07-…` that trigger
DDL raises *no* event was corrected in Phase 1: it raises a read event.
