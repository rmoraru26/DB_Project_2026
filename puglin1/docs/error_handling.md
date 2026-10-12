# Error Management for Audit Plugin
## Common Outcome Format
Operations yield an AuditResult that includes:
- code: the category of the error, or None if successful.
- message: a description of the breakdown.
The caller verifies ok() before proceeding.
## Developed independent assessments
| Condition | Outcome |
Please provide the text that you would like to have paraphrased, and I'll be happy to assist!
| Correct file path | None |
| No file path | IncorrectConfiguration |
| Unable to open file | OpenFailed |
The independent test tries to access the file in append mode.It automatically closes the file once the function returns.
## Proposed plugin functionality
- If the log fails to open, logging should remain inactive.
- If writing is unsuccessful during operation, notify about the failure withoutintentionally dismissing database connections.
- Absence of username details is noted as null.
- Unforeseen exceptions should not surpass the MariaDB callback limit.
- The server error log should not be overwhelmed by recurring errors.
## Existing constraints
Handling of write failures and error reporting for MariaDB are not yet in place.
The existing checks operate separately from MariaDB.
Successfully opening a file does not guarantee that subsequent writes will be successful.
## Running the automated checks

From the project root, compile:

g++ -std=c++11 puglin1/audit_file_check.cpp puglin1/tests/test_automatic_errors.cpp -o puglin1/tests/test_automatic_errors.exe

In PowerShell, run:

.\puglin1\tests\test_automatic_errors.exe

Expected output:

PASS: Empty path
PASS: Missing directory
PASS: Valid path
Failures: 0

The test requires audit_test_missing_directory to be absent.
It creates and removes audit_open_test.tmp in the current directory.

The implementation is in audit_file_check.cpp.
The test calls that implementation through audit_file_check.h.

These checks cover empty paths and file-opening results.
They do not yet cover write failures or integration with MariaDB.
Verified local server version: 13.0.2-MariaDB.
Local operating system: Windows.
Verification command: SELECT VERSION();
## Verified audit API declarations

Inspected installed header:
C:\Program Files\MariaDB 13.0\include\mysql\server\mysql\plugin_audit.h

The audit descriptor is st_mysql_audit.

Its event callback signature is:
void event_notify(MYSQL_THD, unsigned int, const void *);

The callback receives the event class and event-specific data.
The class_mask selects the event classes the plugin subscribes to.

Connection event subclasses:
- MYSQL_AUDIT_CONNECTION_CONNECT
- MYSQL_AUDIT_CONNECTION_DISCONNECT
- MYSQL_AUDIT_CONNECTION_CHANGE_USER

Connection event data uses mysql_event_connection.

Relevant fields:
- event_subclass: connection event type.
- status: operation status.
- thread_id: identifier to map to connection_id.
- user and user_length: username data with an explicit length.

The callback returns void, so AuditResult is an internal
component result, not the callback return type.

Username data must be copied using its explicit length.
Pointers from an event must not be retained for later use
without copying their data.

A timestamp is not shown in the inspected connection structure;
our implementation will generate the record timestamp.

Pending verification:
- Exact status semantics for successful and failed connections.
- Supported server error-reporting mechanism.

## Connection event timing

CONNECT occurs after the authentication phase completes.
DISCONNECT occurs after the connection terminates.
CHANGE_USER occurs after the change-user operation completes.

The inspected header does not explain the values of status.
Successful-connection filtering requires further verification.
## Logger service

The installed service_logger.h describes file logging with rotation.
Its documentation states that access is protected by a mutex.

Relevant functions:
- logger_open()
- logger_write()
- logger_sync()
- logger_close()

This service is a possible option for the audit output.
The inspected header does not document the exact return-value
semantics of writing, syncing, and closing.

It does not establish a dedicated server error-log reporting interface.
That mechanism remains to be verified.
## Error-reporting service

Verified installed header:
mysql/service_my_print_error.h

The service provides:
- my_error()
- my_printf_error()
- my_printv_error()

By default, these functions can report errors to the client.

Relevant flags:
- ME_ERROR_LOG: also write to the server error log.
- ME_ERROR_LOG_ONLY: write only to the server error log.
- ME_WARNING: classify the message as a warning.

Proposed runtime audit-failure reporting:
Use my_printf_error() with ME_ERROR_LOG_ONLY.

The error-number argument and service linkage must be verified
during plugin integration.

An integration test must confirm that a logging failure is reported
without changing the client's operation result.