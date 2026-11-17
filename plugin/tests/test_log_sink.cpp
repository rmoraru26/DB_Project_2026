// Unit tests for LogSink: path validation, open failures, appending, and a
// real write failure provoked by closing the descriptor behind the sink's
// back (EBADF).  On Linux, /dev/full additionally gives ENOSPC.
//
// Run from a writable working directory; the test creates and removes
// sink_test_*.jsonl there.

#include "../src/log_sink.h"

#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#ifdef _WIN32
#include <io.h>
#define close_fd _close
#else
#include <sys/stat.h>
#include <unistd.h>
#define close_fd close
#endif

using campus_audit::LogSink;

static int failures = 0;

static void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS: " : "FAIL: ") << name << '\n';
    if (!condition) ++failures;
}

// Records as the plugin writes them: every one begins with {"ts":"
// (LogSink::open refuses to append to a non-empty file that does not).
static const char R1[] = "{\"ts\":\"t1\",\"a\":1}\n";
static const char R2[] = "{\"ts\":\"t2\",\"a\":2}\n";
static const char R3[] = "{\"ts\":\"t3\",\"a\":3}\n";

static bool write(LogSink& sink, const char* record) {
    return sink.write_all(record, std::string(record).size()).ok();
}

static std::string read_file(const char* path) {
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

int main() {
    const char* path = "sink_test_append.jsonl";
    std::remove(path);

    {
        LogSink sink;
        check(sink.open(nullptr).code == AuditError::invalid_Configuration, "NULL path rejected");
        check(sink.open("").code == AuditError::invalid_Configuration, "empty path rejected");
        check(sink.open("some_dir/").code == AuditError::invalid_Configuration,
              "directory-like path rejected");
        check(sink.open("some_dir\\").code == AuditError::invalid_Configuration,
              "directory-like path ending in a backslash rejected");
        check(sink.open("bad\npath").code == AuditError::invalid_Configuration,
              "control character in path rejected");
        check(sink.open(std::string(600, 'a').c_str()).code == AuditError::invalid_Configuration,
              "over-long path rejected");
        AuditResult r = sink.open("sink_test_missing_dir/x.jsonl");
        check(r.code == AuditError::open_Failed, "missing directory reported as open_Failed");
        check(r.message.find("errno") != std::string::npos, "open failure message carries errno");
        check(!sink.is_open(), "sink stays closed after failed open");
        check(sink.write_all("x\n", 2).code == AuditError::write_Failed, "write on closed sink fails");
    }

    {
        LogSink sink;
        check(sink.open(path).ok(), "valid path opened");
        check(write(sink, R1), "first record written");
        AuditResult bad = sink.open("sink_test_missing_dir/y.jsonl");
        check(!bad.ok() && sink.is_open(), "failed re-open keeps the previous file open");
        check(write(sink, R2), "previous file still writable");
    }
    {
        LogSink sink;
        check(sink.open(path).ok() && write(sink, R3), "re-opened file is appended to");
    }
    check(read_file(path) == std::string(R1) + R2 + R3, "file holds all records in order");

    {
        // A foreign file is never appended to: campus_audit_file_path needs
        // SYSTEM_VARIABLES_ADMIN, not FILE, and must not become a way to write
        // into (or, with readable_by_all, expose) any file the server can write.
        const char* foreign = "sink_test_foreign.dat";
        std::remove(foreign);
        { std::ofstream out(foreign, std::ios::binary); out << "not an audit log\n"; }
#ifndef _WIN32
        chmod(foreign, 0600);
#endif
        LogSink sink;
        sink.set_readable_by_all(true);
        AuditResult r = sink.open(foreign);
        check(r.code == AuditError::open_Failed, "an existing foreign file is refused");
        check(r.message.find("does not begin with a campus_audit record") != std::string::npos,
              "the refusal says why");
        check(!sink.is_open(), "nothing is opened for a foreign file");
        check(read_file(foreign) == "not an audit log\n", "the foreign file is unchanged");
#ifndef _WIN32
        struct stat st;
        check(stat(foreign, &st) == 0 && (st.st_mode & 07777) == 0600,
              "readable_by_all does not change the permissions of a refused file");
#endif
        std::remove(foreign);

        const char* empty = "sink_test_empty.jsonl";
        std::remove(empty);
        { std::ofstream out(empty, std::ios::binary); }
        check(sink.open(empty).ok(), "an existing empty file is accepted");
        sink.close();
        std::remove(empty);

        const char* gap_first = "sink_test_gapfirst.jsonl";
        std::remove(gap_first);
        { std::ofstream out(gap_first, std::ios::binary); out << "\n" << R1; }
        check(sink.open(gap_first).ok(), "a log that begins with the newline of an audit_gap record is accepted");
        sink.close();
        std::remove(gap_first);
    }

    {
        // swap(): a file opened by one sink (a check function) is taken over by
        // another (the update function) without being opened twice.
        const char* other = "sink_test_swap.jsonl";
        std::remove(other);
        LogSink active, staged;
        check(active.open(path).ok() && staged.open(other).ok(), "two sinks opened for swap");
        active.swap(staged);
        check(write(active, R1), "after swap the active sink writes");
        check(staged.is_open(), "after swap the other sink holds the previous file");
        staged.close();
        check(read_file(other) == R1, "the record went to the file that was swapped in");
        LogSink empty;
        empty.swap(active);
        check(!active.is_open() && empty.is_open(), "swap with a closed sink moves the file");
        std::remove(other);
    }

#ifndef _WIN32
    {
        // The log holds account names, hosts and table names: a newly created
        // file must never be accessible to "others", whatever the umask is.
        struct stat st;
        check(stat(path, &st) == 0 && (st.st_mode & 0007) == 0,
              "a newly created log file has no permission bits for others");
    }
    {
        // campus_audit_readable_by_all: LOAD_FILE() needs S_IROTH, and a umask
        // that removes every bit for others must not prevent it.
        mode_t old_mask = umask(0077);
        struct stat st;
        LogSink sink;
        sink.set_readable_by_all(true);
        check(sink.open(path).ok() && stat(path, &st) == 0 && (st.st_mode & S_IROTH),
              "readable_by_all: an existing log file becomes readable by others");
        sink.close();
        const char* fresh = "sink_test_readable.jsonl";
        std::remove(fresh);
        check(sink.open(fresh).ok() && stat(fresh, &st) == 0 && (st.st_mode & S_IROTH) &&
                  (st.st_mode & S_IWOTH) == 0,
              "readable_by_all: a new log file is readable, not writable, by others (umask 077)");
        sink.close();
        std::remove(fresh);
        umask(old_mask);
    }
#endif

    {
        LogSink sink;
        check(sink.open(path).ok(), "opened for EBADF test");
        close_fd(sink.descriptor_for_test());  // simulate the descriptor disappearing
        AuditResult r = sink.write_all("{\"lost\":true}\n", 14);
        check(r.code == AuditError::write_Failed, "write on a dead descriptor reported as write_Failed");
        check(r.message.find("errno") != std::string::npos, "write failure message carries errno");
        sink.close();
    }

#ifndef _WIN32
    {
        LogSink sink;
        if (sink.open("/dev/full").ok()) {
            AuditResult r = sink.write_all("{\"x\":1}\n", 8);
            check(r.code == AuditError::write_Failed, "/dev/full write reported as write_Failed (ENOSPC)");
        } else {
            std::cout << "SKIP: /dev/full not available\n";
        }
    }
#endif

    std::remove(path);
    std::cout << "Failures: " << failures << '\n';
    return failures == 0 ? 0 : 1;
}
