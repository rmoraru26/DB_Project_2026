# Error handling in campus_audit

This note began as the team's design notes for the first prototype of the plugin's error handling
(the `AuditResult` type and the first file-open check). The questions it left open were answered
while the plugin was built; this version describes the error handling of `campus_audit` 1.2.5 as
it is in the source. The earlier text is in the Git history of this file.

## The result type

Every internal operation that can fail returns an `AuditResult` (`plugin/audit_error.h`): a `code`
and a human-readable `message`; `ok()` is true only for `AuditError::None`. The event callback
itself returns `void` (the audit API is notification-only), so `AuditResult` never reaches the
server as a return value; it decides what is counted and what is reported.

| Code | Raised by | What happens |
|---|---|---|
| `invalid_Configuration` | `validate_log_path()` (a lexical check: NULL or empty path, longer than 512 bytes, ending in `/` or `\`, control characters; `plugin/audit_file_check.cpp`), `parse_name_list()` for the database and user lists, the system-variable check functions | `SET GLOBAL` is refused with ER 1231 and a warning that names the reason; at `INSTALL SONAME` / server start the plugin does not start (`init` returns 1), because option-file values do not pass through the check functions and are validated again in `init` |
| `open_Failed` | `LogSink::open()` (`plugin/src/log_sink.cpp`), with the operating system's error | `SET GLOBAL campus_audit_file_path` is refused with the reason (the check function opens, and so creates, the new file once to find out); at `init` the plugin does not start; at run time the plugin becomes `DEGRADED` |
| `write_Failed` | a failed or short `write()` of a record | the record is counted as dropped, the plugin becomes `DEGRADED`, closes the file and reopens it on the next event after 5 seconds; when writing works again it first writes an `audit_gap` record with the number of lost events |
| `format_Failed` | a record that does not fit its buffer | the record is dropped and counted; each such record is reported |
| `unexpected_Failure` | the note that announces a recovery ("audit log reopened; N event(s) were lost") | reported once per recovery |

Anything thrown inside an event callback is caught at the callback boundary
(`campus_audit_notify`, `plugin/src/campus_audit.cpp`) and counted as a dropped event: an exception
that crossed the C callback boundary would terminate `mariadbd`. The other functions the server
calls directly are guarded the same way since 1.2.1: every system-variable check and update
function is registered through `guarded_check<>` / `guarded_update<>`, and `init` / `deinit`
through a wrapper. An exception there is counted in `Campus_audit_events_unexpected` and reported;
a check function then refuses the value, and `init` reports that the plugin was not started.

## Fail-open, and how it is announced

The audit API cannot veto a statement, so the plugin is fail-open by design: a statement is never
affected by a logging problem. What is lost is made visible instead. Since 1.2.2 that includes
records lost without an I/O error (a record that did not fit, a failed allocation, an exception):
they are counted without the log mutex and announced by the next `audit_gap` record.

- status variables: `Campus_audit_state` (`ACTIVE`, `DEGRADED`, `CLOSED`, `BUSY` while a write holds the log longer than a status query may wait), `_events_dropped`,
  `_write_failures`, `_open_failures`, `_reopens`, `_last_error`;
- an `audit_gap` record in the log itself when writing resumes;
- a line in the server's error log (below).

## Where reports go

`report_audit_error(result, sink)` (`plugin/audit_error_reporter.cpp`) reports only failures and
ignores a missing sink. There are two sinks, chosen by where the code runs:

| Sink | Used | Mechanism |
|---|---|---|
| `report_to_server` | outside event callbacks: system-variable check and update functions, `init` | the `my_print_error` service: `my_printf_error(ER_UNKNOWN_ERROR, ..., ME_ERROR_LOG \| ME_WARNING)`, so the client gets a warning and the error log gets the line |
| `report_from_callback` | inside `campus_audit_notify` | one line on `stderr`, which is the server's error log. `my_printf_error()` is deliberately not used there: the server dispatches a GENERAL ERROR audit event for it to every audit plugin, i.e. it would re-enter audit plugins from inside a callback (`docs/plugin-api-notes.md`, "Re-entrancy trap") |

An I/O outage is reported once when it starts and once when it ends, however many records it
loses; a record that does not fit its buffer is reported each time.

## Answers to the questions the first notes left open

| Open question then | Answer now |
|---|---|
| Status of successful and failed connections | `status` is 0 for success and the error number otherwise; a failed login is recorded with 1045 (`tests/plugin/run_plugin_tests.sh`, "connections=FAILED records a failed login") |
| Which error-reporting mechanism to use | the `my_print_error` service outside callbacks, `stderr` inside them (above) |
| The `logger` service | not used; the plugin writes through its own `LogSink` (`plugin/src/log_sink.cpp`): one `write()` per record, `O_APPEND`, no `fsync` |
| Whether a successful open guarantees later writes | it does not; write failures are handled separately (`write_Failed` above) |

## The first file-open check

The team's first file-open check, `try_open_log()` (`std::ofstream` in append mode), was never
called by the plugin, which opens its log through `LogSink::open()` with `validate_log_path()` and
the operating system's `open()`. It was removed from `plugin/audit_file_check.cpp` after the first
merge, together with its three unit-test cases; the original program is
`plugin/exploratory/interactive_open_log.cpp`.

## A log that stalls instead of failing

Fail-open covers errors. A destination that stops accepting data without failing, such as a hung
network file system or a full pipe, makes the `write()` of a record block. The statement that wrote it
and every later recorded statement then wait: the audit API cannot hand a record over without
waiting. Unrecorded statements are not affected.

Up to 1.2.0 the blockage spread further (experiment 32). A `SET GLOBAL campus_audit_*` waited for the
log mutex while the server held `LOCK_global_system_variables`. Logins and every `SELECT @@GLOBAL...`
or `SET GLOBAL` then waited as well. `SHOW STATUS` of the plugin waited while holding
`LOCK_all_status_vars` (`docs/plugin-api-notes.md`, section 9). Since 1.2.1:

| Where | Waits for the log | Then |
|---|---|---|
| event callback | as long as the write takes | (the statement waits) |
| system-variable check function (`file_path`, `reopen_now`) | runs before the server's lock | opens the new file; the update function swaps it in (1.2.2) |
| system-variable update function | for the log mutex at most 2 s; normally no log I/O of its own (1.2.2; the exceptions are in `docs/plugin-api-notes.md`, section 9) | gives up with a warning naming the busy log: `campus_audit_file_path` keeps the old file, `campus_audit_reopen_now` does not reopen. Other variables take effect at once; their `config_change` record is written by the statement's STATUS event, when the log accepts data again |
| status function | at most 0.2 s | `Campus_audit_state` shows `BUSY`; `_file` and `_last_error` show `(busy)` |

`tests/plugin/test_stalled_log.sh` checks all of this against a FIFO whose reader stops reading.

## Files the log may not be

`LogSink::open` refuses a symbolic link, a hard-linked file, a file of another OS user (Linux), a
regular file whose name does not end in `.jsonl`, and an existing file that is neither empty nor a
campus_audit log, all decided on the opened descriptor or handle. It widens permissions only on a
file it has just created. The refusal is an `open_Failed` result with the reason, so it travels
the same way as any other open failure (ER 1231 for `SET GLOBAL`, no start at `init`). Rules,
platform differences and limitations: `docs/security.md`, "Which files the audit log may be".

## A side effect of the file-path check

To refuse an unwritable path with the reason, the check function of `campus_audit_file_path`
opens the new file once, which creates it if it did not exist. If the update that follows then
fails, that empty file stays. It is deliberately not deleted: removing a file from inside the
server after an existence check could remove a file another process created in between, which is
worse than an empty file.

## Tests

| What | Where |
|---|---|
| `validate_log_path()` | `plugin/tests/test_automatic_errors.cpp` |
| `report_audit_error()` | `plugin/tests/test_error_reporter.cpp` |
| open and write failures of `LogSink`, file modes | `plugin/tests/test_log_sink.cpp` |
| outage accounting (`audit_gap` counts) | `plugin/tests/test_gap_accounting.cpp` |
| the loaded plugin: refused configuration (ER 1231 with reasons), a path the server may not write, a write failure through `/dev/full`, `DEGRADED`, recovery, the `audit_gap` record | `tests/plugin/run_plugin_tests.sh`, sections "configuration validation" and "I/O failure behaviour" |
| a locked log file on Windows | `docs/experiments.md`, experiment 4 |
| which files may be opened: links, other owners, wrong names, foreign content; rotation, recovery and restart afterwards | `plugin/tests/test_log_sink.cpp`; `tests/plugin/test_log_path_safety.sh` (`make test-log-path-safety`) |
| a log that stalls without failing (FIFO), what keeps answering | `tests/plugin/test_stalled_log.sh` (`make test-stalled-log`); experiment 32 |

Run the unit tests with `make -C plugin test` (Linux) or `plugin\build_windows.ps1` (Windows), the
harness with `make test-e2e`.
