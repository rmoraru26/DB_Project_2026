#include "log_sink.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

#include <fcntl.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

#include "audit_file_check.h"

namespace campus_audit {

namespace {

std::string describe_errno(int err) {
    char buf[128];
    const char* text = nullptr;
#ifdef _WIN32
    if (strerror_s(buf, sizeof(buf), err) == 0) text = buf;
#else
    // XSI and GNU strerror_r differ; strerror() is acceptable here because the
    // caller holds the sink mutex and only formats the message once.
    (void)buf;
    text = std::strerror(err);
#endif
    std::string s = text ? text : "unknown error";
    return s + " (errno " + std::to_string(err) + ")";
}

int sys_open(const char* path) {
#ifdef _WIN32
    return _open(path, _O_WRONLY | _O_APPEND | _O_CREAT | _O_BINARY | _O_NOINHERIT,
                 _S_IREAD | _S_IWRITE);
#else
    return ::open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0660);
#endif
}

// LOAD_FILE() returns NULL for a file without S_IROTH (Item_load_file::val_str
// in sql/item_strfunc.cc), and the server's umask removes that bit from new
// files, so it is added with fchmod(), which the umask does not affect.
// Returns 0 or an errno value.
int make_readable_by_all(int fd) {
#ifdef _WIN32
    (void)fd;
    return 0;
#else
    struct stat st;
    if (::fstat(fd, &st) != 0) return errno;
    if (st.st_mode & S_IROTH) return 0;
    if (::fchmod(fd, (st.st_mode & 07777) | S_IROTH) != 0) return errno;
    return 0;
#endif
}

long sys_write(int fd, const char* data, size_t length) {
#ifdef _WIN32
    unsigned int chunk = length > 0x7FFFFFFFu ? 0x7FFFFFFFu : static_cast<unsigned int>(length);
    return _write(fd, data, chunk);
#else
    return static_cast<long>(::write(fd, data, length));
#endif
}

void sys_close(int fd) {
#ifdef _WIN32
    _close(fd);
#else
    ::close(fd);
#endif
}

// Every campus_audit record starts with these bytes (begin_record() in
// campus_audit.cpp); an audit_gap record is preceded by a newline.
const char kRecordPrefix[] = "{\"ts\":\"";

// Refuses an existing regular file that is neither empty nor a campus_audit
// log.  SET GLOBAL campus_audit_file_path needs SYSTEM_VARIABLES_ADMIN, not
// FILE; without this check it could append to any file the server may write,
// a table file in the data directory included, and with readable_by_all also
// make that file readable by every OS user.  A FIFO or a device (/dev/full in
// the tests) is not a data file and is left to open().  The check and open()
// are two steps: a file replaced in between is not detected.
AuditResult check_existing_file(const char* path) {
    struct stat st;
    if (::stat(path, &st) != 0) return {AuditError::None, ""};    // open() creates it or says why not
    if ((st.st_mode & S_IFMT) != S_IFREG || st.st_size == 0) return {AuditError::None, ""};
    const std::string refused = std::string("Refusing to append to '") + path + "': ";
    std::FILE* f = std::fopen(path, "rb");
    if (f == nullptr) {
        return {AuditError::open_Failed,
                refused + "the file exists and cannot be read to check that it is a campus_audit log: " +
                    describe_errno(errno)};
    }
    char head[32];
    const size_t n = std::fread(head, 1, sizeof(head), f);
    std::fclose(f);
    size_t i = 0;
    while (i < n && (head[i] == '\n' || head[i] == '\r')) ++i;
    const size_t want = sizeof(kRecordPrefix) - 1;
    if (i == n || (n - i >= want && std::memcmp(head + i, kRecordPrefix, want) == 0)) {
        return {AuditError::None, ""};
    }
    return {AuditError::open_Failed,
            refused + "the file exists and does not begin with a campus_audit record (accepted are a new "
                      "file, an empty one and an earlier campus_audit log)"};
}

}  // namespace

AuditResult LogSink::open(const char* path) {
    if (path == nullptr) {
        return {AuditError::invalid_Configuration, "The audit log path is NULL"};
    }
    AuditResult valid = validate_log_path(path);
    if (!valid.ok()) return valid;
    AuditResult existing = check_existing_file(path);
    if (!existing.ok()) return existing;

    int fd = sys_open(path);
    if (fd < 0) {
        int err = errno;
        return {AuditError::open_Failed,
                std::string("Cannot open audit log '") + path + "': " + describe_errno(err)};
    }
    if (readable_by_all_) {
        int err = make_readable_by_all(fd);
        if (err != 0) {
            sys_close(fd);
            return {AuditError::open_Failed,
                    std::string("Cannot make audit log '") + path + "' readable by all: " +
                        describe_errno(err)};
        }
    }
    close();
    fd_ = fd;
    return {AuditError::None, ""};
}

AuditResult LogSink::write_all(const char* data, size_t length) {
    if (fd_ < 0) {
        return {AuditError::write_Failed, "The audit log is not open"};
    }
    size_t done = 0;
    while (done < length) {
        long n = sys_write(fd_, data + done, length - done);
        if (n < 0) {
            int err = errno;
            if (err == EINTR) continue;
            return {AuditError::write_Failed,
                    "Write to audit log failed: " + describe_errno(err)};
        }
        if (n == 0) {
            return {AuditError::write_Failed, "Write to audit log returned 0 bytes"};
        }
        done += static_cast<size_t>(n);
    }
    return {AuditError::None, ""};
}

void LogSink::close() {
    if (fd_ >= 0) {
        sys_close(fd_);
        fd_ = -1;
    }
}

}  // namespace campus_audit
