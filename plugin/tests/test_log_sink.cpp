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
        check(sink.write_all("{\"a\":1}\n", 8).ok(), "first record written");
        AuditResult bad = sink.open("sink_test_missing_dir/y.jsonl");
        check(!bad.ok() && sink.is_open(), "failed re-open keeps the previous file open");
        check(sink.write_all("{\"a\":2}\n", 8).ok(), "previous file still writable");
    }
    {
        LogSink sink;
        check(sink.open(path).ok() && sink.write_all("{\"a\":3}\n", 8).ok(),
              "re-opened file is appended to");
    }
    check(read_file(path) == "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n", "file holds all records in order");

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
