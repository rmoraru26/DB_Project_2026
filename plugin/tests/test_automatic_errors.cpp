#include "../audit_file_check.h"
#include <cstdio>
#include <fstream>
#include <iostream>



bool check(const std::string& name,
           const AuditResult& result,
           AuditError expected) {
    if (result.code != expected) {
        std::cout << "FAIL: " << name << '\n';
        return false;
    }

    std::cout << "PASS: " << name << '\n';
    return true;
}

int main() {
    int failures = 0;

    // Test 1: empty path.
    if (!check("Empty path",
               try_open_log(""),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    // Test 2: a directory that must not exist.
    if (!check("Missing directory",
               try_open_log(
                   "audit_test_missing_directory/campus_audit.jsonl"
               ),
               AuditError::open_Failed)) {
        ++failures;
    }

    // Test 3: create a temporary file in the current directory.
    const std::string path = "audit_open_test.tmp";

    // Avoid changing a file that already exists.
    std::ifstream existing(path);
    if (existing.good()) {
        std::cout << "FAIL: temporary file already exists\n";
        ++failures;
    } else {
        existing.close();

        AuditResult result = try_open_log(path);

        if (!check("Valid path", result, AuditError::None)) {
            ++failures;
        }

        if (result.ok() && std::remove(path.c_str()) != 0) {
            std::cout << "FAIL: cannot remove temporary file\n";
            ++failures;
        }
    }

    std::cout << "Failures: " << failures << '\n';
    return failures == 0 ? 0 : 1;
}