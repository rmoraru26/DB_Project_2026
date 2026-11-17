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

    // campus_audit::validate_log_path() is a lexical check only.
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