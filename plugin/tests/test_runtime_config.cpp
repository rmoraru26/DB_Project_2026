// Unit tests for src/runtime_config.h: the atomic copies of the dynamic
// settings that concurrent audit callbacks read while SET GLOBAL changes them.
//
// The checks are explicit (not assert()): an optimised build may define
// NDEBUG, which removes every assert().  The Zig build for Windows (-O2) does
// exactly that, so the earlier assert-based version of this file verified
// nothing there.
#include "../src/runtime_config.h"

#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const char* label) {
    ++checks;
    if (condition) {
        std::printf("PASS: %s\n", label);
    } else {
        ++failures;
        std::printf("FAIL: %s\n", label);
    }
}

}  // namespace

int main() {
    {
        campus_audit::RuntimeConfig defaults;
        check(!defaults.log_reads.load() && defaults.connections.load() == 1 &&
              defaults.statement_scope.load() == 0 && defaults.max_sql_length.load() == 1024,
              "defaults before init publishes the configured values: log_reads OFF, connections FAILED, scope TABLES, digest 1024");
    }

    campus_audit::RuntimeConfig config;
    const unsigned int readers = 6;
    const unsigned int writes = 100000;
    // A reader that ever sees a value no writer stored (a torn or
    // out-of-range read) counts it here.
    std::atomic<unsigned long long> impossible_values(0);
    std::atomic<unsigned long long> reads(0);
    std::vector<std::thread> threads;
    for (unsigned int i = 0; i < readers; ++i) {
        threads.emplace_back([&config, &impossible_values, &reads, writes]() {
            unsigned long long bad = 0;
            for (unsigned int n = 0; n < writes; ++n) {
                const unsigned long connections = config.connections.load(std::memory_order_relaxed);
                const unsigned int max_length = config.max_sql_length.load(std::memory_order_relaxed);
                const unsigned long scope = config.statement_scope.load(std::memory_order_relaxed);
                (void)config.log_reads.load(std::memory_order_relaxed);
                if (connections > 2 || scope > 1 || max_length > 8192) ++bad;
            }
            impossible_values.fetch_add(bad);
            reads.fetch_add(writes);
        });
    }
    std::thread writer([&config, writes]() {
        for (unsigned int n = 0; n < writes; ++n) {
            config.log_reads.store((n & 1U) != 0, std::memory_order_relaxed);
            config.connections.store(n % 3, std::memory_order_relaxed);
            config.statement_scope.store(n % 2, std::memory_order_relaxed);
            config.max_sql_length.store(n % 8193, std::memory_order_relaxed);
        }
    });
    writer.join();
    for (std::thread& thread : threads) thread.join();

    check(reads.load() == static_cast<unsigned long long>(readers) * writes,
          "six reader threads completed 100000 reads each while one thread wrote");
    check(impossible_values.load() == 0,
          "no reader saw a value outside the ranges the writer stored (connections 0-2, scope 0-1, digest 0-8192)");
    const unsigned int last = writes - 1;
    check(config.log_reads.load() == ((last & 1U) != 0) && config.connections.load() == last % 3 &&
          config.statement_scope.load() == last % 2 && config.max_sql_length.load() == last % 8193,
          "after the writer finished every setting holds the last value stored");

    std::printf("Checks: %d, Failures: %d\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
