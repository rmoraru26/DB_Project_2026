#include "../audit_error_reporter.h"
#include <iostream>

int report_count = 0;
std::string last_message;

void test_sink(const AuditResult& result) {
    ++report_count;
    last_message = result.message;
    std::cout << "Reported: " << result.message << '\n';
}

int main() {
    AuditResult success = {AuditError::None, ""};

    
    AuditResult failure = {
    AuditError::open_Failed,
    "Cannot open audit log"
};
   
   

    report_audit_error(success, test_sink);

    if (report_count != 0) {
        std::cout << "FAIL: success must not be reported\n";
        return 1;
    }

    report_audit_error(failure, test_sink);

    if (report_count != 1 ||
        last_message != failure.message) {
        std::cout << "FAIL: error must be reported once\n";
        return 1;
    }

    report_audit_error(failure, nullptr);

    if (report_count != 1) {
        std::cout << "FAIL: null sink must be ignored\n";
        return 1;
    }

    std::cout << "PASS: all reporter checks\n";
    return 0;
}