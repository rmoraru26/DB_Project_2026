#include "audit_error_reporter.h"

void report_audit_error(
    const AuditResult& result,
    AuditErrorSink sink
) {
    if (result.ok() || sink == nullptr) {
        return;
    }

    sink(result);
}