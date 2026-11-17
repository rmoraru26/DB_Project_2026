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
    // creating it with owner/group read-write permissions if necessary.
    // After set_readable_by_all(true) the file, also an existing one, is made
    // readable by others: the server's LOAD_FILE() reads no other file.  No
    // effect on Windows, where the C runtime's stat() already reports the
    // owner's read permission for others.
    // On failure the previously open file (if any) stays open.
    AuditResult open(const char* path);
    void set_readable_by_all(bool on) { readable_by_all_ = on; }

    // Writes the whole buffer or reports write_Failed (short write, ENOSPC,
    // EIO, EBADF ...).  Never retries forever: EINTR is retried, nothing else.
    AuditResult write_all(const char* data, size_t length);

    void close();
    bool is_open() const { return fd_ >= 0; }

    // For tests only: the raw descriptor, so a test can provoke EBADF.
    int descriptor_for_test() const { return fd_; }

private:
    int fd_ = -1;
    bool readable_by_all_ = false;

    LogSink(const LogSink&) = delete;
    LogSink& operator=(const LogSink&) = delete;
};

}  // namespace campus_audit

#endif
