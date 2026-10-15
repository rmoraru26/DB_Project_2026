#ifndef AUDIT_FILE_CHECK_H
#define AUDIT_FILE_CHECK_H

#include "audit_error.h"

AuditResult try_open_log(const std::string& path);

#endif