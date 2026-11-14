#include "../src/runtime_config.h"

#include <cassert>
#include <thread>
#include <vector>

int main() {
    campus_audit::RuntimeConfig config;
    const unsigned int readers = 6;
    const unsigned int writes = 100000;
    std::vector<std::thread> threads;
    for (unsigned int i = 0; i < readers; ++i) {
        threads.emplace_back([&config]() {
            for (unsigned int n = 0; n < writes; ++n) {
                const unsigned long connections = config.connections.load(std::memory_order_relaxed);
                const unsigned int max_length = config.max_sql_length.load(std::memory_order_relaxed);
                (void)config.log_reads.load(std::memory_order_relaxed);
                assert(connections <= 2);
                assert(max_length <= 8192);
            }
        });
    }
    std::thread writer([&config]() {
        for (unsigned int n = 0; n < writes; ++n) {
            config.log_reads.store((n & 1U) != 0, std::memory_order_relaxed);
            config.connections.store(n % 3, std::memory_order_relaxed);
            config.max_sql_length.store(n % 8193, std::memory_order_relaxed);
        }
    });
    writer.join();
    for (std::thread& thread : threads) thread.join();
    return 0;
}
