// Unit tests for src/gap_accounting.h: how many events an I/O outage lost,
// and when that count may be reset.
//
// The checks are explicit (not assert()): an optimised build may define
// NDEBUG, which removes every assert() together with the calls inside it.
// The Zig build for Windows (-O2) does exactly that, so the earlier
// assert-based version of this file verified nothing there.
#include "../src/gap_accounting.h"

#include <cstdio>

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
    campus_audit::GapAccounting gap;
    check(gap.dropped() == 0, "a new accounting object has lost nothing");
    gap.event_lost_to_io();
    gap.event_lost_to_io();
    check(gap.dropped() == 2, "every lost event is counted");

    const bool failed_marker = gap.marker_result(false);
    check(!failed_marker, "a marker that could not be written is reported as not written");
    check(gap.dropped() == 2, "a failed marker does not erase the outage: the count is kept for the next attempt");

    gap.event_lost_to_io();
    check(gap.dropped() == 3, "events lost after the failed marker are added to the same outage");

    const bool written_marker = gap.marker_result(true);
    check(written_marker, "a written marker is reported as written");
    check(gap.dropped() == 0, "only a written marker resets the count");

    gap.event_lost_to_io();
    check(gap.dropped() == 1, "a new outage starts counting from zero");

    std::printf("Checks: %d, Failures: %d\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
