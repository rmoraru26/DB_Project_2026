
#ifndef AUDIT_ERROR_H
#define AUDIT_ERROR_H
#include<string>
enum class AuditError {
    None,
    invalid_Configuration,
    open_Failed,
    write_Failed,
    format_Failed,
    unexpected_Failure
};

struct AuditResult {
    AuditError code;
    std::string message;
    bool ok() const {
        return code == AuditError::None;
    }
};

#endif