# Phase 1 closeout check (17 November 2026)

Raw outputs of the final staging-readiness check of the uncommitted working tree of
`improvement/frantastic-37plus` (baseline `19fd0a219930dd986eab5f9d53c1fe18c6ecd698`), made
locally by the AI assistant after the post-audit remediation (`../post-audit/`). Not a CI run.

| File | What | Result |
|---|---|---|
| `01-evidence-paths.txt` | every `docs/evidence/...` path and every relative evidence name cited in README.md, `docs/*.md` and the evidence READMEs | all exist; 3 expected "missing" lines, explained at the end of the file |
| `02-repository-checks.txt` | `check_repo.py`, `test_source_distribution.py`, `git diff --check`, trailing blanks, website files against `19fd0a2`, the two submission worktrees | all exit 0; website files unchanged; `DB_Project_2026-submission-review` has no status entry. The last line for `DB_Project_2026-windows` (no files changed since 14 November) ends in a `stat` error of the command itself, not of the worktree |
| `03-secret-scan.txt` | the change set searched for the 13 generated secrets of the two test stacks, for private-key markers and real-looking Werkzeug hashes | nothing found |
| `05a-final-repository-checks-bad-path.txt` | the checks of file 02 again after `docs/testing.md` was updated | **failed** (exit 1): the new text named `scripts/p1_1_recovery.sh` instead of its full path; kept because it happened |
| `05-final-repository-checks.txt` | the same after correcting that path | `check_repo.py`, `test_source_distribution.py`, `git diff --check` exit 0; no trailing blanks |
| `04-docker-store-read-only.txt` | Docker Desktop when the P1-1 failure-path scenarios were to run | `read-only file system` for every create or remove; no new container possible |

| `06a-p1-1-recovery-found-degraded-after-undo.txt` | `scripts/p1_1_recovery.sh`, first run after the Docker recovery | **9 passed, 1 failed**: recovery of an oversized archive left by the pre-fix script (with the documented `--import`), failure in the middle of a parts import and its retry all pass; after a failed reopen `rotate_log.sh` renamed the archive back but the plugin stayed `DEGRADED` and wrote no new record. A real defect of `rotate_log.sh` (and of its comment "the plugin still writes") |
| `06-p1-1-recovery.txt` | the same script after the fix (`rotate_log.sh` now reopens the original file at once and reports the plugin state) | **10 passed, 0 failed** |

`scripts/p1_1_recovery.sh` verifies three P1-1 failure paths: an oversized archive left by the
pre-fix script and recovered with the documented `--import`; a failure in the middle of a parts
import; a failed reopen. It could not run when file 04 was recorded; it ran after Docker Desktop
was recovered (files 06a and 06):

```bash
bash docs/evidence/phase1/closeout/scripts/p1_1_recovery.sh frt-p1-79c0601b-mariadb:13.0.2 <backup>/scripts/rotate_log.sh
```

Its passwords exist only inside the throw-away container it creates and removes. The final full
verification is in `../final-verification/`.
