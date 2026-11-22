// I/O-gap event count. Callers serialize this object with the sink mutex.
#ifndef CAMPUS_AUDIT_GAP_ACCOUNTING_H
#define CAMPUS_AUDIT_GAP_ACCOUNTING_H

namespace campus_audit {

class GapAccounting {
public:
    GapAccounting() : dropped_(0) {}

    unsigned long long dropped() const { return dropped_; }
    void event_lost_to_io() { ++dropped_; }
    // Records lost for other reasons (counted elsewhere without the sink
    // mutex), merged in before the next marker so that it announces them too.
    void events_lost(unsigned long long n) { dropped_ += n; }

    // A failed marker must leave the count intact so a later recovery retries it.
    bool marker_result(bool written) {
        if (written) dropped_ = 0;
        return written;
    }

private:
    unsigned long long dropped_;
};

}  // namespace campus_audit

#endif
