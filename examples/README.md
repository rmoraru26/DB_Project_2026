# Examples: learn the plugin in ten minutes

Six short SQL files, meant to be read and run in order. Each one starts with a comment that says
what it shows, what it needs and where its real output is recorded. They use only statements that the
end-to-end tests (`tests/plugin/run_plugin_tests.sh`) and the demo (`scripts/demo.sh`) already ran
against MariaDB 13.0.2.

| File | You learn | Real output |
|---|---|---|
| [`01_install_and_verify.sql`](01_install_and_verify.sql) | A server plugin is installed with `INSTALL SONAME`; `information_schema.PLUGINS` shows type `AUDIT` and status `ACTIVE`; the plugin adds 8 system and 11 status variables | [`demo-windows.txt`](../docs/evidence/demo-windows.txt) step 1 |
| [`02_cause_events.sql`](02_cause_events.sql) | A booking, a *rejected* statement and a rolled-back change look different to an audit plugin than to a trigger | [`sample-records.jsonl`](../docs/evidence/sample-records.jsonl) |
| [`03_read_the_log.sql`](03_read_the_log.sql) | The log is JSON Lines; `import_plugin_log()` and the views join it with the trigger-based row history | [`demo-windows.txt`](../docs/evidence/demo-windows.txt) steps 3-8 |
| [`04_configure_and_break_it.sql`](04_configure_and_break_it.sql) | Dynamic variables, filtering, and what the plugin does with invalid values (ER 1231, old value kept) | [`plugin-tests-windows.txt`](../docs/evidence/plugin-tests-windows.txt) |
| [`05_unload.sql`](05_unload.sql) | The shutdown path: `plugin_stop` record, clean `UNINSTALL`, reinstall as a new instance | [`plugin-tests-windows.txt`](../docs/evidence/plugin-tests-windows.txt) |
| [`06_skeleton_plugin.sql`](06_skeleton_plugin.sql) | **Write your own:** the 60-line tutorial plugin [`skeleton_plugin/`](skeleton_plugin/README.md) loaded next to campus_audit, counting every event the server hands it | [`12-skeleton-plugin.txt`](../docs/evidence/windows-2026-11-03/12-skeleton-plugin.txt) |

## Run them

With Docker (after `make up`; run in CI on 2026-11-03, output in
[`03-make-examples.txt`](../docs/evidence/linux-ci-2026-11-03/03-make-examples.txt)):

```bash
make examples
```

Against any MariaDB 13.0.x server with the plugin library in `@@plugin_dir` (this is the path that was executed):

```bash
mariadb --force --table -uroot -p < examples/01_install_and_verify.sql
mariadb --force --table -uroot -p < examples/02_cause_events.sql
mariadb --force --table -uroot -p < examples/03_read_the_log.sql
```

`--force` keeps the client running after the deliberate errors in examples 02, 04 and 05. The database
objects they use (`university_resources`, `campus_audit`) are created by `scripts/setup_database.sh`.

## What to look for

* **Example 02, statement (b):** the rejected `INSERT` still produces a `table_write` record, because
  the server raises TABLE events when it opens the table, *before* it executes the statement. Only
  the `statement` record that follows carries `"error_code":4025`. "Opened for write" is not
  "changed". That is one of the limits of the audit API this project documents in
  [docs/plugin-api-notes.md](../docs/plugin-api-notes.md).
* **Example 02, statement (c):** the rolled-back `UPDATE` is recorded with `"status":"ok"` and no
  trigger row exists for it. The plugin sees statements, not commits.
* **Example 03, last result:** `Campus_audit_events_dropped = 0` and `Campus_audit_state = ACTIVE`
  mean that no record was lost. If the disk fails, the state becomes `DEGRADED` and a later
  `audit_gap` record states how many events were dropped
  ([docs/experiments.md](../docs/experiments.md), experiment 4).
* **Example 04:** every rejected `SET GLOBAL` leaves the previous value in force.
