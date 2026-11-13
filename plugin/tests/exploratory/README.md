# Exploratory programs (not part of the test suite)

The team's first two experiments with the `AuditResult` type, kept for the record. They are **not
tests**: they assert nothing, `interactive_open_log.cpp` asks for a path on stdin, and neither is built
by `plugin/Makefile`, `plugin/build_windows.ps1` or CI. Their checks live on in the real unit tests
(`../test_automatic_errors.cpp`, `../test_error_reporter.cpp`, `../test_log_sink.cpp`).

| File | Was | Shows |
|---|---|---|
| `demo_audit_result.cpp` | `plugin/tests/test_auditerror.cpp` | how a success and a failure look as `AuditResult` |
| `interactive_open_log.cpp` | `plugin/tests/test_open_error.cpp` | the first version of `try_open_log()` (now in `plugin/audit_file_check.cpp`) |

Build one by hand, e.g. `g++ -std=c++11 demo_audit_result.cpp -o demo && ./demo`.
