# campus_audit: the plugin on its own

`campus_audit` is a MariaDB **audit plugin**: a shared library that `mariadbd` loads with
`INSTALL SONAME` and then calls for every connection, table access and finished statement of every
client. It writes one JSON line per event: who touched which table, with which statement (literals
replaced by `?`), and whether it worked. This page needs nothing of the booking application in the
rest of the repository.

## Run it in two commands

You need Docker (Linux, or Windows with Docker Desktop). No compiler, no MariaDB, no `.env`.

| | Linux (bash, GNU make) | Windows (PowerShell, in the project folder) |
|---|---|---|
| build, start, guided tour | `make plugin-lab` | `.\frantastic.cmd plugin-lab` |
| remove the container | `make plugin-lab-down` | `.\frantastic.cmd plugin-lab-down` |

`make plugin-lab` builds `campus_audit.so` and the 50-line [skeleton plugin](../examples/skeleton_plugin/README.md)
against the headers of MariaDB 13.0.2 (the image build also runs the plugin's unit tests). It then
starts a throw-away server that holds nothing but these two plugins and runs
[`lab/tour.sh`](lab/tour.sh) inside it. The tour prints every statement, the server's answer and the
plugin's records, and checks each claim:

| Step | What you see |
|---|---|
| 0–1 | `INSTALL SONAME 'campus_audit'`: `ACTIVE`, type `AUDIT`, 9 system and 11 status variables, a `plugin_start` record |
| 2 | `SET GLOBAL campus_audit_databases = 'lab'` takes effect at once and is itself recorded |
| 3 | a good and a CHECK-violating `INSERT`: both are recorded with their outcome (`error_code` 0 and 4025), and no literal reaches the log |
| 4 | a `DELETE` the privilege system refuses (1142) and a failed login (1045), both of which never reach a table |
| 5 | invalid values refused by the plugin's check functions, with the reason in `SHOW WARNINGS`; a foreign file refused as audit log |
| 6 | the redirect to `/dev/full` recorded in the log it left (handover); fail-open: the `INSERT` still succeeds, the plugin turns `DEGRADED`, and an `audit_gap` record later announces how many records were lost |
| 7 | the skeleton plugin next to campus_audit; the server refusing an *experimental* build of it (ER 1126, maturity check) |

It ends with `== Result: 25 passed, 0 failed` and exits non-zero if any check failed. CI runs it from
a clean checkout on every push. A full run is in
[`docs/evidence/cycle9/14-plugin-lab-plugin-1.2.5-docker-desktop.txt`](../docs/evidence/cycle9/14-plugin-lab-plugin-1.2.5-docker-desktop.txt).
One record from step 3:

```json
{"ts":"2026-11-21T01:59:50.202234Z","seq":7,"instance":"660bfb7488147-1","event":"statement","conn":15,"query_id":28,"account":"root[root] @ localhost []","db":null,"command":"Query","error_code":4025,"status":"error","sql_digest":"INSERT INTO lab.notes VALUES (?, ?, ?)","sql_digest_truncated":false}
```

## Experiment

The container stays up after the tour. It publishes no port, and its root password is random and
stored only inside it.

```bash
docker exec -it campus-audit-plugin-lab mariadb                                    # root SQL shell
docker exec campus-audit-plugin-lab tail -f /var/log/campus_audit/campus_audit.jsonl   # the log, live
```

Things to try in the SQL shell. Each one shows one property of the audit API:

```sql
SET GLOBAL campus_audit_connections = 'ALL';        -- record every login and logout, not only failed ones
SET GLOBAL campus_audit_log_reads = ON;             -- SELECTs on lab.* now produce table_read records
LOCK TABLES lab.notes WRITE;                        -- under LOCK TABLES the server raises no TABLE event:
INSERT INTO lab.notes VALUES (10, 'x', 1);          --   this INSERT leaves no record
UNLOCK TABLES;
SET GLOBAL campus_audit_statement_scope = 'SESSION';-- now statements without a table event are recorded too
LOCK TABLES lab.notes WRITE;
INSERT INTO lab.notes VALUES (11, 'y', 1);          --   a statement record with "scope":"session"
UNLOCK TABLES;
SET GLOBAL campus_audit_reopen_now = ON;            -- close and reopen the log (rotation)
SHOW GLOBAL STATUS LIKE 'Campus_audit%';            -- counters: written, dropped, filtered, write failures
UNINSTALL SONAME 'campus_audit';                    -- deinit runs; a plugin_stop record ends the log
```

Why each of these behaves as it does, with the source of every fact: [docs/plugin-api-notes.md](../docs/plugin-api-notes.md)
and the measured [experiments](../docs/experiments.md).

**Change a plugin and reload it.** Edit [`examples/skeleton_plugin/skeleton_audit.cpp`](../examples/skeleton_plugin/skeleton_audit.cpp)
(for example, drop `MYSQL_AUDIT_GENERAL_CLASSMASK` from its descriptor) and run `make plugin-lab`
again. The image rebuilds only what changed, and the tour reloads both plugins.

## Build and install it without Docker

| Platform | Commands |
|---|---|
| Linux (headers of the server's exact version: `libmariadbd-dev`, `libmariadb-dev`) | `make -C plugin test` (unit tests, no server), `make -C plugin` → `plugin/build/campus_audit.so`; skeleton: `make -C examples/skeleton_plugin` |
| Windows (MariaDB 13.0.x zip or MSI, [Zig 0.16.0](https://ziglang.org/download/), no Visual Studio) | `powershell -ExecutionPolicy Bypass -File plugin\build_windows.ps1 -MariaDBDir "C:\Program Files\MariaDB 13.0" -Zig C:\tools\zig\zig.exe` |

Copy the library into the directory `SELECT @@plugin_dir;` names. Put `plugin_maturity = beta`
under `[mysqld]` (the plugin declares itself Beta; the server's default `gamma` refuses it, and
the option can only be set at startup), restart, then run `INSTALL SONAME 'campus_audit';`. The
options the Docker image uses are in [`docker/mariadb/campus_audit.cnf`](../docker/mariadb/campus_audit.cnf).
On Linux, `LOAD_FILE()` needs the log to be readable by all; see [docs/security.md](../docs/security.md).

## The source, file by file

| File | Lines | What it does |
|---|---:|---|
| [`src/campus_audit.cpp`](src/campus_audit.cpp) | 1342 | the plugin: `maria_declare_plugin`, the audit descriptor and `campus_audit_notify`; `on_connection`, `on_table`, `on_general`; the 9 system variables with check and update functions; the 11 status variables; `init`/`deinit` |
| [`src/record_format.cpp`](src/record_format.cpp), `.h` | 651 | server-independent: the JSON writer, the literal-free SQL digest, name filters |
| [`src/log_sink.cpp`](src/log_sink.cpp), `.h` | 527 | the log file: which files may be opened (checked on the opened descriptor or handle), one `write()` per record, reopen |
| [`src/statement_scope.h`](src/statement_scope.h) | 137 | which statements get a `statement` record, decided from event facts only (no SQL parsing) |
| [`src/platform.h`](src/platform.h) | 148 | mutex with a bounded wait, reader/writer lock, clock: Linux and Windows |
| `src/gap_accounting.h`, `src/runtime_config.h` | 49 | counting lost records; atomic copies of settings for concurrent callbacks |
| `src/service_symbols.cpp`, `src/campus_audit.def` | 30 | Windows/Zig builds: the server service pointers and the exported symbols |
| `audit_error*.h/.cpp`, `audit_file_check.*` | | error types and their reporting to the client and the error log ([docs/error_handling.md](docs/error_handling.md)) |
| [`tests/`](tests) | 1247 | 7 unit-test programs, no server needed; `make mutation` (repository root) injects 80 bugs they must detect |

Read it in this order: the [skeleton plugin](../examples/skeleton_plugin/README.md) (the three parts every audit plugin has),
then `campus_audit_notify` and `on_table` in `src/campus_audit.cpp`, then `src/statement_scope.h`.

## Tests of the plugin alone

| Command | What it runs | Needs |
|---|---|---|
| `make -C plugin test` | 7 unit-test programs | g++ and the server headers |
| `make mutation` | the unit tests against 80 injected bugs | g++, Python 3 |
| `make plugin-lab` | the guided tour above (25 checks) | Docker |
| `make test-server-version MARIADB_IMAGE=mariadb:11.8@sha256:...` | the end-to-end harness, thread pool, stalled log and log path safety tests against another server version | Docker |

The end-to-end harness [`tests/plugin/run_plugin_tests.sh`](../tests/plugin/run_plugin_tests.sh) runs against any
server where the plugin is installed: the Docker stack, a native Linux server, or native Windows
from Git Bash. Where each suite last ran is recorded in [docs/testing.md](../docs/testing.md).
