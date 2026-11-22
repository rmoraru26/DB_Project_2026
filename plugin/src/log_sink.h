// Append-only JSON Lines file used by campus_audit.
//
// Records are written with one write() call per line on a descriptor opened
// with O_APPEND, under the plugin's sink mutex, so concurrent connections
// never interleave partial lines.  The class itself is not thread-safe.

#ifndef CAMPUS_AUDIT_LOG_SINK_H
#define CAMPUS_AUDIT_LOG_SINK_H

#include <cstddef>

#include "audit_error.h"

namespace campus_audit {

class LogSink {
public:
    LogSink() = default;
    ~LogSink() { close(); }

    // Validates the path (see validate_log_path) and opens it for appending,
    // creating a new regular file with owner/group read-write permissions.
    // Which files may be opened (no links, no foreign files, no devices but
    // /dev/null and /dev/full, no network paths on Windows) is decided on the
    // opened descriptor or handle: see "what may be opened" in log_sink.cpp.
    // After set_readable_by_all(true) a file this call creates is made
    // readable by others (LOAD_FILE() reads no other file); an existing file's
    // permissions are never changed.  No effect on Windows.
    // On failure the previously open file (if any) stays open.
    AuditResult open(const char* path);
    void set_readable_by_all(bool on) { readable_by_all_ = on; }

    // Writes the whole buffer or reports write_Failed (short write, ENOSPC,
    // EIO, EBADF ...).  Never retries forever: EINTR is retried, nothing else.
    AuditResult write_all(const char* data, size_t length);

    void close();
    bool is_open() const { return fd_ >= 0; }

    // Exchanges the open files of two sinks.  Lets a file be opened in one
    // place (a check function) and taken over in another (the update
    // function) without opening it twice.
    void swap(LogSink& other) {
        const int fd = fd_;
        fd_ = other.fd_;
        other.fd_ = fd;
    }

    // For tests only: the raw descriptor, so a test can provoke EBADF.
    int descriptor_for_test() const { return fd_; }

    // For tests only (Linux): the owner an existing log must have, instead of
    // the process's effective user, so the owner check can be tested without
    // root (giving a file away needs root).  -1: the effective user.
    void expect_owner_for_test(long uid) { expected_owner_ = uid; }

private:
    int fd_ = -1;
    bool readable_by_all_ = false;
    long expected_owner_ = -1;

    LogSink(const LogSink&) = delete;
    LogSink& operator=(const LogSink&) = delete;
};

}  // namespace campus_audit

#endif
