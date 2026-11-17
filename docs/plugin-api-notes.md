# MariaDB audit plugin API: what campus_audit relies on

Target: **MariaDB 13.0.2**, audit API `MYSQL_AUDIT_INTERFACE_VERSION 0x0303` (the plugin also builds
against `0x0302`, MariaDB 10.11 to 11.8; run on 11.8.9, see "Audit API versions" below),
plugin API `MARIA_PLUGIN_INTERFACE_VERSION 0x010f`.

Every statement below is labelled by where it comes from:

- **[doc]**: the official [plugin overview](https://mariadb.com/docs/server/reference/plugins/plugin-overview)
  (installation, `mysql.plugin`, maturity, status) and
  [Writing Plugins for MariaDB](https://mariadb.com/docs/server/reference/product-development/plugin-development/development-writing-plugins-for-mariadb)
  (the declaration: type, descriptor, name, author, description, licence, init, deinit, version
  `0xAABB`, variables, version string, maturity; for the licence and the maturity it says "see
  include/mysql/plugin.h").
  The official [Audit Plugin Development](https://mariadb.com/docs/server/reference/product-development/plugin-development/audit-plugin-development)
  page was retrieved again on 2026-11-15, as HTML and as its Markdown source: it consists of the
  title, the sentence "Provides instructions for developing plugins that track and log server
  activity for security and compliance monitoring" and the note "This page contains background
  information for MariaDB developers". It describes no event class, structure or callback. No
  statement here rests on it. **The developer-level documentation of the audit API is the header
  that ships with the server**, `include/mysql/plugin_audit.h`, whose comments are quoted below.
- **[header]**: comments and declarations in the installed headers
  `include/mysql/plugin.h`, `include/mysql/plugin_audit.h` and `include/mysql/service_*.h`
  (the same files ship in the Windows zip and in `libmariadbd-dev`).
- **[source]**: the server source at tag `mariadb-13.0.2` (each claim links the file and line on GitHub at that tag)
  (`sql/sql_audit.h`, `sql/sql_audit.cc`, `sql/sql_plugin.cc`, `sql/mysqld.cc`, `sql/set_var.cc`,
  `sql/sql_class.cc`, `sql/sql_parse.cc` and the server_audit plugin's `server_audit.cc`).
  This is implementation behaviour, not an API promise; it can change between versions.
- **[observed]**: what our tests showed on 13.0.2 (Windows build, and the Linux Docker image in CI
  where stated; see `docs/evidence/`).

## 1. Plugin type and declaration

- An audit plugin is a `MYSQL_AUDIT_PLUGIN` whose `info` points to a
  `struct st_mysql_audit { interface_version; release_thd; event_notify; class_mask[1]; }` [header].
- `maria_declare_plugin(name) { ... } maria_declare_plugin_end;` exports
  `_maria_plugin_interface_version_`, `_maria_sizeof_struct_st_plugin_` and
  `_maria_plugin_declarations_`; the server finds the plugin through these symbols [header].
  With MSVC they are exported by `MYSQL_PLUGIN_EXPORT` (`_declspec(dllexport)`); with a GNU
  toolchain on Windows nothing is exported automatically once any symbol is `dllexport`
  (as `SERVICE_VERSION` is), so `plugin/src/campus_audit.def` lists them [observed].
- The descriptor carries a maturity level, which the server compares with its minimum allowed
  maturity during installation [doc]. The server refuses to load a library whose maturity is
  below `plugin_maturity` (default `gamma`): *"Loading of experimental plugin skel is prohibited by
  --plugin-maturity=gamma"* [observed]. campus_audit declares itself **BETA**, so the server needs
  `plugin_maturity=beta`, a startup-only option, and logs
  *"Plugin 'campus_audit' is of maturity level beta while the server is stable"* [observed].

## 2. Event classes and what each one delivers

campus_audit subscribes to `MYSQL_AUDIT_GENERAL_CLASSMASK | MYSQL_AUDIT_CONNECTION_CLASSMASK |
MYSQL_AUDIT_TABLE_CLASSMASK`.

| Class / subclass | When [header, source] | Fields used | Not available |
|---|---|---|---|
| CONNECTION CONNECT | after authentication; `status` = error code of the failed login, 0 on success | thread_id, user, priv_user, proxy_user, host, ip, port, database, tls_version | the password (never passed), client program name |
| CONNECTION DISCONNECT | after the connection ends; `status` = disconnect error code | same | session duration |
| CONNECTION CHANGE_USER | after COM_CHANGE_USER, also when it fails (`status` = 1045); fields come from the **old** security context (`sql_audit.h`, `mysql_audit_notify_connection_change_user(thd, old_ctx)`) [source: [sql_audit.h:282](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L282)]; confirmed on 13.0.2 with `mysql_change_user()` from `tests/plugin/change_user.c`: a switch a→b is recorded with `user: a`, a failed switch b→a with `user: b` [observed] | same | the account switched **to** (neither on success nor on failure) |
| TABLE LOCK | at the start of each statement, per table it opens, `read_only` = 1 for reads; **not while `LOCK TABLES` is in effect** [header, quoted in 2a] | thread_id, query_id, user, priv_user, priv_host, host, ip, database, table | **rows**, column values, number of rows, whether the statement later succeeded, the SQL command |
| TABLE CREATE / DROP / RENAME / ALTER | DDL on a table; RENAME adds new_database / new_table [header] | same | the DDL text (comes with GENERAL STATUS) |
| GENERAL STATUS | after the result or error was sent to the client [header] | general_thread_id, query_id, general_user (formatted `priv[user] @ host [ip]`), database, general_command, general_error_code, general_query | rows affected (see below), row images, the tables touched |
| GENERAL LOG / ERROR / RESULT / WARNING | ignored by campus_audit | | |

Important consequences:

- **No row images.** No audit event carries old or new column values; `mysql_event_table` has no
  row data at all [header]. campus_audit therefore never claims to record *what* changed in a row.
  Row-level before/after values are captured by SQL triggers instead (`database/triggers.sql`).
- **`general_rows` is not "rows affected".** For STATUS events it is
  `thd->get_stmt_da()->current_row_for_warning()` [source: [sql_audit.h:192](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L192)], so campus_audit does not record it.
- **TABLE LOCK means "opened for reading/writing", not "changed".** A failed INSERT (CHECK
  constraint error 4025) still produces `table_write` for the table and for `audit_events`, which
  the trigger would have written [observed]. Only the statement record says whether it succeeded.
- **Not transactional.** An UPDATE that is later rolled back still yields `table_write` and a
  statement with `status: ok`; the plugin sees statements, not commits [observed, integration test
  "rolled-back UPDATE ..."]. COMMIT/ROLLBACK themselves touch no table and are not recorded.
- **Triggers are visible.** The table a trigger writes appears as a second `table_write` with the
  same `query_id` as the user's statement [observed]; this is how plugin records and trigger rows are
  correlated. The built-in server_audit additionally logs each trigger body statement as its own
  QUERY record [observed, `docs/evidence/exp-server-audit.txt`].
- **`database` is the session's default schema** (`thd->db`), not the schema of the table
  [source: [sql_audit.h:193](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L193)]; `INSERT INTO exp_db.t ...` without `USE` gives a statement record with `"db": null`
  while the table record says `"db": "exp_db"` [observed].
- **Identifiers and timestamps.** `thread_id` equals `CONNECTION_ID()`; `query_id` is a server-wide
  counter, so `(instance, conn, query_id)` identifies a statement [observed, harness check
  "table and statement records share query_id"]. Connection ids restart after a server restart.
  `general_time` has one-second resolution (`my_time(0)`) [source: [sql_audit.h:180](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L180)], so campus_audit takes its own
  microsecond UTC timestamp.
- **SQL text** is `thd->query_string` in the client character set [source: [sql_audit.h:189-191](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L189-L191)]. Client libraries such
  as PyMySQL interpolate parameters before sending, so the server sees literal values (emails, booking
  times, password hashes). campus_audit only writes a digest with literals replaced by `?`.
- **Refused statements raise no TABLE event.** The privilege check runs before the server opens a
  table, so `DELETE FROM bookings` by an account without DELETE (ER 1142) produced no record at all
  in plugin 1.0.0 [observed]. Since 1.1.0 the plugin records such a statement from GENERAL STATUS
  (`"access_denied": true`, error 1044/1142/1143/1227/1370) when the session's **default** schema is
  watched; a refused statement that names a watched table from another default schema stays
  invisible, because GENERAL events do not name tables [observed, harness "refused statements"].
- **GENERAL STATUS comes after the client has its answer** (it is raised after
  `end_statement()` [source: [sql_parse.cc:2448-2458](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_parse.cc#L2448-L2458)]). A reader on *another* connection can therefore look at the log
  before the statement record is written. The same connection cannot: the server finishes the
  callback before it reads the next command, which is why the Audit Lab imports the log on the
  request's own connection.
- **Unknown accounts are not refused with 1045.** For an account that does not exist, 13.0.2 for
  Windows answers with an authentication-plugin switch (to `auth_gssapi_client`), so a client
  without that plugin (PyMySQL) aborts; the plugin then records `connect_failed` with status 1158
  (aborted handshake), while the `mariadb` CLI follows the switch and the record says 1045 [observed].
  The server does not reveal whether the account exists; the recorded status depends on the client.

## 2a. What the TABLE class does not show, and scope SESSION

The plugin learns that a statement belongs to a watched schema from its TABLE events. Four kinds of
statement give it nothing, or something misleading, to go on. Each row was measured on 13.0.2
(`docs/experiments.md`, experiments 21 to 25; `examples/07_what_table_events_miss.sql`; the
end-to-end harness, "statements without table events").

| Statement | What the server raises | Source |
|---|---|---|
| `INSERT`, `UPDATE`, `DELETE`, `SELECT` while `LOCK TABLES` is in effect | **no table event**. The header says of the LOCK event: "This event is generated at the beginning of every statement for every affected table, unless there's a LOCK TABLES statement in effect (in which case it is generated once for LOCK TABLES and then is suppressed until the tables are unlocked)." `LOCK TABLES` itself raises one LOCK event per table; `UNLOCK TABLES` raises none | [header], [observed] |
| `CREATE TRIGGER`, `DROP TRIGGER`, `CREATE VIEW` | one LOCK event **with `read_only` = 1** for the table the trigger or view refers to: the server reports this DDL as read access. The class has subclasses only for tables (LOCK, CREATE, DROP, RENAME, ALTER) | [header], [observed] |
| `DROP VIEW`, `COMMIT`, `ROLLBACK`, `START TRANSACTION`, `SET`, `CALL` | no table event | [observed] |
| `CREATE PROCEDURE`, `DROP PROCEDURE` | one event, for `mysql.proc` | [observed] |

Two more facts about the order of events matter for what follows [observed]:

- **A trigger's body statement gets a GENERAL STATUS event of its own**, with its own query id,
  *before* the STATUS event of the statement that fired it. The tables the trigger writes are
  opened by the firing statement, so their TABLE events carry the *outer* query id.
- A routine's statements are statements of their own: each has its table events and its STATUS
  event under its own query id, and `CALL` gets a STATUS event without any table event. `SET`
  inside a routine gets no STATUS event.

The GENERAL STATUS event of every such statement still arrives, but it names no table and carries
no SQL command type, only the session's default schema (`database`, added in 0x303). What a plugin
may do with that, without reading the SQL text:

- **Default, `campus_audit_statement_scope = TABLES`:** nothing. Statements under `LOCK TABLES`
  and the table-less statements above leave no record. Trigger DDL and `CREATE VIEW` are recorded
  when `campus_audit_log_reads` is `ON` (as `table_read` plus the statement, whose digest shows the
  DDL), and not otherwise.
- **Opt-in, `SESSION` (plugin 1.2.0):** a statement gets a record marked `"scope":"session"` when
  the server raised no table event for it (events for the system schemas do not count), it arrived
  through a protocol command that runs SQL (`Query` or `Execute`, not `Quit` or `Ping`), no other
  statement of the connection is waiting for its own STATUS event (which excludes trigger bodies),
  and (a) the session's default schema is watched, or (b) the last statement of the connection
  that raised table events touched a watched table. `LOCK TABLES` on a watched table is such a
  statement, so rule (b) covers everything executed under the lock, whatever the default schema is.
  The logic is `plugin/src/statement_scope.h`; it has unit tests and mutants of its own.

What scope `SESSION` cannot do, because the facts are not in the events:

- tell a `SELECT` under `LOCK TABLES` from a write, or a trigger's body statement under
  `LOCK TABLES` from the client's statement (under the lock neither raises a table event, and the
  firing statement leaves nothing waiting);
- record trigger DDL without `log_reads`: its only table event is a read, and a read with
  `log_reads` off is a `SELECT` as far as the events say;
- record table-less DDL that names a watched object with a qualified name from a session whose
  default schema is not watched and whose last table access was elsewhere.

An alternative that was considered and not used: `mysql/plugin.h` declares
`int thd_in_lock_tables(const MYSQL_THD thd)` and `int thd_sql_command(const MYSQL_THD thd)`
[header]. Both would answer the question directly. They are functions of the server executable,
not *services*: a plugin that calls them must be linked against the server binary, which the
Zig-built Windows DLL deliberately avoids (section 5a), and the values `thd_sql_command` returns
are the `enum_sql_command` constants of a private header (`private/sql_command.h`). The rules above
need neither.

Per-connection state lives in three hidden session variables, which travel with the connection
when the thread pool moves it between threads; the configuration-change mark is `thread_local`
(section 3). Whether a statement stays on one thread from its `SET GLOBAL` callback to its STATUS
event, and whether the session variables follow the connection, is not stated by the header. It is
measured on every run by `tests/plugin/test_thread_pool.sh` (`make test-threadpool`):
`thread_handling=pool-of-threads`, a pool of 2 threads, 12 connections, 360 rounds in each of two
phases, every count exact. That is an observation for 13.0.2, not an API guarantee.

**Prepared statements over the binary protocol** (what a driver sends; measured with the C API by
the harness, `tests/plugin/change_user.c --prepared`). `COM_STMT_PREPARE` leaves no record (there is no
`statement` record with the command `Prepare`), in either scope. Every `COM_STMT_EXECUTE` is its own statement: its TABLE events and its STATUS event
(command `Execute`) share one query id, different for each execution, so each execution gets its
own `statement` record with its own error code (a duplicate key: 1062). The query text the server
passes for an execution goes through the same digest as any other, and no bound value reaches the
log. After the executions nothing is left pending: in scope `SESSION` the next table-less
statement of the connection is recorded.

## 3. Callback contract

- `event_notify(MYSQL_THD, unsigned int event_class, const void *event)` returns **void** [header]:
  an audit plugin can observe but not veto or fail a statement. campus_audit is therefore
  necessarily **fail-open** for runtime errors.
- The event structures are local variables of the dispatching function (`mysql_event_general event;`
  in `sql_audit.h`) [source: [sql_audit.h:176](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L176)], so their pointers are only valid during the call; campus_audit formats
  everything before returning and keeps no pointers.
- Callbacks run concurrently in many connection threads; the plugin must do its own locking.
- `release_thd` may be NULL; campus_audit holds no per-THD resources.
- Per-connection state: `MYSQL_THDVAR_ULONGLONG(stmt_query_id, PLUGIN_VAR_NOSYSVAR | PLUGIN_VAR_NOCMDOPT, ...)`
  is a hidden session variable used to remember "this statement touched a watched table" until its
  STATUS event (the same technique server_audit uses with a hidden THDVAR string) [header, source].
  Since 1.2.0 there are two more of the same kind, `stmt_seen_query_id` ("the statement that raised
  the latest table event") and `session_latch` (rule (b) of section 2a). All three are read and
  written only in event callbacks, never in a SET GLOBAL update callback (see the deadlock trap
  below), and are written only when their value changes.

### Re-entrancy trap found in the source

`my_printf_error(..., ME_ERROR_LOG_ONLY)` looks like the natural way to report a failure from inside
`event_notify`. But `my_message_sql()` (`sql/mysqld.cc`) treats `ME_ERROR_LOG_ONLY` as "no THD" and
then calls `mysql_audit_general(0, MYSQL_AUDIT_GENERAL_ERROR, ...)`, which dispatches to **all audit
plugins through `plugin_foreach()`** (`sql/sql_audit.cc`, `mysql_audit_notify` with `thd == NULL`)
[source: [mysqld.cc:3539](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/mysqld.cc#L3539), [sql_audit.cc:424](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.cc#L424)]. Reporting from the callback would therefore re-enter audit plugins. campus_audit uses
`my_printf_error` only from init, deinit and SET GLOBAL handlers (never while holding its own locks),
and writes a line to stderr (the server's error log) from inside callbacks: once per I/O outage
(when it starts and when it ends), and once for each record that does not fit its buffer
(`plugin/docs/error_handling.md`).

### Deadlock trap: a THDVAR inside a system-variable update callback (found on Linux)

- `SET GLOBAL` of a plugin variable runs the plugin's `update` callback with
  `LOCK_global_system_variables` held: `sys_var::update()` takes it for every GLOBAL update
  (`sql/set_var.cc`), and `sys_var_pluginvar::global_update()` asserts that it owns it before calling
  `plugin_var->update` (`sql/sql_plugin.cc`) [source: [set_var.cc:242](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/set_var.cc#L242), [sql_plugin.cc:3723](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L3723), [sql_plugin.cc:3731](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L3731)].
- `THDVAR(thd, x)` resolves through `intern_sys_var_ptr(thd, offset, true)`. A connection starts
  without its own copy of the plugins' session variables (`plugin_thdvar_init()`, also after
  COM_CHANGE_USER); the first access makes it: `intern_sys_var_ptr(thd, offset, true)` calls
  `sync_dynamic_session_variables(thd, global_lock)` with `global_lock` true, which
  locks `LOCK_global_system_variables` itself [source: [sql_plugin.cc:3297](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L3297), [sql_plugin.cc:3221-3237](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L3221-L3237)].
- So the first THDVAR access of a connection must not happen inside an update callback. On Linux
  the mutex is a plain pthread mutex (`MY_MUTEX_INIT_FAST`, `sql/mysqld.cc`): the thread waits for
  itself, and every new connection waits behind it, because `THD::init()` takes the same mutex
  (`sql/sql_class.cc`) [source: [mysqld.cc:4672-4673](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/mysqld.cc#L4672-L4673), [sql_class.cc:1382](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_class.cc#L1382)]. On Windows `pthread_mutex_t` is a `CRITICAL_SECTION`
  (`include/mysql/server/my_pthread.h`), which its owner may lock again [header], so nothing happens.
- campus_audit 1.1.0 did exactly that: `log_config_change()` set `THDVAR(thd, stmt_query_id)` to have
  the SET statement logged, and its event handler returned before reading the THDVAR for every GENERAL
  event except STATUS. The Windows suite passed. The first Docker CI run (13.0.2 on Linux) stopped at
  `SET GLOBAL campus_audit_max_sql_length = 999999`, the suite's first accepted SET GLOBAL and the
  first statement of its connection: no answer for an hour, nothing in the error log, and the web
  container's health checks queued up behind it [observed].
- `server_audit` makes the same kind of THDVAR access in its update callbacks (`mark_always_logged()`,
  `log_current_query()`), but its `auditing()` reads the THDVAR at the start of every event, and the
  GENERAL LOG event of a COM_QUERY comes before parsing (`dispatch_command()` in `sql/sql_parse.cc`), so
  the copy already exists when SET GLOBAL runs [source: [sql_parse.cc:1875](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_parse.cc#L1875)]. campus_audit 1.1.1 does not depend on that
  order: the mark is a `thread_local` flag, which the statement's own STATUS event reads. This
  relies on a statement running on one OS thread from the update callback to its STATUS event, also
  with the thread pool. The header does not promise that; it is **observed** on 13.0.2 and checked
  on every run by `tests/plugin/test_thread_pool.sh` (360 `SET GLOBAL` statements on 12 connections
  with a pool of 2 threads: 360 attributed records, no stray one).

### Reading the log back: LOAD_FILE() needs a file readable by all (found on Linux)

- `Item_load_file::val_str` (`sql/item_strfunc.cc`) returns NULL unless the caller has FILE, the
  path is inside `secure_file_priv`, the file is smaller than `max_allowed_packet` **and its mode has
  `S_IROTH`** [source: [item_strfunc.cc:4240](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/item_strfunc.cc#L4240)]. The plugin creates its log `0660` and the server's umask applies, so on Linux
  every import returned NULL: `make demo` failed with ER 1644 from `import_plugin_log`, and 42
  end-to-end checks, 8 app tests and 3 browser tests failed in the Docker CI runs for that reason only
  [observed]. On Windows the check passed in every run.
- campus_audit 1.1.1 adds `S_IROTH` with `fchmod()`, which the umask does not affect, when the
  startup option `campus_audit_readable_by_all` is ON; the Docker image sets it and protects the
  directory instead (`docs/security.md`).

## 4. Lifecycle

- `INSTALL SONAME 'campus_audit'` loads the library, records it in `mysql.plugin` and calls `init`;
  it is loaded again at every server start [doc: "the plugin will automatically be loaded every time
  the server restarts"; observed after restart].
- `INSTALL SONAME` of a library whose plugins are already installed is a **silent no-op**;
  `INSTALL PLUGIN campus_audit SONAME 'campus_audit'` fails with ER 1968 [observed].
- Missing library: ER 1126 *Can't open shared library* [observed].
- If `init` returns non-zero the plugin is not activated; at server start the server keeps running
  and the plugin shows as `NOT INSTALLED` in `information_schema.ALL_PLUGINS` while its row stays in
  `mysql.plugin` [observed].
- **The server also calls `deinit` after a failed `init`**: `initialize_audit_plugin()` reports
  *"init function returned error"* and the plugin is later finalised through
  `finalize_audit_plugin()`, which calls `deinit` [source, observed: our first version logged a
  spurious write failure from deinit]. campus_audit guards deinit with an `initialized` flag.

## 4a. Dynamic system-variable storage and callback concurrency

Target: MariaDB 13.0.2, C++11. The official plugin system-variable documentation describes the
check callback's `save` storage and says the update callback stores the accepted value through
`var_ptr`; it explicitly notes an update callback is needed when the plugin wants an atomic value.
It does not document a guarantee that plugin callback reads of the backing storage are synchronized
with concurrent `SET GLOBAL` updates. The event API also invokes the audit callback on concurrent
connection threads. Under the C++11 memory model, an unsynchronized read/write pair on ordinary scalar
storage is a data race, so code must not treat the server's global-variable lock as protecting plugin
reads that do not acquire that lock.

`campus_audit` therefore keeps MariaDB's required backing storage for the sysvars but publishes the
four dynamic scalar settings read by event callbacks (`log_reads`, `connections`, `statement_scope`,
`max_sql_length`) to atomic runtime copies from their update callbacks. Startup initializes those copies before event
callbacks can run. Callback reads and update stores are relaxed atomics: each setting is independent,
no pointer/object lifetime is being published, and no multi-setting snapshot is required. Database and
user filters remain protected by `filter_lock`; the active log path and sink state remain under
`sink_lock`. The update callbacks retain their existing no-THDVAR rule because MariaDB 13.0.2 invokes
them while holding `LOCK_global_system_variables`.

References: [MariaDB plugin update callback documentation](https://mariadb.com/docs/server/server-usage/plugins/plugin-system-variables/#update-callback)
and [C++ data races](https://en.cppreference.com/w/cpp/language/multithread). The repository's
13.0.2 evidence remains version-specific; these internal server-lock observations are not asserted as
a stable API guarantee for other MariaDB releases.

More facts about variables:

- Status variables are registered only after `init` succeeded (`plugin_do_initialize`) [source: [sql_plugin.cc:1455-1489](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L1455-L1489)].
- The check functions are documented for SET [header]; campus_audit does not rely on them running
  for values from `my.cnf` or the command line and validates everything again in `init`. With
  `loose_campus_audit_databases=bad name` in `my.ini`, it was `init` that rejected the value and the
  plugin stayed inactive [observed].
- `loose_` prefixes let the server start before the plugin is installed; the values are used when
  `INSTALL SONAME` runs later [observed with `my.ini`].

## 5. Services

### 5a. Why only services

- A dynamic plugin reaches server functions through *services*: each `service_*.h` declares a pointer
  such as `my_print_error_service`; the plugin binary must **define** a variable with that name whose
  initial value is the service version, and the server overwrites it at load time
  (`libservices/*.c`, `sql/sql_plugin.cc` `plugin_dl_add`) [source: [sql_plugin.cc:817-824](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L817-L824)].
- Normally this comes from linking `libmysqlservices.a` (Linux, package `libmariadb-dev`) or
  `mysqlservices.lib` (Windows). The MSVC-built `mysqlservices.lib` cannot be linked by a GNU
  toolchain (it carries `/DEFAULTLIB:MSVCRT` directives) [observed], so the Zig build compiles
  `plugin/src/service_symbols.cpp`, which contains exactly what `libservices` contains.
- Used services: `my_print_error` (warnings to the client and error log) and `thd_alloc`
  (`thd_strmake` to copy a SET value into statement memory inside a check function).
- The plugin calls nothing else in the server. A function that is declared in `plugin.h` but is
  not a service (for example `thd_in_lock_tables`) would have to be resolved against the server
  executable itself; on Windows that means an import library for `mariadbd.exe`, which the GNU
  toolchain build does not use.

## 6. System and status variables

- `MYSQL_SYSVAR_STR/BOOL/ENUM/UINT` with check and update functions; a check function that returns
  non-zero makes `SET GLOBAL` fail with ER 1231, and warnings raised before that remain visible in
  `SHOW WARNINGS` [observed].
- `val_str()` may return a pointer into the caller's stack buffer; the value must be copied
  (`thd_strmake`) before the check function returns [header comment on `st_mysql_value`].
- Integer sysvars are clamped to `[min, max]` with a warning, not rejected
  (`max_sql_length=999999` becomes 8192) [observed].
- Status variables use `SHOW_SIMPLE_FUNC` so that counters are read atomically and strings are
  copied under the plugin's lock. MariaDB prefixes nothing itself when the names already start with
  the plugin name (`plugin_do_initialize`) [source: [sql_plugin.cc:1489](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L1489)]; they appear as `Campus_audit_*`.

## 6a. The licence field of the declaration

`plugin.h` defines three values for the `license` member of the declaration, "the plugin license
(PLUGIN_LICENSE_XXX)": `PLUGIN_LICENSE_PROPRIETARY` (0), `PLUGIN_LICENSE_GPL` (1) and
`PLUGIN_LICENSE_BSD` (2), shown as `PROPRIETARY`, `GPL` and `BSD` in
`INFORMATION_SCHEMA.PLUGINS.PLUGIN_LICENSE` [header]. The official "Writing Plugins" page adds only
"see include/mysql/plugin.h" [doc]. We found nothing in the header or that page saying that the
server treats plugins differently by this value; we did not search the server source for it.

The plugin's own source is published under the MIT licence (`LICENSE`), a permissive licence for
which the header has no value. Since 1.2.0 `campus_audit` and the tutorial plugin declare
`PLUGIN_LICENSE_BSD`, the permissive value of the three; earlier versions declared
`PLUGIN_LICENSE_GPL`, which named a licence the repository does not use. The field is a label. It
does not change the terms in `LICENSE`, and this project makes no statement about the licence
terms of a binary that combines its code with the server's headers, which carry a GPL version 2
notice.

## 7. Platform notes

- Linux: the official image's MariaDB apt repository provides `libmariadbd-dev` (headers in
  `/usr/include/mariadb/server`) and `libmariadb-dev` (`libmysqlservices.a`) in exactly the server's
  version (checked in the repository's `Contents-amd64` index). The Docker build compiles and loads
  the plugin against them; it ran in CI on GitHub's `ubuntu-24.04` runners [observed,
  `docs/evidence/linux-ci-2026-11-03/`].
- Windows: the official zip/MSI ships `include/mysql/server` (incl. `private/service_versions.h`) and
  `lib/mysqlservices.lib`. A DLL built with Zig 0.16 (`x86_64-windows-gnu`) loads into the official
  MSVC-built `mariadbd.exe` 13.0.2 [observed]; the plugin interface is plain C structs.
- A Linux `.so` cannot be loaded by Windows MariaDB and vice versa; each platform needs its own build.

## 8. Audit API versions

[header] The official `include/mysql/plugin_audit.h` of five releases (`docs/evidence/cycle3/01-audit-header-fields.txt`, script `docs/evidence/cycle3/scripts/compare_audit_headers.sh`):

| Release | `MYSQL_AUDIT_INTERFACE_VERSION` | Fields campus_audit reads that are not in every release |
|---|---|---|
| 10.11.15, 11.4.9, 11.8.9 | `0x0302` | connection event without `port` and `tls_version` |
| 12.0.2, 13.0.2 | `0x0303` | adds `port` and `tls_version` to the connection event (and `port` to the GENERAL and TABLE events, which campus_audit does not read) |

Everything the correlation needs (`database` and `query_id` of the GENERAL event, `query_id` of the TABLE
event) is in both. `plugin/src/campus_audit.cpp` therefore refuses only headers older than `0x0302` and
records `port` and `tls_version` as `null` when it is built against `0x0302`.

[observed] Built against 11.8.9 and loaded into an 11.8.9 server, the plugin passed the whole harness
(134 checks) and the thread-pool test (30 checks); every server behaviour listed above was the same as on
13.0.2 (`docs/evidence/cycle3/`, experiment 31). 10.11 and 11.4 were not run.

## 9. Which server locks are held while plugin code runs

A plugin function can be called while the server holds one of its own locks. Anything that function
waits for then holds that lock up as well. campus_audit has one mutex of its own (`sink_lock`, around
the log file); this is where its functions run:

| Plugin function | Server lock held | Source |
|---|---|---|
| event callback (`campus_audit_notify`) | none of the global locks below | dispatched from the statement's own thread [source: [sql_audit.h:176](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_audit.h#L176)]. A TABLE event comes before the table is used. The GENERAL STATUS event comes **after** `protocol->end_statement()`, so the client already has its answer, and before the connection reads its next statement [source: [sql_parse.cc:1914-1921](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_parse.cc#L1914-L1921)] |
| system-variable check function | none: `set_var::check()` runs before `sys_var::update()` takes the lock [source: [set_var.cc:231-246](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/set_var.cc#L231-L246)] | |
| system-variable update function | `LOCK_global_system_variables` | [source: [sql_plugin.cc:3720-3732](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_plugin.cc#L3720-L3732)], `mysql_mutex_assert_owner(&LOCK_global_system_variables)` before `plugin_var->update()` |
| status function (`SHOW_SIMPLE_FUNC`) | `LOCK_all_status_vars` for reading | [source: [sql_show.cc:8917-8922](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_show.cc#L8917-L8922)] in `fill_status()`; `add_status_vars()` and `remove_status_vars()`, i.e. `INSTALL` and `UNINSTALL` of a plugin with status variables, take it for writing [source: [sql_show.cc:3676](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_show.cc#L3676), [3759](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_show.cc#L3759)]. A `SHOW STATUS LIKE` pattern is applied before a `SHOW_SIMPLE_FUNC` is called, so only matching names call it [source: [sql_show.cc:4063-4068](https://github.com/MariaDB/server/blob/mariadb-13.0.2/sql/sql_show.cc#L4063-L4068)]; `SHOW GLOBAL STATUS` without a pattern calls all of them |

[observed] Experiment 32 made a log `write()` block without failing: the log was a FIFO whose reader
stopped reading. Recorded statements waited for it, which the design accepts: one synchronous
`write()` per record, in the statement's own thread. A TABLE-event record blocks the statement itself.
A statement record blocks the connection before its next statement. Plugin 1.2.0 also let the blockage
spread. `SET GLOBAL campus_audit_reopen_now = ON` waited for `sink_lock` inside its update function,
so it held `LOCK_global_system_variables`. From then on `SELECT @@GLOBAL.max_connections`, `SET GLOBAL
max_connections`, `SHOW GLOBAL VARIABLES` and a new connection's `SELECT 1` got no answer for 5 s either:
logging in reads global variables. `SHOW GLOBAL STATUS LIKE 'Campus_audit%'` hung as well. Unrecorded
work went on: an `INSERT` into an unwatched schema took 27 ms. Once the FIFO was read again, a new
connection answered within 39 ms, and the writer's 1000 rows and 1000 records were all there.

Since 1.2.1 the functions that run under a server lock wait for `sink_lock` for a bounded time only:
update functions 2 s, status functions 0.2 s (`TimedLockGuard`, `plugin/src/platform.h`). After
that an update function gives up with a warning. A configuration record is then dropped and counted,
a new `file_path` is not taken, and the log is not reopened. A status function shows `BUSY` or
`(busy)`. The event callbacks still wait as long as the write takes. `tests/plugin/test_stalled_log.sh`
(`make test-stalled-log`, part of `make test-integration` and of the 11.8.9 CI job) repeats the
experiment. On 1.2.0 it gives 7 passed, 10 failed; on 1.2.1, 17 of 17.

Since 1.2.2 update functions do no log I/O at all. The file a new `campus_audit_file_path` or
`campus_audit_reopen_now = ON` needs is opened by the **check** function, before the server's lock,
and the update function only swaps it in. A `config_change` record is formatted in the update
function and written by the same statement's STATUS event, in the same thread (the mechanism
`log_this_statement` already relies on, `test_thread_pool.sh`). A change made while the log is stalled
therefore takes effect at once, and its record is written, not dropped, once the log accepts data
again. One write remains in an update function. When a new file replaces a degraded one, the
`audit_gap` record is written into the file the check function has just opened.
