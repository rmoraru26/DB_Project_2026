# MariaDB audit plugin API: what campus_audit relies on

Target: **MariaDB 13.0.2**, audit API `MYSQL_AUDIT_INTERFACE_VERSION 0x0303`,
plugin API `MARIA_PLUGIN_INTERFACE_VERSION 0x010f`.

Every statement below is labelled by where it comes from:

- **[doc]**: the official [plugin overview](https://mariadb.com/docs/server/reference/plugins/plugin-overview)
  (installation, `mysql.plugin`, maturity, status).  The
  [audit plugin development](https://mariadb.com/docs/server/reference/product-development/plugin-development/audit-plugin-development)
  page could only be retrieved as its title and summary with our tools, so no statement here rests
  on it; the audit API details below come from the headers and the server source instead.
- **[header]**: comments and declarations in the installed headers
  `include/mysql/plugin.h`, `include/mysql/plugin_audit.h` and `include/mysql/service_*.h`
  (the same files ship in the Windows zip and in `libmariadbd-dev`).
- **[source]**: the server source at tag `mariadb-13.0.2`
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
| CONNECTION CHANGE_USER | after COM_CHANGE_USER, also when it fails (`status` = 1045); fields come from the **old** security context (`sql_audit.h`, `mysql_audit_notify_connection_change_user(thd, old_ctx)`) [source]; confirmed on 13.0.2 with `mysql_change_user()` from `tests/plugin/change_user.c`: a switch a→b is recorded with `user: a`, a failed switch b→a with `user: b` [observed] | same | the account switched **to** (neither on success nor on failure) |
| TABLE LOCK | at the start of each statement, per table it opens, `read_only` = 1 for reads [header] | thread_id, query_id, user, priv_user, priv_host, host, ip, database, table | **rows**, column values, number of rows, whether the statement later succeeded |
| TABLE CREATE / DROP / RENAME / ALTER | DDL on a table; RENAME adds new_database / new_table [header] | same | the DDL text (comes with GENERAL STATUS) |
| GENERAL STATUS | after the result or error was sent to the client [header] | general_thread_id, query_id, general_user (formatted `priv[user] @ host [ip]`), database, general_command, general_error_code, general_query | rows affected (see below), row images, the tables touched |
| GENERAL LOG / ERROR / RESULT / WARNING | ignored by campus_audit | | |

Important consequences:

- **No row images.** No audit event carries old or new column values; `mysql_event_table` has no
  row data at all [header]. campus_audit therefore never claims to record *what* changed in a row.
  Row-level before/after values are captured by SQL triggers instead (`database/triggers.sql`).
- **`general_rows` is not "rows affected".** For STATUS events it is
  `thd->get_stmt_da()->current_row_for_warning()` [source], so campus_audit does not record it.
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
  [source]; `INSERT INTO exp_db.t ...` without `USE` gives a statement record with `"db": null`
  while the table record says `"db": "exp_db"` [observed].
- **Identifiers and timestamps.** `thread_id` equals `CONNECTION_ID()`; `query_id` is a server-wide
  counter, so `(instance, conn, query_id)` identifies a statement [observed, harness check
  "table and statement records share query_id"]. Connection ids restart after a server restart.
  `general_time` has one-second resolution (`my_time(0)`) [source], so campus_audit takes its own
  microsecond UTC timestamp.
- **SQL text** is `thd->query_string` in the client character set [source]. Client libraries such
  as PyMySQL interpolate parameters before sending, so the server sees literal values (emails, booking
  times, password hashes). campus_audit only writes a digest with literals replaced by `?`.
- **Refused statements raise no TABLE event.** The privilege check runs before the server opens a
  table, so `DELETE FROM bookings` by an account without DELETE (ER 1142) produced no record at all
  in plugin 1.0.0 [observed]. Since 1.1.0 the plugin records such a statement from GENERAL STATUS
  (`"access_denied": true`, error 1044/1142/1143/1227/1370) when the session's **default** schema is
  watched; a refused statement that names a watched table from another default schema stays
  invisible, because GENERAL events do not name tables [observed, harness "refused statements"].
- **GENERAL STATUS comes after the client has its answer** (it is raised after
  `end_statement()` [source]). A reader on *another* connection can therefore look at the log
  before the statement record is written. The same connection cannot: the server finishes the
  callback before it reads the next command, which is why the Audit Lab imports the log on the
  request's own connection.
- **Unknown accounts are not refused with 1045.** For an account that does not exist, 13.0.2 for
  Windows answers with an authentication-plugin switch (to `auth_gssapi_client`), so a client
  without that plugin (PyMySQL) aborts; the plugin then records `connect_failed` with status 1158
  (aborted handshake), while the `mariadb` CLI follows the switch and the record says 1045 [observed].
  The server does not reveal whether the account exists; the recorded status depends on the client.

## 3. Callback contract

- `event_notify(MYSQL_THD, unsigned int event_class, const void *event)` returns **void** [header]:
  an audit plugin can observe but not veto or fail a statement. campus_audit is therefore
  necessarily **fail-open** for runtime errors.
- The event structures are local variables of the dispatching function (`mysql_event_general event;`
  in `sql_audit.h`) [source], so their pointers are only valid during the call; campus_audit formats
  everything before returning and keeps no pointers.
- Callbacks run concurrently in many connection threads; the plugin must do its own locking.
- `release_thd` may be NULL; campus_audit holds no per-THD resources.
- Per-connection state: `MYSQL_THDVAR_ULONGLONG(stmt_query_id, PLUGIN_VAR_NOSYSVAR | PLUGIN_VAR_NOCMDOPT, ...)`
  is a hidden session variable used to remember "this statement touched a watched table" until its
  STATUS event (the same technique server_audit uses with a hidden THDVAR string) [header, source].
  It is read and written only in event callbacks, never in a SET GLOBAL update callback (see the
  deadlock trap below).

### Re-entrancy trap found in the source

`my_printf_error(..., ME_ERROR_LOG_ONLY)` looks like the natural way to report a failure from inside
`event_notify`. But `my_message_sql()` (`sql/mysqld.cc`) treats `ME_ERROR_LOG_ONLY` as "no THD" and
then calls `mysql_audit_general(0, MYSQL_AUDIT_GENERAL_ERROR, ...)`, which dispatches to **all audit
plugins through `plugin_foreach()`** (`sql/sql_audit.cc`, `mysql_audit_notify` with `thd == NULL`)
[source]. Reporting from the callback would therefore re-enter audit plugins. campus_audit uses
`my_printf_error` only from init, deinit and SET GLOBAL handlers (never while holding its own locks),
and writes a single rate-limited line to stderr (the server's error log) from inside callbacks.

### Deadlock trap: a THDVAR inside a system-variable update callback (found on Linux)

- `SET GLOBAL` of a plugin variable runs the plugin's `update` callback with
  `LOCK_global_system_variables` held: `sys_var::update()` takes it for every GLOBAL update
  (`sql/set_var.cc`), and `sys_var_pluginvar::global_update()` asserts that it owns it before calling
  `plugin_var->update` (`sql/sql_plugin.cc`) [source].
- `THDVAR(thd, x)` resolves through `intern_sys_var_ptr(thd, offset, true)`. A connection starts
  without its own copy of the plugins' session variables (`plugin_thdvar_init()`, also after
  COM_CHANGE_USER); the first access makes it with `sync_dynamic_session_variables(thd, true)`, which
  locks `LOCK_global_system_variables` itself [source].
- So the first THDVAR access of a connection must not happen inside an update callback. On Linux
  the mutex is a plain pthread mutex (`MY_MUTEX_INIT_FAST`, `sql/mysqld.cc`): the thread waits for
  itself, and every new connection waits behind it, because `THD::init()` takes the same mutex
  (`sql/sql_class.cc`) [source]. On Windows `pthread_mutex_t` is a `CRITICAL_SECTION`
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
  the copy already exists when SET GLOBAL runs [source]. campus_audit 1.1.1 does not depend on that
  order: the mark is a `thread_local` flag, which the statement's own STATUS event reads (a statement
  runs on one OS thread up to that event, also with the thread pool).

### Reading the log back: LOAD_FILE() needs a file readable by all (found on Linux)

- `Item_load_file::val_str` (`sql/item_strfunc.cc`) returns NULL unless the caller has FILE, the
  path is inside `secure_file_priv`, the file is smaller than `max_allowed_packet` **and its mode has
  `S_IROTH`** [source]. The plugin creates its log `0660` and the server's umask applies, so on Linux
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

## 5. Dynamic system-variable storage and callback concurrency

Target: MariaDB 13.0.2, C++11. The official plugin system-variable documentation describes the
check callback's `save` storage and says the update callback stores the accepted value through
`var_ptr`; it explicitly notes an update callback is needed when the plugin wants an atomic value.
It does not document a guarantee that plugin callback reads of the backing storage are synchronized
with concurrent `SET GLOBAL` updates. The event API also invokes the audit callback on concurrent
connection threads. Under the C++11 memory model, an unsynchronized read/write pair on ordinary scalar
storage is a data race, so code must not treat the server's global-variable lock as protecting plugin
reads that do not acquire that lock.

`campus_audit` therefore keeps MariaDB's required backing storage for the sysvars but publishes the
three dynamic scalar settings read by event callbacks (`log_reads`, `connections`, `max_sql_length`)
to atomic runtime copies from their update callbacks. Startup initializes those copies before event
callbacks can run. Callback reads and update stores are relaxed atomics: each setting is independent,
no pointer/object lifetime is being published, and no multi-setting snapshot is required. Database and
user filters remain protected by `filter_lock`; the active log path and sink state remain under
`sink_lock`. The update callbacks retain their existing no-THDVAR rule because MariaDB 13.0.2 invokes
them while holding `LOCK_global_system_variables`.

Context7 references: [MariaDB plugin update callback documentation](https://mariadb.com/docs/server/server-usage/plugins/plugin-system-variables/#update-callback)
and [C++ data races](https://en.cppreference.com/w/cpp/language/multithread). The repository's
13.0.2 evidence remains version-specific; these internal server-lock observations are not asserted as
a stable API guarantee for other MariaDB releases.
- Status variables are registered only after `init` succeeded (`plugin_do_initialize`) [source].
- The check functions are documented for SET [header]; campus_audit does not rely on them running
  for values from `my.cnf` or the command line and validates everything again in `init`. With
  `loose_campus_audit_databases=bad name` in `my.ini`, it was `init` that rejected the value and the
  plugin stayed inactive [observed].
- `loose_` prefixes let the server start before the plugin is installed; the values are used when
  `INSTALL SONAME` runs later [observed with `my.ini`].

## 5. Services

- A dynamic plugin reaches server functions through *services*: each `service_*.h` declares a pointer
  such as `my_print_error_service`; the plugin binary must **define** a variable with that name whose
  initial value is the service version, and the server overwrites it at load time
  (`libservices/*.c`, `sql/sql_plugin.cc` `plugin_dl_add`) [source].
- Normally this comes from linking `libmysqlservices.a` (Linux, package `libmariadb-dev`) or
  `mysqlservices.lib` (Windows). The MSVC-built `mysqlservices.lib` cannot be linked by a GNU
  toolchain (it carries `/DEFAULTLIB:MSVCRT` directives) [observed], so the Zig build compiles
  `plugin/src/service_symbols.cpp`, which contains exactly what `libservices` contains.
- Used services: `my_print_error` (warnings to the client and error log) and `thd_alloc`
  (`thd_strmake` to copy a SET value into statement memory inside a check function).

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
  the plugin name (`plugin_do_initialize`) [source]; they appear as `Campus_audit_*`.

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
