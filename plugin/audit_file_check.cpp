#include "audit_file_check.h"
#include <fstream>

namespace {

// The lexical rules, on a std::string so that a byte sequence with an
// embedded NUL (possible through try_open_log) is checked in full.
AuditResult validate_path_text(const std::string& path) {
    if (path.empty()) {
        return {
            AuditError::invalid_Configuration,
            "The audit log path is empty"
        };
    }

    if (path.size() > 512) {
        return {
            AuditError::invalid_Configuration,
            "The audit log path is longer than 512 bytes"
        };
    }

    for (char c : path) {
        if (static_cast<unsigned char>(c) < 0x20 || c == 0x7F) {
            return {
                AuditError::invalid_Configuration,
                "The audit log path contains a control character"
            };
        }
    }

    const char last = path[path.size() - 1];
    if (last == '/' || last == '\\') {
        return {
            AuditError::invalid_Configuration,
            "The audit log path names a directory, not a file: " + path
        };
    }

    return {AuditError::None, ""};
}

}  // namespace

namespace campus_audit {

AuditResult validate_log_path(const char* path) {
    if (path == nullptr) {
        return {
            AuditError::invalid_Configuration,
            "The audit log path is NULL"
        };
    }

    return validate_path_text(path);
}

}  // namespace campus_audit

AuditResult try_open_log(const std::string& path) {
    AuditResult valid = validate_path_text(path);
    if (!valid.ok()) {
        return valid;
    }

    std::ofstream file(path, std::ios::app);

    if (!file.is_open()) {
        return {
            AuditError::open_Failed,
            "Cannot open audit log: " + path
        };
    }

    return {AuditError::None, ""};
}
