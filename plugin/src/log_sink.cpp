#include "log_sink.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

#include <fcntl.h>
#include <sys/stat.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
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

// ---------------------------------------------------------------- what may be opened
//
// SET GLOBAL campus_audit_file_path needs SYSTEM_VARIABLES_ADMIN, not FILE.
// The plugin must therefore never become a way to write into, or (with
// campus_audit_readable_by_all) expose, a file that is not its own log: a
// table file in the data directory, a log of another program, a file of
// another OS user.  The rules below are applied to the file that was actually
// opened (its descriptor or handle), not to the path name, so a file swapped
// in between a check and the open cannot slip through:
//
//   * a symbolic link (Linux, last path component) or a reparse point
//     (Windows: symbolic link, junction) is refused;
//   * a FIFO or a character device (/dev/full, /dev/null) is accepted as it
//     is; their permissions are never changed;
//   * any other non-regular file is refused;
//   * a regular file's name must end in ".jsonl" (no MariaDB data, log or
//     table file does);
//   * a regular file this call creates is the plugin's own;
//   * an existing regular file must have exactly one link (no hard link to
//     another file), belong to the server's own OS user (Linux), and be empty
//     or begin with a campus_audit record.  The content alone proves nothing
//     (anybody who can write a file can write those bytes); it is the last of
//     these conditions, against appending to a .jsonl file of the server's own
//     that is not an audit log;
//   * permissions are widened (readable_by_all) only on a file this call has
//     just created, never on an existing one.
//
// Not covered: a symbolic link or junction in a directory component of the
// path (the directory is the administrator's choice, like the server's own
// log directories); the owner on Windows.

// Every campus_audit record starts with these bytes (begin_record() in
// campus_audit.cpp); an audit_gap record is preceded by a newline.
const char kRecordPrefix[] = "{\"ts\":\"";

bool has_jsonl_suffix(const char* path) {
    const size_t n = std::strlen(path);
    const char suffix[] = ".jsonl";
    const size_t k = sizeof(suffix) - 1;
    if (n < k) return false;
    for (size_t i = 0; i < k; ++i) {
        char c = path[n - k + i];
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        if (c != suffix[i]) return false;
    }
    return true;
}

// The first bytes of an existing file decide only whether it looks like a
// campus_audit log: empty, or a record (possibly after the newline of an
// audit_gap record).
bool looks_like_audit_log(const char* head, size_t n) {
    size_t i = 0;
    while (i < n && (head[i] == '\n' || head[i] == '\r')) ++i;
    const size_t want = sizeof(kRecordPrefix) - 1;
    return i == n || (n - i >= want && std::memcmp(head + i, kRecordPrefix, want) == 0);
}

AuditResult refused(const char* path, const std::string& why) {
    return {AuditError::open_Failed, std::string("Refusing audit log '") + path + "': " + why};
}

const char kNotALog[] =
    "the file exists and does not begin with a campus_audit record (accepted are a new file, an empty "
    "one and an earlier campus_audit log)";
const char kSuffix[] = "a regular audit log file must end in .jsonl";

#ifdef _WIN32

std::string describe_win32(DWORD err) {
    return "Windows error " + std::to_string(static_cast<unsigned long>(err));
}

// Opens `path` for appending and checks the opened handle.  *created: this
// call created the file.
AuditResult open_checked(const char* path, long expected_owner, int* out, bool* created) {
    (void)expected_owner;    // the owner is not checked on Windows
    const bool jsonl = has_jsonl_suffix(path);
    // FILE_FLAG_OPEN_REPARSE_POINT: a symbolic link or junction is opened
    // itself instead of its target, so it can be recognised and refused.
    HANDLE h = CreateFileA(path, FILE_APPEND_DATA | FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           jsonl ? OPEN_ALWAYS : OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        const DWORD err = GetLastError();
        if (!jsonl && (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND)) {
            return refused(path, kSuffix);
        }
        return {AuditError::open_Failed,
                std::string("Cannot open audit log '") + path + "': " + describe_win32(err)};
    }
    *created = jsonl && GetLastError() != ERROR_ALREADY_EXISTS;
    const DWORD type = GetFileType(h);
    if (type == FILE_TYPE_CHAR || type == FILE_TYPE_PIPE) {
        // NUL, a console or a named pipe: accepted as it is.
    } else {
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(h, &info)) {
            const DWORD err = GetLastError();
            CloseHandle(h);
            return {AuditError::open_Failed,
                    std::string("Cannot inspect audit log '") + path + "': " + describe_win32(err)};
        }
        AuditResult bad = {AuditError::None, ""};
        if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
            bad = refused(path, "it is a reparse point (symbolic link or junction)");
        } else if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            bad = refused(path, "it is a directory");
        } else if (!jsonl) {
            bad = refused(path, kSuffix);
        } else if (!*created && info.nNumberOfLinks != 1) {
            bad = refused(path, "it has " + std::to_string(info.nNumberOfLinks) +
                                    " hard links; an audit log has exactly one");
        } else if (!*created) {
            char head[32];
            DWORD n = 0;
            if (!ReadFile(h, head, sizeof(head), &n, nullptr)) {
                bad = refused(path, "it cannot be read to check that it is a campus_audit log: " +
                                        describe_win32(GetLastError()));
            } else if (!looks_like_audit_log(head, n)) {
                bad = refused(path, kNotALog);
            }
        }
        if (!bad.ok()) {
            CloseHandle(h);
            return bad;
        }
    }
    const int fd = _open_osfhandle(reinterpret_cast<intptr_t>(h), _O_APPEND);
    if (fd < 0) {
        CloseHandle(h);
        return {AuditError::open_Failed, std::string("Cannot open audit log '") + path + "': no descriptor"};
    }
    _setmode(fd, _O_BINARY);    // no "\n" -> "\r\n" translation
    *out = fd;
    return {AuditError::None, ""};
}

#else  // POSIX

// Opens `path` for appending and checks the opened descriptor.  *created:
// this call created the file.
AuditResult open_checked(const char* path, long expected_owner, int* out, bool* created) {
    const bool jsonl = has_jsonl_suffix(path);
    int fd = -1;
    *created = false;
    if (jsonl) {
        // O_EXCL: created only if it did not exist; a symbolic link counts
        // as existing and is not followed.
        fd = ::open(path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0660);
        if (fd >= 0) {
            *created = true;
        } else if (errno != EEXIST) {
            const int err = errno;
            return {AuditError::open_Failed,
                    std::string("Cannot open audit log '") + path + "': " + describe_errno(err)};
        }
    }
    if (fd < 0) {
        // O_NONBLOCK: a FIFO without a reader fails at once (ENXIO) instead
        // of blocking the caller; cleared again below.
        fd = ::open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) {
            const int err = errno;
            if (err == ELOOP) return refused(path, "it is a symbolic link");
            if (err == ENXIO) return refused(path, "it is a FIFO without a reader");
            if (err == ENOENT && !jsonl) return refused(path, kSuffix);
            return {AuditError::open_Failed,
                    std::string("Cannot open audit log '") + path + "': " + describe_errno(err)};
        }
    }
    struct stat st;
    if (::fstat(fd, &st) != 0) {
        const int err = errno;
        ::close(fd);
        return {AuditError::open_Failed,
                std::string("Cannot inspect audit log '") + path + "': " + describe_errno(err)};
    }
    AuditResult bad = {AuditError::None, ""};
    if (S_ISFIFO(st.st_mode) || S_ISCHR(st.st_mode)) {
        // accepted as it is
    } else if (!S_ISREG(st.st_mode)) {
        bad = refused(path, "it is not a regular file, a FIFO or a character device");
    } else if (!jsonl) {
        bad = refused(path, kSuffix);
    } else if (!*created) {
        if (st.st_nlink != 1) {
            bad = refused(path, "it has " + std::to_string(static_cast<unsigned long>(st.st_nlink)) +
                                    " hard links; an audit log has exactly one");
        } else if (static_cast<long>(st.st_uid) !=
                   (expected_owner >= 0 ? expected_owner : static_cast<long>(::geteuid()))) {
            bad = refused(path, "it belongs to another OS user (uid " +
                                    std::to_string(static_cast<unsigned long>(st.st_uid)) + ")");
        } else if (st.st_size > 0) {
            // Read through a second descriptor and make sure it is the same
            // file as the one opened for writing (device and inode).
            const int rfd = ::open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            struct stat rst;
            char head[32];
            ssize_t n = -1;
            if (rfd >= 0 && ::fstat(rfd, &rst) == 0 && rst.st_dev == st.st_dev && rst.st_ino == st.st_ino) {
                n = ::pread(rfd, head, sizeof(head), 0);
            }
            const int err = errno;
            const bool same = rfd >= 0 && n >= 0;
            if (rfd >= 0) ::close(rfd);
            if (!same) {
                bad = refused(path, "it cannot be read back as the same file to check that it is a "
                                    "campus_audit log" + (rfd < 0 ? ": " + describe_errno(err) : std::string()));
            } else if (!looks_like_audit_log(head, static_cast<size_t>(n))) {
                bad = refused(path, kNotALog);
            }
        }
    }
    if (bad.ok()) {
        const int flags = ::fcntl(fd, F_GETFL);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) != 0) {
            bad = {AuditError::open_Failed,
                   std::string("Cannot open audit log '") + path + "': " + describe_errno(errno)};
        }
    }
    if (!bad.ok()) {
        ::close(fd);
        return bad;
    }
    *out = fd;
    return {AuditError::None, ""};
}

#endif

// LOAD_FILE() returns NULL for a file without S_IROTH (Item_load_file::val_str
// in sql/item_strfunc.cc), and the server's umask removes that bit from new
// files, so it is added with fchmod(), which the umask does not affect.
// Called only for a regular file the plugin has just created.  Returns 0 or
// an errno value.
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

}  // namespace

AuditResult LogSink::open(const char* path) {
    if (path == nullptr) {
        return {AuditError::invalid_Configuration, "The audit log path is NULL"};
    }
    AuditResult valid = validate_log_path(path);
    if (!valid.ok()) return valid;

    int fd = -1;
    bool created = false;
    AuditResult opened = open_checked(path, expected_owner_, &fd, &created);
    if (!opened.ok()) return opened;
    if (readable_by_all_ && created) {
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
