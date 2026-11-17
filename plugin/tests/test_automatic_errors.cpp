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

    // Tests 4-12: campus_audit::validate_log_path() is a lexical check only.
    using campus_audit::validate_log_path;

    if (!check("validate: NULL path",
               validate_log_path(nullptr),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    if (!check("validate: empty path",
               validate_log_path(""),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    if (!check("validate: trailing forward slash",
               validate_log_path("some_dir/"),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    if (!check("validate: trailing backslash",
               validate_log_path("some_dir\\"),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    if (!check("validate: newline in path",
               validate_log_path("bad\npath.jsonl"),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    if (!check("validate: DEL in path",
               validate_log_path("bad\x7Fpath.jsonl"),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    // The limit is 512 bytes: 513 is rejected, exactly 512 is accepted.
    if (!check("validate: 513-byte path",
               validate_log_path(std::string(513, 'a').c_str()),
               AuditError::invalid_Configuration)) {
        ++failures;
    }

    if (!check("validate: 512-byte path",
               validate_log_path(std::string(512, 'a').c_str()),
               AuditError::None)) {
        ++failures;
    }

    // A lexically valid path passes even though its directory does not exist,
    // and validating it must not create the file.
    const char* lexical = "audit_test_missing_directory/campus_audit.jsonl";
    if (!check("validate: lexically valid path",
               validate_log_path(lexical),
               AuditError::None)) {
        ++failures;
    }

    const char* untouched = "audit_validate_test.tmp";
    std::remove(untouched);
    AuditResult validated = validate_log_path(untouched);
    std::ifstream created(untouched);
    if (!validated.ok() || created.good()) {
        std::cout << "FAIL: validate: no file is created\n";
        ++failures;
    } else {
        std::cout << "PASS: validate: no file is created\n";
    }

    std::cout << "Failures: " << failures << '\n';
    return failures == 0 ? 0 : 1;
}