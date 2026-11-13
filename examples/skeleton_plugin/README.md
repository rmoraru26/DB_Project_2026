# Write your first MariaDB audit plugin (15 minutes)

`skeleton_audit.cpp` is the smallest audit plugin that does something visible: it counts the events
the server hands it, per event class, and shows the counts as status variables. `campus_audit` is
the same three parts plus filtering, records, a log file and failure handling. Start here, then read
`plugin/src/campus_audit.cpp`.

## 1. Read the code: three parts

| Part | In `skeleton_audit.cpp` | What the server does with it |
|---|---|---|
| (1) callback | `skeleton_notify(thd, event_class, event)` | calls it synchronously, in the session's own thread, for every event of a subscribed class; it returns `void`, so a plugin can watch but never refuse a statement |
| (2) audit descriptor | `struct st_mysql_audit skeleton_descriptor` | interface version (`MYSQL_AUDIT_INTERFACE_VERSION`), the callback, and the class mask (GENERAL, CONNECTION, TABLE) |
| (3) declaration | `maria_declare_plugin(skeleton_audit) { ... }` | exports the symbols the server looks up when it opens the library: type `MYSQL_AUDIT_PLUGIN`, name, licence, `init`/`deinit`, status variables, version, **maturity** |

The status variables are a plain table of `{name, address, SHOW_ULONGLONG}`; the server reads the
counters whenever someone runs `SHOW GLOBAL STATUS`. The callback runs in many threads at once, so the
counters are incremented atomically.

## 2. Build it

The headers come from the server package (`libmariadbd-dev` on Debian/Ubuntu, `include\mysql\server` in
every MariaDB Windows installation). They must match the server's version.

```bash
# Linux (the Docker image does exactly this in its build stage)
g++ -std=c++11 -O2 -shared -fPIC -DMYSQL_DYNAMIC_PLUGIN \
    -I/usr/include/mariadb/server -I/usr/include/mariadb/server/private \
    examples/skeleton_plugin/skeleton_audit.cpp -o skeleton_audit.so

# Windows, with Zig as the C++ compiler; the .def file exports the three plugin symbols
zig c++ -target x86_64-windows-gnu -std=c++11 -O2 -shared -DMYSQL_DYNAMIC_PLUGIN \
    -I"C:/Program Files/MariaDB 13.0/include/mysql/server" -I"C:/Program Files/MariaDB 13.0/include/mysql/server/private" \
    examples/skeleton_plugin/skeleton_audit.cpp examples/skeleton_plugin/skeleton_audit.def -o skeleton_audit.dll
```

Copy the library into `SELECT @@plugin_dir;` (the Docker image already has
`/usr/lib/mysql/plugin/skeleton_audit.so`).

## 3. Load it and watch it count

```bash
make sql            # Docker; natively: mariadb -uroot -p
```

```sql
INSTALL SONAME 'skeleton_audit';
SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE FROM information_schema.PLUGINS WHERE PLUGIN_TYPE = 'AUDIT';
SHOW GLOBAL STATUS LIKE 'skeleton\_audit\_%';
SELECT COUNT(*) FROM university_resources.rooms;
SHOW GLOBAL STATUS LIKE 'skeleton\_audit\_%';
```

Or run all of it at once: `examples/06_skeleton_plugin.sql` (part of `make examples`). Real output on
MariaDB 13.0.2 (`docs/evidence/windows-2026-11-03/12-skeleton-plugin.txt`):

```text
| campus_audit   | ACTIVE | AUDIT | campus_audit.dll   | Beta |
| skeleton_audit | ACTIVE | AUDIT | skeleton_audit.dll | Beta |
Skeleton_audit_general_events     4  ->  10     one SELECT and one SHOW: several GENERAL events each
Skeleton_audit_table_events       0  ->   1     the SELECT opened one table
Skeleton_audit_connection_events  0  ->   0     this session logged in before INSTALL
```

Two audit plugins are active at the same time; the server notifies each of them for every event.

## 4. Things to try

- **Log in again** (a new `mariadb` session): `connection_events` grows by one at login and one at logout.
- **Subscribe to fewer classes:** remove `MYSQL_AUDIT_GENERAL_CLASSMASK`, rebuild, `UNINSTALL SONAME` +
  `INSTALL SONAME`: the general counter stays at 0. That mask is how `campus_audit` avoids work for
  classes it does not need.
- **Look inside an event:** cast `event` to `const mysql_event_table*` for `MYSQL_AUDIT_TABLE_CLASS`
  and read `->database` and `->table`; that is how `campus_audit` filters by schema (`on_table()`).

## 5. Break it on purpose: plugin maturity

Every plugin declares a maturity, and the server refuses libraries below its `plugin_maturity`
(default `gamma`; this project's servers run with `beta`). Build the same file with
`-DSKELETON_EXPERIMENTAL` and install it:

```text
ERROR 1126 (HY000): Can't open shared library 'skeleton_audit_exp.dll' (errno: 1,
Loading of experimental plugin skeleton_audit is prohibited by --plugin-maturity=beta)
```

The check happens when the library is loaded, before `init` runs; `plugin_maturity` can only be
changed at server start. (This is experiment 1 in `docs/experiments.md`.)

## 6. Unload

```sql
UNINSTALL SONAME 'skeleton_audit';
```

`deinit` runs, the library is closed, and the counters are gone; the next `INSTALL` starts from 0.

## From the skeleton to campus_audit

| campus_audit adds | Where |
|---|---|
| filtering by schema and user, records per table and per statement, joined by `query_id` | `on_table()`, `on_general()`, a per-connection `MYSQL_THDVAR` |
| JSON Lines records with literal-free SQL digests | `plugin/src/record_format.cpp` |
| a log file, fail-open on write errors, `audit_gap` records | `plugin/src/log_sink.cpp`, `write_record()` |
| eight system variables: seven validated and dynamic, one startup option | `MYSQL_SYSVAR_*` with check and update functions, `PLUGIN_VAR_READONLY` |
| status variables computed on demand | `SHOW_SIMPLE_FUNC` entries |
| errors reported to the client and the error log | the `my_print_error` service (`plugin/src/service_symbols.cpp` on Windows/Zig) |
