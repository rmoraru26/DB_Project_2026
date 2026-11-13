# Security considerations

## What is never written by the plugin

- **No SQL literals.** Statement records contain a digest in which every string, number, hex/bit
  literal and comment is removed (`plugin/src/record_format.cpp`, `sql_digest`).  Tested in
  `plugin/tests/test_record_format.cpp` (passwords in `IDENTIFIED BY`, password hashes, executable
  comments, 100 kB literals) and end-to-end (`tests/plugin/run_plugin_tests.sh`: "digest masks
  literals", "no password text appears anywhere in the log").
- **Also under `NO_BACKSLASH_ESCAPES`.** A backslash right before a quote ends a literal in that
  sql_mode but escapes the quote by default, and the plugin cannot see the session's sql_mode. Read
  with the default rules, `VALUES ('C:\', 'pw123')` would have put `pw123` into the digest (found by
  the independent review in the code of 1.1.0). Since 1.1.1 everything from such a backslash to the
  end of the statement is masked as one literal, which is safe under either reading; checked by unit
  tests and end to end in a real `NO_BACKSLASH_ESCAPES` session.
- **No passwords from logins.** Connection events never contain the password; the test logs in with a
  wrong password and checks the log for it.
- **No row values.** The audit API does not deliver them.

Comparison: the built-in `server_audit` plugin with `QUERY_DML` logged
`UPDATE users SET password_hash = 'pbkdf2:sha256:600000$SALTsalt$deadbeef' ...` verbatim, and every
booking's literal values (`docs/evidence/exp-server-audit.txt`).

## What is written and why

| Data | Why it is needed | Risk |
|---|---|---|
| database account, host, IP, port | attributing access | personal data of administrators / services |
| attempted user name of failed logins | detecting password guessing | a user may type a password into the user field |
| schema, table, query id, error code | what was accessed and the outcome | low |
| digest (identifiers, keywords) | which kind of statement | table/column names; long statements cut at `max_sql_length` |

Retention and access are the administrator's responsibility.  The plugin creates its log without
any permission for other OS users.  But `LOAD_FILE()`, which the project's import uses, reads only
files that are readable by all (`S_IROTH`, checked in `Item_load_file::val_str`), so on Linux the
import needs `campus_audit_readable_by_all = ON`.  The Docker image sets it and keeps other users out
with the directory instead: `/var/log/campus_audit` is `0750 mysql:mysql`, and the container runs no
other service.  On a native Linux server, turn the option on only for a directory like that.  On
Windows the log inherits the ACL of its directory; the `S_IROTH` check passed there in every run (the
C runtime's `stat()` reports the owner's read permission for others too), so the option has no effect.

## Row history (triggers)

- `users.password_hash` is excluded from the JSON in the `users` triggers; a test checks that no
  `pbkdf2:`/`scrypt:` string ever appears in `audit_events`.
- `audit_events` stores e-mail addresses and names of users (the rows being audited).
- `application_user_id` is asserted by the client (`SET @app_user_id`), not verified by the server,
  and `event_source` only records whether it was set: `application` if `@app_user_id` was non-NULL,
  `direct_sql` if it was NULL. `direct_sql` is therefore not evidence of access outside the web
  application. The web app itself writes with `@app_user_id` NULL in two cases: registration (nobody
  is signed in yet) and the housekeeping that completes past bookings and returns overdue loans of
  *all* users when a signed-in user opens a booking page. The housekeeping clears the variable on
  purpose, so that another user's reservation is never attributed to the visitor; its history rows
  have `application_user_id = NULL`, `event_source = direct_sql`, `database_user = campus_app@<host>`.
  Being signed in is thus not the same as being recorded as the actor. No sentinel user id and no
  extra `event_source` value exist for this; see `docs/design-decisions.md`, "What `event_source`
  means, and what it does not".

## Accounts and least privilege

- The web app connects as `campus_app` with SELECT on `users`, column-level INSERT on only
  `full_name`, `email`, and `password_hash` (registration) and column-level UPDATE on only
  `full_name` and `password_hash` (the account-settings page: change name, change password); it
  cannot assign or change a role, `is_active` or an e-mail address (ER 1143). A refresh of the
  account revokes table-wide INSERT/UPDATE on `users` left by older versions and keeps the column
  grants. It has SELECT/INSERT/UPDATE on `bookings` and `loans` (a future loan is cancelled by
  setting `status = 'cancelled'`, migration 006, not by deleting it),
  SELECT on `rooms`, `items`, `audit_events` and `campus_audit.*`, SELECT/INSERT/UPDATE/DELETE on the
  disposable lab table `audit_lab_notes`, and EXECUTE on `campus_audit.import_current_log()`.
  No DELETE on any real table, no DDL, no FILE, no SUPER (tested: ER 1142 for DELETE on `bookings`
  and for INSERT into `audit_events`; ER 1370 for `import_plugin_log()`; `LOAD_FILE()` returns NULL).
  The triggers write history with their DEFINER's rights.
- `import_current_log()` is `SQL SECURITY DEFINER`, takes no argument and reads only the path in
  `@@GLOBAL.campus_audit_file_path`, which only an administrator can change.  This gives the web app
  fresh plugin records without giving it FILE (which would let it read any file inside
  `secure_file_priv`).
- `audit_lab_intruder` is a decoy account for the lab's failed-login demonstration: no privileges,
  `ACCOUNT LOCK`, and a random password hash nobody knows (created by `database/app_account.sh`).
- Account passwords never appear in SQL text: `database/app_account.sh` and
  `scripts/repair_credentials.sh` send only the mysql_native_password hash
  (`database/native_password_hash.sh`, checked against the server's `PASSWORD()` by
  `tests/database/test_native_password_hash.sh`), so neither the general log nor the process list
  can show them.
- Installing the plugin, `SET GLOBAL campus_audit_*`, `import_plugin_log()` (FILE privilege) and the
  test scripts need an administrator account.  A refused `SET GLOBAL campus_audit_*` is itself
  recorded (`access_denied`, ER 1227) when the session's default schema is watched.
- A local first-run administrator is provisioned by the operator bootstrap using the MariaDB
  administrator connection. The web process only generates a random password and salted hash; its
  `campus_app` database account cannot insert an administrator or change roles. Migration 005 opens a
  one-time database gate only when no administrator exists. Bootstrap stores a protected pending
  credential before changing MariaDB, verifies that password against the application login, then
  atomically promotes it to `.admin-credentials`. A pending file lets startup finish an interrupted
  bootstrap or rotation. On a fresh database, a valid saved credential is reused instead of rotated.
  Ordinary startup verifies an existing credential and never replaces an existing administrator's
  password. A missing/malformed file or a mismatch against an existing administrator fails closed;
  `make reset-admin` is an explicit rotation using the local MariaDB operator credentials. Existing
  installations demote only the known seeded Dana demo identity; unrelated users and administrators
  are preserved.
- `secure_file_priv` is set to the audit log directory in Docker, so `LOAD_FILE()` cannot read
  anything else.

## Tamper evidence (not tamper proof)

An administrator with SUPER can uninstall the plugin or redirect the log.  Each configuration change
is written as a `config_change` record followed by the attributed `SET GLOBAL` statement, and
uninstall/shutdown writes `plugin_stop` with counters, so changes are visible in the log itself.
The file is not signed or hash-chained; forwarding it to a separate log host would be the next step.

## Secrets in the repository

- No real passwords are committed.  `.env.example` contains placeholders; `.env` is git-ignored and
  `scripts/check_repo.py` fails CI if a `.env`, `.pem` or `.key` file is tracked.
- The student demo password `campus-demo-2026` is intentionally public and can authenticate only
  seeded student identities. The seeded Dana identity is migrated to the student role; no seeded
  administrator uses this password. Never reuse it outside a local demo database.
- `make up` reconciles the canonical local administrator with the database's one-time bootstrap gate.
  The generated credential is saved with mode 0600 and is never printed by setup. Windows setup
  disables inherited access and verifies that only the current user, SYSTEM and local Administrators
  have explicit FullControl. On Windows the helper builds an exact allow-only DACL and calls
  `SetNamedSecurityInfoW` with `DACL_SECURITY_INFORMATION` and
  `PROTECTED_DACL_SECURITY_INFORMATION`; it does not request or change SACL, owner or group
  information. DACL verification requests only DACL and owner data. SACL auditing is unrelated to
  granting these three principals file access, so `SeSecurityPrivilege` and administrator elevation
  are not required when the ordinary user owns the file and has DACL modification rights. The
  built-in Administrators SID remains in the DACL for recovery and system administration. Windows
  writes stage a zero-byte file, protect and verify it before writing contents, flush it, then replace
  or move it and verify the actual destination DACL and contents. Replacement retains a recoverable
  prior file until verification succeeds. If protection or verification fails, setup stops, removes
  only its own temporary file where safe, and preserves the existing destination. Keep the files
  private; they are ignored by Git.
  Existing installations run migration 004: it demotes only the known seeded Dana account, preserves
  its row and related history, and leaves unrelated administrator accounts unchanged.
  `scripts/setup_database.sh` and the Docker initdb order run migration 004 after `seed.sql`. The
  seed assigns a role only when it inserts a new row, so re-running the setup or `seed.sql` alone
  neither restores that identity's administrator role nor demotes a locally assigned administrator
  (checked by `tests/database/test_legacy_admin_migration.sh`).
- If the local credential file is lost or malformed, explicitly run `make reset-admin` (or
  `frantastic.cmd reset-admin` on Windows) while MariaDB and the web service are running. It rotates
  only `admin@frantastic.local`, verifies authentication, and replaces the local credential file. If
  that canonical account is absent while other administrators exist, use an authorised DBA recovery
  process; startup will not create another administrator or bypass authentication.
- Test scripts create throwaway accounts with random passwords and drop them again.

## Web application

- Passwords are hashed with Werkzeug (`generate_password_hash`); registration requires 8+ characters.
- Application values use PyMySQL `%s` parameters. The Audit Lab adds only source-controlled SQL
  fragments and a fixed `event_time` identifier; filter values are allow-listed or passed as
  parameters (`frontend/lab.py`). Account bootstrap SQL has a few controlled interpolations: account
  names are fixed, host names are restricted to `[A-Za-z0-9.%_-]+`, and generated password hashes
  are checked against narrow format patterns that exclude SQL quoting characters. The database
  helper does not interpolate user-supplied SQL. These constructions are not treated as injection
  vulnerabilities; do not expand their accepted character sets without revisiting the audit.
- Targeted interpolation review:

  | Site | Interpolated content | Classification and action |
  |---|---|---|
  | `frontend/app.py` login, registration and resource queries | Form values | Parameterized PyMySQL values; unchanged. |
  | `frontend/lab.py` event/history queries | Fixed column lists and fixed SQL fragments; validated filters/parameters | Trusted SQL structure plus parameterized values. `event_time` is a fixed internal identifier; user filters do not become SQL structure. |
  | `database/app_account.sh` | Fixed account/privilege statements, validated host, generated native-password hashes | Controlled SQL construction. Host regex excludes quotes; password hashes are generated by the helper and hash shape is constrained by the MariaDB client syntax. |
  | `scripts/repair_credentials.sh` | Generated native-password hashes | Generated values, checked as `*` plus 40 hex digits before SQL. No user SQL is accepted. |
  | `scripts/provision_local_admin_db.sh` | Generated Werkzeug hash passed to a fixed stored-procedure call | Generated value restricted to hash characters excluding SQL quote/backslash; the database routine controls account identity and role. |
  | `tests/plugin/run_plugin_tests.sh`, `tests/database/test_native_password_hash.sh` | Run IDs, generated fixture accounts/passwords; one test SQL literal has explicit escaping | Test-only generated data. The password-hash test exercises quotes and backslashes through `sql_literal`; not a production query interface. |

  No remaining application SQL site was found where browser-controlled data changes SQL syntax. The
  fixed fragments and constrained generated values are intentionally retained rather than wrapped in
  unnecessary query-building abstractions.
- `SECRET_KEY` is mandatory; the app refuses to start without it.  Flask's debug mode is never
  enabled.
- CSRF: every POST needs the session's token, as a form field or an `X-CSRF-Token` header (the lab's
  JSON calls); without it the request is refused with 400 (tested for every POST route).
- Login throttle: 5 failed logins per 5 minutes per client address and e-mail → HTTP 429.  Lab
  actions: 60 per 5 minutes per user.  Both are in-memory, per process (a restart clears them).
- Session cookie `HttpOnly`, `SameSite=Lax`; set `SESSION_COOKIE_SECURE=1` behind HTTPS.
- The Audit Lab never executes SQL from the browser: the browser names one of seven allow-listed
  actions, the server validates label and quantity, and changes only the caller's own
  `audit_lab_notes` rows.  Its JSON endpoints require a login (401 otherwise), the state-changing
  ones also the CSRF token.  Students only see the plugin records of their own lab connections.
- A database that cannot be reached, or rejects the app's password, gives a 503 page that explains
  the likely cause (never the password); `/healthz` reports it to Compose.
- `login?next=` accepts only the value `lab`, so it cannot be used as an open redirect.
- The app is served by waitress, a production WSGI server (`python app.py`, also in Docker); Flask's
  development server and debug mode are not used.
- Not implemented: HTTPS (the demo binds to 127.0.0.1). The student demo password is public and
  intended only for local learning. Do not expose the demo app beyond `127.0.0.1` with seed data loaded.

## Plugin event-loss counters

`Campus_audit_events_dropped` counts detected event records that could not be recorded, including
allocation/format failures and records lost during sink I/O outages. `Campus_audit_write_failures`
counts failed event-record and recovery-marker write attempts. `audit_gap.dropped_events` is
narrower: it counts event records lost because the log sink was unavailable during one I/O outage;
the marker is written after the sink recovers. Thus the counters are not expected to be equal.
Intentionally filtered events increment `events_filtered`, not `events_dropped`. The API cannot
report activity it never exposes to this plugin. A failed/partial gap-marker write does not mean an
additional database event was lost; a failed marker keeps the outage count and the plugin degraded
until a later recovery can write it. The marker is an aggregate count, not a list of event identities.
Status counters are unsigned 64-bit counts, monotonic within a plugin instance, and reset on plugin
restart/reinitialization; integer wraparound is possible only after 2^64 increments. The I/O-gap count
is held in memory and reset only after its marker is written successfully, so a server crash or plugin
restart before that write cannot preserve the unfinished count.

## Runtime configuration synchronization

The event callback reads dynamic scalar settings (`log_reads`, `connections`, `max_sql_length`) from
atomic runtime copies. MariaDB's plugin variable update callbacks publish validated values into those
copies; callback reads use relaxed atomic operations because each scalar has no dependent data and
does not publish pointers. String filters use the existing reader/writer lock, and log-path state uses
the sink mutex. This avoids unsynchronized C++ scalar accesses without adding a mutex to the hot path.
