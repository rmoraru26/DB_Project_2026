# Cycle 8, security review of the campus_audit_file_path protection (17 November 2026)

The first version of the protection (commit `d147cdc`) checked an existing file by its **path** and
its **first bytes**. A review against these questions found it insufficient:

| Question | Finding in `d147cdc` | Since this review |
|---|---|---|
| Can the content check be spoofed? | yes: anybody who can write a file can write `{"ts":"`; and any **empty** file was accepted, such as the data file of an empty MyISAM table | content is only the last condition. A regular file must also end in `.jsonl` (no MariaDB data, table or log file does), have one link and belong to the server's OS user (Linux); empty is accepted only for `.jsonl` |
| Symbolic links, hard links, Windows reparse points | followed / not detected / not detected | refused: `O_NOFOLLOW`; `st_nlink` / `nNumberOfLinks` must be 1; `FILE_FLAG_OPEN_REPARSE_POINT` and a reparse-point check on the handle |
| Ownership and permissions | not checked | Linux: owner must be the server's effective user. Windows: not checked (limitation) |
| TOCTOU between check, open and `fchmod` | `stat()` and `fopen()` on the path, then `open()`, then `fchmod()`: a file swapped in between was not detected | every decision is taken on the opened descriptor or handle. On Linux the first bytes are read through a second descriptor whose device and inode must equal the written one; on Windows through the same handle |
| Can permission widening reach a pre-existing file? | yes, any existing file accepted (with `readable_by_all`) | no: `fchmod` only on a file this call created (`O_EXCL` / `OPEN_ALWAYS` with "did not exist") |
| Rotation, reopen, recovery, startup | (untested against the new rule) | tested by `tests/plugin/test_log_path_safety.sh`: rotation by rename and `campus_audit_reopen_now`, recovery after `/dev/full`, server restart reopening the existing log |
| Linux and Windows the same? | the content check ran through the C runtime on both; no link or owner checks on either | the same rules except the owner (Windows); see `docs/security.md`, "Which files the audit log may be" |

A FIFO is now opened with `O_NONBLOCK`, so one without a reader is refused at once; earlier the open
blocked the calling thread.

| File | Run | Result |
|---|---|---|
| `01-unit-tests.txt` | `make -C plugin clean test` (as root in the test-runner container, so the other-owner case runs) | 213 checks, 0 failed, 0 skipped |
| `02-mutation-check.txt` | `python3 scripts/mutation_check.py -j 6` | 75 of 75 mutants killed. S02 and S04-S11 break the new rules one at a time. A first run left S09 (no `O_NOFOLLOW`) alive: the second descriptor's `O_NOFOLLOW` still refused the link. The test now requires the open itself to refuse it |
| `03-plugin-build.txt` | `make -C plugin clean plugin`, MariaDB 13.0.2 headers | exit 0, no warnings |
| `10-server-13.0.2.txt` | `bash scripts/test_server_version.sh mariadb:13.0.2-resolute@sha256:0e4bb0f3…` | harness 141/0/0 (+4: two foreign files refused with reasons, both unchanged); thread pool 30/0; stalled log 19/0; **log path safety 33/0 and, after a restart, 2/0** |
| `11-server-11.8.9.txt` | the same with `mariadb:11.8@sha256:d36f18d6…` | the same counts, 0 failed |
| `20-native-windows-blocked.txt` | `plugin/build_windows.ps1` (Zig 0.16.0, official 13.0.2 zip), then `INSTALL SONAME` into a throw-away native `mariadbd` | the DLL and the unit-test programs **built**. Smart App Control blocked the unit-test program and, this time, also the unsigned DLL (`ERROR 1126 … An Application Control policy has blocked this file`). Nothing ran natively; Windows security was not changed or bypassed. Native Windows results come from the CI job `windows-native` |

An earlier run of `test_server_version.sh` for this tree is not recorded as a result. It overlapped the
native build and the mutation run, and the thread-pool test's throw-away server did not become
reachable in time (25 failed on 13.0.2, 30 passed on 11.8.9). The two "reason is given" checks of the
first version of `test_log_path_safety.sh` also failed: they sent `SHOW WARNINGS` with `-e`, where the
client stops at the error. The script now uses stdin, as the harness does. Both runs above were made
afterwards, alone.

CI for `d147cdc` (run 44121153458): static, Docker and 11.8.9 jobs successful. The **native Windows
job failed** in its end-to-end step. Its log needs a signed-in GitHub account, and the failure could
not be reproduced locally (Smart App Control). The workflow now reports failing checks as public
annotations, so the cause can be read without signing in.

## Second independent review (20 November 2026)

A second reviewer, with no part in the fix, reviewed commit `9a25115` read-only. Verdict: on Linux,
regular files are decided on the opened descriptor without a bypass found; Windows was not sound.
Its findings and what was done:

| Finding | Severity | Change |
|---|---|---|
| Windows accepted UNC paths (`\host\share\x.jsonl`): the service account authenticates to that host (NTLM capture or relay), even for names that are then refused | high | a name starting with `\` or `//` is refused before anything is opened |
| Windows accepted any named pipe or device by name (`\.\pipe\x`), without impersonation protection | high | pipes and devices are refused (`GetFileType` must be a disk file); `SECURITY_SQOS_PRESENT \| SECURITY_IDENTIFICATION` on the open |
| Windows alternate data streams (`table.ibd:x.jsonl`) passed the suffix check and were created without further checks | medium | a `:` other than after a drive letter is refused by name |
| Linux accepted a FIFO or character device of any owner and name (a local user's FIFO receives every record, or stalls the server) | medium | a FIFO must belong to the server's OS user; of the devices only `/dev/null` and `/dev/full`, by device number; inspected through `O_PATH` before any open for writing |
| The Windows symbolic-link test required a message Windows does not produce, so it failed on the elevated CI runner | medium | the Windows message now starts "it is a symbolic link or another reparse point" |
| A file staged by a `SET` whose update never ran could be taken over later | low | each check function first discards this connection's staged file |
| Mutant patterns with `\n`; the owner check needed root | low | single-line patterns; owner hook (`9a25115`); new mutants S12 (FIFO owner) and S13 (device allow-list) |
| Inaccurate documentation (header comment, "the directory is the administrator's choice", "a refusal comes before any write") and undocumented limitations | low | `docs/security.md`, "Which files the audit log may be", rewritten with the remaining limitations |

CI for `9a25115` (run 44837044498): static (unit tests and mutation check as a normal user), Docker
end to end and MariaDB 11.8.9 successful. Native Windows failed in its unit-test step, as the reviewer
predicted for the symbolic-link test. The step's output is now also reported as public annotations.

Docker Desktop was not running on the development PC for this round, so the Linux suites for the
final change ran in CI only. Locally, the sink and its tests were compiled for both platforms with
Zig 0.16.0 (`x86_64-linux-gnu` and `x86_64-windows-gnu`, `-Wall -Wextra`): no errors, no warnings.
Nothing ran natively on Windows (Smart App Control).
