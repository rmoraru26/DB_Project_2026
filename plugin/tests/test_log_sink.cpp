// Unit tests for LogSink: path validation, open failures, appending, which
// existing files may be opened (and which must not be), and a real write
// failure provoked by closing the descriptor behind the sink's back (EBADF).
// On Linux, /dev/full additionally gives ENOSPC.
//
// Run from a writable working directory; the test creates and removes only
// sink_test_* files there.  It never touches any other file.

#include "../src/log_sink.h"

#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <io.h>
#define close_fd _close
#else
#include <fcntl.h>
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

static void skip(const std::string& name) { std::cout << "SKIP: " << name << '\n'; }

// Records as the plugin writes them: every one begins with {"ts":"
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

static void make_file(const char* path, const std::string& content) {
    std::remove(path);
    std::ofstream out(path, std::ios::binary);
    out << content;
}

// A refused open: the right code, nothing opened, the reason in the message.
static void expect_refused(const char* path, const std::string& reason, const std::string& name) {
    LogSink sink;
    sink.set_readable_by_all(true);
    AuditResult r = sink.open(path);
    check(r.code == AuditError::open_Failed && !sink.is_open() &&
              r.message.find(reason) != std::string::npos,
          name + " (" + (r.ok() ? std::string("accepted") : r.message) + ")");
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
        check(r.message.find("Cannot open audit log") != std::string::npos, "open failure message names the log and the OS error");
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

    // ------------------------------------------------------------ what may not be opened
    {
        const char* foreign = "sink_test_foreign.jsonl";
        make_file(foreign, "not an audit log\n");
        expect_refused(foreign, "does not begin with a campus_audit record",
                       "an existing .jsonl file that is not a campus_audit log is refused");
        check(read_file(foreign) == "not an audit log\n", "the refused file is unchanged");
        std::remove(foreign);

        const char* other_name = "sink_test_table.dat";
        make_file(other_name, "");
        expect_refused(other_name, "must end in .jsonl",
                       "an existing empty file whose name does not end in .jsonl is refused");
        check(read_file(other_name).empty(), "it stays empty");
        std::remove(other_name);

        const char* not_there = "sink_test_new.log";
        std::remove(not_there);
        expect_refused(not_there, "must end in .jsonl", "a new file whose name does not end in .jsonl is refused");
        std::ifstream probe(not_there);
        check(!probe.good(), "and is not created");

        const char* upper = "sink_test_upper.JSONL";
        std::remove(upper);
        LogSink sink;
        check(sink.open(upper).ok(), "the .jsonl suffix is matched without regard to case");
        sink.close();
        std::remove(upper);

        const char* empty = "sink_test_empty.jsonl";
        make_file(empty, "");
        check(sink.open(empty).ok(), "an existing empty .jsonl file is accepted");
        sink.close();
        std::remove(empty);

        const char* gap_first = "sink_test_gapfirst.jsonl";
        make_file(gap_first, std::string("\n") + R1);
        check(sink.open(gap_first).ok(), "a log that begins with the newline of an audit_gap record is accepted");
        sink.close();
        std::remove(gap_first);
    }

    {
        // A hard link: the existing name is a campus_audit log by content, but the
        // file has a second name elsewhere, so appending would change that file too.
        const char* target = "sink_test_linked_target.jsonl";
        const char* alias = "sink_test_hardlink.jsonl";
        make_file(target, R1);
        std::remove(alias);
#ifdef _WIN32
        const bool linked = CreateHardLinkA(alias, target, nullptr) != 0;
#else
        const bool linked = ::link(target, alias) == 0;
#endif
        if (linked) {
            expect_refused(alias, "hard links", "a hard link is refused, even with a log-like content");
            expect_refused(target, "hard links", "and so is the file under its other name");
            check(read_file(target) == R1, "the hard-linked file is unchanged");
        } else {
            skip("hard link could not be created here");
        }
        std::remove(alias);
        std::remove(target);
    }

    {
        // A symbolic link to a log-like file: refused, the target untouched.
        const char* target = "sink_test_symlink_target.jsonl";
        const char* alias = "sink_test_symlink.jsonl";
        make_file(target, R1);
        std::remove(alias);
#ifdef _WIN32
        bool linked = CreateSymbolicLinkA(alias, target, 0x2 /* ALLOW_UNPRIVILEGED_CREATE */) != 0;
        if (!linked) linked = CreateSymbolicLinkA(alias, target, 0) != 0;
#else
        const bool linked = ::symlink(target, alias) == 0;
#endif
        if (linked) {
            expect_refused(alias, "", "a symbolic link is refused");
            LogSink sink;
            AuditResult r = sink.open(alias);
            check(r.message.find("it is a symbolic link") != std::string::npos, "the refusal names the symbolic link (the open itself refuses it)");
            check(read_file(target) == R1, "the link's target is unchanged");
        } else {
            skip("symbolic link could not be created here (Windows needs developer mode or a privilege)");
        }
        std::remove(alias);
        std::remove(target);
    }

#ifndef _WIN32
    {
        // A file of another OS user, writable for the server: refused, unchanged.
        // Needs root to give the file away.
        const char* foreign_owner = "sink_test_owner.jsonl";
        make_file(foreign_owner, R1);
        if (::geteuid() == 0 && ::chown(foreign_owner, 4242, 4242) == 0) {
            ::chmod(foreign_owner, 0666);
            expect_refused(foreign_owner, "another OS user", "a file of another OS user is refused");
            check(read_file(foreign_owner) == R1, "it is unchanged");
        } else {
            skip("file of another OS user (needs root)");
        }
        std::remove(foreign_owner);
    }
    {
        // A FIFO: refused at once without a reader (no hang), accepted with one,
        // and the descriptor blocks again (O_NONBLOCK was only for the open).
        const char* fifo = "sink_test_fifo";
        std::remove(fifo);
        if (::mkfifo(fifo, 0600) == 0) {
            expect_refused(fifo, "FIFO without a reader", "a FIFO without a reader is refused at once");
            const int reader = ::open(fifo, O_RDONLY | O_NONBLOCK);
            LogSink sink;
            check(reader >= 0 && sink.open(fifo).ok(), "a FIFO with a reader is accepted (no .jsonl needed)");
            check(sink.is_open() && (::fcntl(sink.descriptor_for_test(), F_GETFL) & O_NONBLOCK) == 0,
                  "its descriptor is blocking again");
            sink.close();
            if (reader >= 0) ::close(reader);
        } else {
            skip("mkfifo not possible here");
        }
        std::remove(fifo);
    }
    {
        // The log holds account names, hosts and table names: a newly created
        // file must never be accessible to "others", whatever the umask is.
        struct stat st;
        check(stat(path, &st) == 0 && (st.st_mode & 0007) == 0,
              "a newly created log file has no permission bits for others");
    }
    {
        // campus_audit_readable_by_all: LOAD_FILE() needs S_IROTH, and a umask
        // that removes every bit for others must not prevent it.  Only a file
        // the plugin has just created is changed, never an existing one.
        mode_t old_mask = umask(0077);
        struct stat st;
        LogSink sink;
        sink.set_readable_by_all(true);
        ::chmod(path, 0640);
        check(sink.open(path).ok() && stat(path, &st) == 0 && (st.st_mode & 07777) == 0640,
              "readable_by_all: the permissions of an existing log file are not widened");
        sink.close();
        const char* fresh = "sink_test_readable.jsonl";
        std::remove(fresh);
        check(sink.open(fresh).ok() && stat(fresh, &st) == 0 && (st.st_mode & S_IROTH) &&
                  (st.st_mode & S_IWOTH) == 0,
              "readable_by_all: a new log file is readable, not writable, by others (umask 077)");
        sink.close();
        std::remove(fresh);
        const char* refused_file = "sink_test_refused_mode.jsonl";
        make_file(refused_file, "not an audit log\n");
        ::chmod(refused_file, 0600);
        check(!sink.open(refused_file).ok() && stat(refused_file, &st) == 0 && (st.st_mode & 07777) == 0600,
              "readable_by_all: a refused file keeps its permissions");
        std::remove(refused_file);
        umask(old_mask);
    }
#endif

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
