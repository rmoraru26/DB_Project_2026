# Improvement cycle 2 (17 November 2026)

Cycle 2 acts on two independent assessments made in fresh contexts after the first merge: the
official one of `main` (`abdfa3a`) and a shadow one of the cycle-1 branch (`2aa163d`). Both scored
36/40 (9, 9, 9, 9); the changes below address the reasons they gave for withholding points, each
checked against the source first. All runs were made locally by the AI assistant on the project
owner's PC; raw outputs are unedited.

## Changes

| Finding (assessment) | Checked | Change |
|---|---|---|
| `plugin/docs/error_handling.md`, linked from the README, was the first prototype's notes: a stray chat sentence, paths of the deleted `puglin1/` folder, "write failures not yet in place", advice to call `my_printf_error(ME_ERROR_LOG_ONLY)` from the callback | yes | rewritten from the source: result codes, where each arises, fail-open, the two report sinks, the answers to the questions the first notes left open, the tests |
| `[source]` claims in `docs/plugin-api-notes.md` cannot be checked (no lines) | yes | all 16 now link the file and line at tag `mariadb-13.0.2` on GitHub; one call chain corrected (`intern_sys_var_ptr(…, true)` → `sync_dynamic_session_variables(thd, global_lock)`) |
| The README's "Building and installing the plugin yourself" on Linux was never run, and "install the headers" did not say how | yes | run in full (file 01); the README names the packages |
| "injects 65 bugs" (67), "60-line skeleton" (about 50 lines of code), "eight system variables" (9), "single rate-limited line" (only I/O outages are), "recovery within 5 s" (needs the next event), a benchmark "not run on Linux" (it was, in a container), a backspace byte in `docs/testing.md`, examples 06/07 out of order, a results heading that named one run for rows of two | yes, each | corrected |
| The skeleton uses `__atomic_add_fetch` | yes | kept (both documented build commands, g++ and `zig c++`, support it; `std::atomic` would break the status-variable pointers); the README says which compilers support it |

## Results

| File | Run | Result |
|---|---|---|
| `01-native-linux-install.txt` (driver `scripts/native_linux_install.sh`) | the README's Linux path without the project's Docker build: Ubuntu 26.04.1 with the MariaDB `1:13.0.2+maria~ubu2604` packages (the official image the project pins, started as a plain container without its entrypoint). Toolchain and headers by apt; `make -C plugin test`; `make -C plugin`; copy to `@@plugin_dir`; option file with `plugin_maturity = beta` and `loose_campus_audit_readable_by_all = ON`; a 0750 log directory; restart; `setup_database.sh`; `demo.sh`; the README's verification SQL; the harness; the web application with `python app.py` | every step exit 0; `campus_audit ACTIVE AUDIT campus_audit.so 1.2.0 Beta`, 9 system and 11 status variables, `Campus_audit_state = ACTIVE`, 0 dropped; harness 134 passed, 0 failed, 0 skipped; `GET /healthz` 200 (`{"status":"ok","database":"ok"}`), `/` 200, `/lab` 200 |

Not done here: a physical Linux host (the run is in a container on Docker Desktop); macOS.
