#include "../src/gap_accounting.h"

#include <cassert>

int main() {
    campus_audit::GapAccounting gap;
    assert(gap.dropped() == 0);
    gap.event_lost_to_io();
    gap.event_lost_to_io();
    assert(gap.dropped() == 2);
    assert(!gap.marker_result(false));
    assert(gap.dropped() == 2);  // a failed marker does not erase the outage
    gap.event_lost_to_io();
    assert(gap.dropped() == 3);
    assert(gap.marker_result(true));
    assert(gap.dropped() == 0);
    return 0;
}
