#ifndef AUDIT_ERROR_REPORTER_H
#define AUDIT_ERROR_REPORTER_H

#include "audit_error.h"

// Funcția care primește eroarea pentru raportare.
using AuditErrorSink = void (*)(const AuditResult&);

// Raportează doar rezultatele care reprezintă erori.
void report_audit_error(
    const AuditResult& result,
    AuditErrorSink sink
);

#endif