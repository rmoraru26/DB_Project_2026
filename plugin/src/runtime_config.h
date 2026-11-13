// Atomic copies of scalar settings read by concurrent audit callbacks.
#ifndef CAMPUS_AUDIT_RUNTIME_CONFIG_H
#define CAMPUS_AUDIT_RUNTIME_CONFIG_H

#include <atomic>

namespace campus_audit {

struct RuntimeConfig {
    RuntimeConfig() : log_reads(false), connections(1), max_sql_length(1024) {}

    std::atomic<bool> log_reads;
    std::atomic<unsigned long> connections;
    std::atomic<unsigned int> max_sql_length;
};

}  // namespace campus_audit

#endif
