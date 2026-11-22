# Exploratory programs (not part of the test suite)

The team's first two experiments with the `AuditResult` type, kept for the record. They are **not
tests**: they assert nothing, `interactive_open_log.cpp` asks for a path on stdin, and neither is built
by `plugin/Makefile`, `plugin/build_windows.ps1` or CI. Their checks live on in the real unit tests
(`../tests/test_automatic_errors.cpp`, `../tests/test_error_reporter.cpp`, `../tests/test_log_sink.cpp`).

The "Was" column gives each program's original path. In Phase 1 they were moved out of the test
programs into `plugin/tests/exploratory/`, and after the first merge into `plugin/exploratory/`,
outside the test tree altogether, so that nothing under `plugin/tests/` is a program without checks.

| File | Was (former path, removed) | Shows |
|---|---|---|
| `demo_audit_result.cpp` | `plugin/tests/test_auditerror.cpp` | how a success and a failure look as `AuditResult` |
| `interactive_open_log.cpp` | `plugin/tests/test_open_error.cpp` | the first version of `try_open_log()` (never called by the plugin; removed from `plugin/audit_file_check.cpp` after the first merge) |

Build one by hand, e.g. `g++ -std=c++11 demo_audit_result.cpp -o demo && ./demo`.
