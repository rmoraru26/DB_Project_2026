#!/usr/bin/env python3
"""Mutation check for the plugin's unit tests (needs g++ and make, no server).

Unit tests that pass prove little unless they also *fail* when the code is
wrong.  This script copies plugin/ into a scratch directory, injects one
deliberate bug at a time (a "mutant"), rebuilds and runs the unit tests, and
reports whether the tests noticed.

    python3 scripts/mutation_check.py            # run all mutants, 4 in parallel
    python3 scripts/mutation_check.py -j 8 -v    # more workers, show test output
    python3 scripts/mutation_check.py --list     # list the mutants only

Result per mutant:
    killed    the unit tests failed (or crashed / timed out) -- good
    SURVIVED  all unit tests still passed -- the tests miss this bug
    invalid   the mutant did not compile (the script's edit is wrong)

Exit status: 0 when every mutant was killed, 1 if any survived or was invalid.
Only the repository's own sources are modified, and only inside the scratch
copy; nothing in the working tree is touched.
"""
import argparse
import concurrent.futures
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugin"

# (id, file relative to plugin/, exact text to replace (must occur once), replacement, what the bug is)
MUTANTS = [
    # ------------------------------------------------------------ digest: literals must be masked
    ("D01", "src/record_format.cpp", "        if (c == '\\'' || c == '\"') {", "        if (c == '\"') {",
     "single-quoted strings are no longer masked"),
    ("D02", "src/record_format.cpp", "        if (c == '\\'' || c == '\"') {", "        if (c == '\\'') {",
     "double-quoted strings are no longer masked"),
    ("D03", "src/record_format.cpp",
     "} else if (is_digit(c) || (c == '.' && i + 1 < length && is_digit(s[i + 1]))) {", "} else if (false) {",
     "numbers are no longer masked"),
    ("D04", "src/record_format.cpp", "|| (c == '.' && i + 1 < length && is_digit(s[i + 1]))) {", ") {",
     "numbers starting with '.' are no longer masked"),
    ("D05", "src/record_format.cpp",
     "} else if ((d == '+' || d == '-') && (s[i - 1] == 'e' || s[i - 1] == 'E')) {", "} else if (false) {",
     "exponent signs end a number early (1.5e-3 leaks '3')"),
    ("D06", "src/record_format.cpp", "if (prefix && i < length && s[i] == '\\'') {", "if (false) {",
     "X'..', B'..', N'..' and _charset'..' literals are no longer masked"),
    ("D07", "src/record_format.cpp", "if (c == '\\\\' && quote != '`' && i + 1 < length) {", "if (false) {",
     "backslash escapes inside strings are ignored (a \\' ends the literal early)"),
    ("D08", "src/record_format.cpp", "if (i + 1 < length && s[i + 1] == quote) {  // doubled quote",
     "if (false) {  // doubled quote", "doubled quotes ('it''s') end the literal early"),
    ("D09", "src/record_format.cpp", "if (c == '\\\\' && quote != '`' && i + 1 < length) {",
     "if (c == '\\\\' && i + 1 < length) {",
     "a backslash is treated as an escape inside `identifiers` too"),
    ("D16", "src/record_format.cpp", "if (s[i + 1] == quote) {", "if (false) {",
     "a backslash before a quote is read as an escape, so under NO_BACKSLASH_ESCAPES the next literal leaks"),
    ("D10", "src/record_format.cpp", "if (c == '#' ||", "if (false && c == '#' ||",
     "# comments are kept (they can carry secrets)"),
    ("D11", "src/record_format.cpp", "s[i + 1] == '-' &&\n", "s[i + 1] == '-' && false &&\n",
     "-- comments are kept"),
    ("D12", "src/record_format.cpp", "if (c == '/' && i + 1 < length && s[i + 1] == '*') {", "if (false) {",
     "/* */ and /*! */ comments are kept"),
    ("D13", "src/record_format.cpp", "if (is_space(c)) {\n            pending_space = true;",
     "if (is_space(c)) {\n            pending_space = false;", "whitespace is not collapsed to one space"),
    ("D14", "src/record_format.cpp", "if (truncated) *truncated = cut;", "if (truncated) *truncated = false;",
     "a cut digest is not flagged as truncated"),
    ("D15", "src/record_format.cpp",
     "while (start > 0 && (static_cast<unsigned char>(out[start]) & 0xC0) == 0x80) --start;",
     "while (false) --start;", "a truncated digest may end inside a multi-byte UTF-8 character"),
    # ------------------------------------------------------------ JSON writer
    ("J01", "src/record_format.cpp", "if (c == '\"' || c == '\\\\') {", "if (c == '\"') {",
     "backslash is not escaped in JSON"),
    ("J02", "src/record_format.cpp", "} else if (c < 0x20 || c == 0x7F) {", "} else if (c == 0x7F) {",
     "control characters below 0x20 are not escaped"),
    ("J03", "src/record_format.cpp", "} else if (c < 0x20 || c == 0x7F) {", "} else if (c < 0x20) {",
     "DEL (0x7F) is not escaped"),
    ("J04", "src/record_format.cpp", "put_raw(\"\\\\ufffd\", 6);\n                ++i;",
     "put_raw(s + i, 1);\n                ++i;", "invalid UTF-8 bytes are copied into the JSON line"),
    ("J05", "src/record_format.cpp", "if (length_ + 1 >= capacity_) {  // keep room for a final NUL",
     "if (length_ + 1 > capacity_) {  // keep room for a final NUL",
     "off-by-one: the writer stores its NUL one byte past the buffer"),
    ("J06", "src/record_format.cpp", "put_raw(\"null\", 4);\n        return;",
     "put_raw(\"\\\"\\\"\", 2);\n        return;", "a missing (NULL) value is written as an empty string instead of null"),
    ("J07", "src/record_format.cpp", "put('}');\n    put('\\n');", "put('}');",
     "records are no longer terminated by a newline"),
    ("J08", "src/record_format.cpp", "*truncated = value != nullptr && keep < length;", "*truncated = false;",
     "a bounded string cut short is not flagged"),
    # ------------------------------------------------------------ configuration lists
    ("N01", "src/record_format.cpp", "if (!name_char_allowed(static_cast<unsigned char>(start[k]), kind)) {",
     "if (false) {", "unsupported characters in schema/user names are accepted"),
    ("N02", "src/record_format.cpp", "if (out->count == NameList::kMaxNames) {", "if (false) {",
     "more than 16 names are accepted (buffer overrun)"),
    ("N03", "src/record_format.cpp", "if (n > static_cast<size_t>(NameList::kMaxNameLength)) {", "if (false) {",
     "names longer than 128 characters are accepted (buffer overrun)"),
    ("N04", "src/record_format.cpp", "            if (*p == '\\0') {\n                return {AuditError::invalid_Configuration,\n"
     "                        std::string(\"trailing comma in \")",
     "            if (false) {\n                return {AuditError::invalid_Configuration,\n"
     "                        std::string(\"trailing comma in \")", "a trailing comma in a list is accepted"),
    ("N05", "src/record_format.cpp", "if (out->match_all && out->count > 0) {", "if (false) {",
     "'*' may be combined with explicit names"),
    ("N06", "src/record_format.cpp", "} else if (n == 1 && *start == '*' && kind == NameKind::Database) {",
     "} else if (n == 1 && *start == '*') {", "'*' is accepted in the user list"),
    ("N07", "src/record_format.cpp", "if (list.match_all) return !is_system_schema(db, length);",
     "if (list.match_all) return true;", "'*' also audits mysql / information_schema / performance_schema / sys"),
    ("N08", "src/record_format.cpp", "return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;",
     "return c;", "schema names are matched case-sensitively"),
    ("N09", "src/record_format.cpp", "if (alen != blen) return false;", "if (false) return false;",
     "a schema name matches when it is only a prefix of a watched name"),
    ("N10", "src/record_format.cpp", "if (std::strlen(list.names[k]) == length &&", "if (true &&",
     "an excluded user matches when the login is only a prefix of the listed name"),
    # ------------------------------------------------------------ timestamps and helpers
    ("T01", "src/record_format.cpp", "rem / 60 % 60", "rem / 60", "minutes are not reduced modulo 60"),
    ("T02", "src/record_format.cpp", "(seconds - 86399) / 86400", "seconds / 86400",
     "timestamps before 1970 round the wrong way"),
    ("T03", "src/record_format.cpp", "if (m <= 2) ++y;", "if (false) ++y;", "January and February get the previous year"),
    ("T04", "src/record_format.cpp", "while (n < max_scan && s[n] != '\\0') ++n;",
     "while (n <= max_scan && s[n] != '\\0') ++n;", "bounded_length reads one byte past its limit"),
    # ------------------------------------------------------------ path validation and file sink
    ("P01", "audit_file_check.cpp", "path.size() > 512", "path.size() > 5120", "over-long paths are accepted"),
    ("P02", "audit_file_check.cpp", "if (static_cast<unsigned char>(c) < 0x20 || c == 0x7F) {", "if (false) {",
     "control characters in the log path are accepted"),
    ("P03", "audit_file_check.cpp", "if (last == '/' || last == '\\\\') {", "if (last == '/') {",
     "a path ending in a backslash (Windows directory) is accepted"),
    ("S01", "src/log_sink.cpp", "if (!valid.ok()) return valid;", "(void)valid;",
     "LogSink::open skips path validation"),
    ("S02", "src/log_sink.cpp", "O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK",
     "O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK",
     "the log is not opened in append mode (a reopen overwrites it)"),
    ("S03", "src/log_sink.cpp", "O_CLOEXEC, 0660)", "O_CLOEXEC, 0666)",
     "the log file is created world-readable"),
    # ------------------------------------------------------------ which files may be opened (1.2.4)
    ("S04", "src/log_sink.cpp", "        if (st.st_nlink != 1) {", "        if (false) {",
     "a hard-linked file is appended to"),
    ("S05", "src/log_sink.cpp", "std::memcmp(head + i, kRecordPrefix, want) == 0", "true",
     "any existing non-empty file counts as a campus_audit log"),
    ("S06", "src/log_sink.cpp", "    if (n < k) return false;\n", "    if (n < k) return true;\n    return true;\n",
     "a regular file of any name (a table file) is accepted"),
    ("S07", "src/log_sink.cpp", "while (i < n && (head[i] == '\\n' || head[i] == '\\r')) ++i;", "",
     "a log that begins with the newline of an audit_gap record is refused"),
    ("S08", "src/log_sink.cpp", "        } else if (static_cast<long>(st.st_uid) !=\n", "        } else if (false &&\n",
     "a file of another OS user is appended to"),
    ("S09", "src/log_sink.cpp", "O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK",
     "O_WRONLY | O_APPEND | O_CLOEXEC | O_NONBLOCK",
     "a symbolic link to a log-like file is followed"),
    ("S10", "src/log_sink.cpp", "if (readable_by_all_ && created) {", "if (readable_by_all_) {",
     "readable_by_all widens the permissions of an existing file"),
    ("S11", "src/log_sink.cpp", "flags & ~O_NONBLOCK", "flags",
     "the log descriptor stays non-blocking (records are lost instead of waiting)"),
    # ------------------------------------------------------------ refused statements (1.1.0)
    ("A01", "src/record_format.cpp", "return code == 1044 || code == 1142 ||", "return code == 1044 ||",
     "a refused DELETE/UPDATE/INSERT (ER 1142) is no longer recorded"),
    ("A02", "src/record_format.cpp", "account[n] != '[' && account[n] != '\\0'", "account[n] != '\\0'",
     "the whole account string is compared with campus_audit_exclude_users, so exclusions stop working"),
    # ------------------------------------------------------------ readable_by_all (1.1.1)
    ("R01", "src/log_sink.cpp", "if (st.st_mode & S_IROTH) return 0;", "return 0;",
     "campus_audit_readable_by_all leaves the log unreadable for LOAD_FILE()"),
    # ------------------------------------------------------------ statement scope SESSION (1.2.0)
    ("C01", "src/statement_scope.h", "const bool session = f.scope == kScopeSession && unclassified &&",
     "const bool session = unclassified &&",
     "the default scope TABLES also records table-less statements (the opt-in is ignored)"),
    ("C02", "src/statement_scope.h", "f.sql_command && !f.any_table_event && !f.open_recorded_statement;",
     "f.sql_command && !f.open_recorded_statement;",
     "SESSION also records statements whose table events were deliberately not recorded (reads, other schemas)"),
    ("C11", "src/statement_scope.h", "f.sql_command && !f.any_table_event && !f.open_recorded_statement;",
     "f.sql_command && !f.any_table_event;",
     "SESSION records every trigger body statement as if the client had sent it"),
    ("C12", "src/statement_scope.h", "f.sql_command && !f.any_table_event && !f.open_recorded_statement;",
     "!f.any_table_event && !f.open_recorded_statement;",
     "SESSION records protocol commands such as Quit as statements"),
    ("C13", "src/statement_scope.h", '(length == 7 && std::memcmp(command, "Execute", 7) == 0);', "false;",
     "prepared statements executed through the binary protocol are never recorded by SESSION"),
    ("C14", "src/statement_scope.h", 'return (length == 5 && std::memcmp(command, "Query", 5) == 0) ||',
     "return length >= 4 ||",
     "any protocol command with a name of four letters or more counts as a statement (Quit, Ping)"),
    ("C03", "src/statement_scope.h", "(f.latched || f.default_schema_watched);", "f.default_schema_watched;",
     "DML under LOCK TABLES from another default schema is not recorded (rule (b) lost)"),
    ("C04", "src/statement_scope.h", "(f.latched || f.default_schema_watched);", "f.latched;",
     "trigger/view DDL in a watched default schema is not recorded (rule (a) lost)"),
    ("C05", "src/statement_scope.h", "        track->seen_query_id = query_id;\n        track->latched = 0;",
     "        track->seen_query_id = query_id;",
     "the latch is never cleared: every later table-less statement of the connection is recorded"),
    ("C06", "src/statement_scope.h", "        track->recorded_query_id = query_id;\n        track->latched = 1;",
     "        track->recorded_query_id = query_id;",
     "the latch is never set: nothing under LOCK TABLES is recorded"),
    ("C07", "src/statement_scope.h", "    d.apply_user_filter = true;", "    d.apply_user_filter = false;",
     "campus_audit_exclude_users is ignored for refused and session-scope statements"),
    ("C08", "src/statement_scope.h", "    const bool refused = f.access_denied && f.default_schema_watched;",
     "    const bool refused = f.access_denied;",
     "refusals in sessions of unwatched schemas are recorded"),
    ("C09", "src/statement_scope.h", "    d.mark_session = session;", "    d.mark_session = false;",
     "session-scope records are not marked, so they cannot be told from table-backed ones"),
    ("C10", "src/record_format.cpp",
     "        if (equals_exact(db, length, sys)) return true;",
     "        if (false) return true;",
     "mysql and sys no longer count as system schemas: CREATE PROCEDURE (event on mysql.proc) is never recorded"),
    ("N12", "src/record_format.cpp",
     "        if (equals_exact(db, length, sys)) return true;",
     "        if (equals_ignore_case(db, length, sys)) return true;",
     "a user schema `MySQL` or `Sys` is taken for the system schema and silently not audited by '*'"),
    ("N13", "src/record_format.cpp",
     "        if (equals_ignore_case(db, length, sys)) return true;\n    }\n    return false;\n}\n\nbool database_matches",
     "        if (equals_exact(db, length, sys)) return true;\n    }\n    return false;\n}\n\nbool database_matches",
     "INFORMATION_SCHEMA / Performance_Schema in another case are audited by '*' like a user schema"),
    # ------------------------------------------------------------ outage accounting and atomic settings
    ("G01", "src/gap_accounting.h", "if (written) dropped_ = 0;", "dropped_ = 0;",
     "a recovery marker that could not be written still erases the count of lost events"),
    ("G02", "src/gap_accounting.h", "void event_lost_to_io() { ++dropped_; }", "void event_lost_to_io() { }",
     "events lost to an I/O failure are not counted"),
    ("G03", "src/gap_accounting.h", "        return written;", "        return true;",
     "a failed recovery marker is reported as written, so the plugin leaves the degraded state"),
    ("G04", "src/runtime_config.h", "connections(1), statement_scope(0)", "connections(1), statement_scope(1)",
     "the statement scope starts as SESSION before the configured value is published"),
    # Not mutated on purpose: LogSink::write_all's `n == 0` branch (a write() that returns 0 for a
    # non-empty buffer).  No real descriptor can be made to do that, so it cannot be tested without
    # fault injection; it is a defensive guard against an endless loop.
    # Nor LogSink's comparison of device and inode between the descriptor it writes and the one it
    # reads the first bytes through: it only matters if the file is replaced between the two open()
    # calls, a race a unit test cannot provoke reliably.
]


def run(cmd, cwd, timeout):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                           env={"PATH": "/usr/bin:/bin:/usr/local/bin", "CXXFLAGS": "-O0"})
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"")
        out = out.decode(errors="replace") if isinstance(out, bytes) else out
        return None, out + "\n<timed out>"


def make_copy(dest):
    shutil.copytree(PLUGIN, dest, ignore=shutil.ignore_patterns("build"))


def classify(code, out):
    if code is None:
        return "killed", "timed out (hang)"
    if code == 0:
        return "SURVIVED", ""
    if "error:" in out and "FAIL:" not in out and "Failures:" not in out:
        return "invalid", out.strip().splitlines()[-1] if out.strip() else ""
    if "FAIL:" in out:
        names = [l[6:].strip() for l in out.splitlines() if l.startswith("FAIL:")]
        return "killed", f"{len(names)} failing check(s): {names[0]}"
    return "killed", f"test program crashed or failed (exit {code})"


def one(mutant, workdir, timeout):
    mid, rel, old, new, what = mutant
    dest = pathlib.Path(workdir) / mid
    make_copy(dest)
    target = dest / rel
    text = target.read_text(encoding="utf-8")
    if text.count(old) != 1:
        return mid, what, "invalid", f"pattern occurs {text.count(old)} times in {rel}", ""
    target.write_text(text.replace(old, new), encoding="utf-8")
    code, out = run(["make", "test"], dest, timeout)
    status, detail = classify(code, out)
    shutil.rmtree(dest, ignore_errors=True)
    return mid, what, status, detail, out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", "--jobs", type=int, default=4)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--timeout", type=int, default=120, help="seconds per mutant")
    args = ap.parse_args()

    if args.list:
        for mid, rel, _, _, what in MUTANTS:
            print(f"{mid}  {rel:24} {what}")
        return 0
    for tool in ("make", "g++"):
        if shutil.which(tool) is None:
            print(f"{tool} not found", file=sys.stderr)
            return 2

    with tempfile.TemporaryDirectory(prefix="campus_mut_") as work:
        base = pathlib.Path(work) / "baseline"
        make_copy(base)
        code, out = run(["make", "test"], base, args.timeout)
        if code != 0:
            print("The unmutated unit tests fail; fix them before running the mutation check.\n" + out)
            return 2
        print(f"baseline: unit tests pass; running {len(MUTANTS)} mutants with {args.jobs} workers\n")

        results = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(one, m, work, args.timeout) for m in MUTANTS]
            for f in futures:
                results.append(f.result())

    order = {m[0]: i for i, m in enumerate(MUTANTS)}
    results.sort(key=lambda r: order[r[0]])
    for mid, what, status, detail, out in results:
        print(f"{mid}  {status:8}  {what}")
        if detail and (status != "killed" or args.verbose):
            print(f"      {detail}")
        if args.verbose and status == "SURVIVED":
            print(out)
    killed = sum(1 for r in results if r[2] == "killed")
    survived = [r[0] for r in results if r[2] == "SURVIVED"]
    invalid = [r[0] for r in results if r[2] == "invalid"]
    print(f"\n{killed} of {len(results)} mutants killed; survived: {survived or 'none'}; invalid: {invalid or 'none'}")
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
