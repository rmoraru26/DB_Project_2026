#ifndef AUDIT_FILE_CHECK_H
#define AUDIT_FILE_CHECK_H

#include <string>

#include "audit_error.h"

// Checks that the path can be opened for appending by actually opening it
// (std::ofstream), so the file is created when it does not exist.
AuditResult try_open_log(const std::string& path);

namespace campus_audit {

// Lexical check of an audit log path.  Never touches the filesystem: it does
// not create, open, truncate or write anything.  Returns
// AuditError::invalid_Configuration for a NULL or empty path, a path longer
// than 512 bytes, a path ending in '/' or '\' (a directory), or a path
// containing an ASCII control character (0x00-0x1F, 0x7F).  Whether the
// directory exists and the file may be written is left to the caller's open.
AuditResult validate_log_path(const char* path);

}  // namespace campus_audit

#endif
