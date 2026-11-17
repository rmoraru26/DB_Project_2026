#include "log_sink.h"

#include <cerrno>
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

}  // namespace

AuditResult LogSink::open(const char* path) {
    if (path == nullptr) {
        return {AuditError::invalid_Configuration, "The audit log path is NULL"};
    }
    AuditResult valid = validate_log_path(path);
    if (!valid.ok()) return valid;

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
