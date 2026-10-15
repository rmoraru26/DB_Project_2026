#include "audit_file_check.h"
#include <fstream>

AuditResult try_open_log(const std::string& path) {
    if (path.empty()) {
        return {
            AuditError::invalid_Configuration,
            "The audit log path is empty"
        };
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