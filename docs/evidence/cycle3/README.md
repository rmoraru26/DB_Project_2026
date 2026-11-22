# Improvement cycle 3: audit API versions (17 November 2026)

Both independent assessments made after the first merge noted that every observation was made on
MariaDB 13.0.2 only. This cycle built the plugin against the current long-term-support release,
MariaDB **11.8.9**, found that the plugin's own version check refused it, established from the
official headers that the check was stricter than the API, relaxed it, and ran the plugin's tests
against a real 11.8.9 server; then re-ran the full suite on 13.0.2. All runs were made locally by the
AI assistant on the project owner's PC; raw outputs are unedited.

| File | Run | Result |
|---|---|---|
| `01-audit-header-fields.txt` (script `scripts/compare_audit_headers.sh`) | the official `include/mysql/plugin_audit.h` at the tags 10.11.15, 11.4.9, 11.8.9, 12.0.2, 13.0.2 | `0x0302` for 10.11, 11.4, 11.8; `0x0303` for 12.0, 13.0. `0x0302` already has the GENERAL event's `database` and `query_id` and the TABLE event's `query_id`; only the connection event's `port` and `tls_version` are new in `0x0303` |
| `02-build-11.8.9-before-change.txt` | the project's Dockerfile, `MARIADB_IMAGE=mariadb:11.8@sha256:d36f18d6…`, committed tree `8734502` | stops at the plugin's `#error "campus_audit needs audit API 0x0303 or newer"` (GCC then also reports the missing `port` and `tls_version` members) |
| `03-build-11.8.9-after-change.txt` | the same with the change (tree `b0504f765eec`): the check now requires `0x0302`, and `port` / `tls_version` are recorded as `null` with older headers | builds; the seven unit-test programs pass inside the build |
| `04-harness-11.8.9.txt` | `tests/plugin/run_plugin_tests.sh` against a running 11.8.9 server built from that image, with the CHANGE_USER / prepared-statement helper | `Server: 11.8.9-MariaDB-ubu2404`; 134 passed, 0 failed, 0 skipped |
| `05-thread-pool-11.8.9.txt` | `tests/plugin/test_thread_pool.sh` with `THREAD_POOL_IMAGE` = that image | `thread_handling=pool-of-threads`, pool of 2; 30 passed, 0 failed |
| `linux-13.0.2/` | the full Linux run of tree `b0504f765eec` on 13.0.2: fresh `make up` (project `frt-c3-b0504f76`), unit tests, shell suites, repository checks, mutation, `make test`, `make examples`, `make test-integration`, `make test-app` | all exit 0; 187 unit checks; 67 of 67 mutants killed; `make test` 8 of 8 suites (harness 134/0/0, database 18, 22, 24, 36, 24, 16, 3, 10, application 332 passed, 1 skipped); integration 19, 8, 13, 30; `make test-app` 331 passed, 2 skipped |

Not run: MariaDB 10.11 and 11.4 (same interface and fields as 11.8 according to the headers); the
web application and the database scripts on 11.8; native Windows for this tree (the `0x0303` code
path it builds is unchanged; the CI Windows job runs it on push).
