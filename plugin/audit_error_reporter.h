#ifndef AUDIT_ERROR_REPORTER_H
#define AUDIT_ERROR_REPORTER_H

#include "audit_error.h"

// The function that receives an error for reporting.
using AuditErrorSink = void (*)(const AuditResult&);

// Reports only the results that are errors.
void report_audit_error(
    const AuditResult& result,
    AuditErrorSink sink
);

#endif