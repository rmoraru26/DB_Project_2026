
#include "../audit_error.h"
#include <fstream>
#include <iostream>

AuditResult try_open_log(const std::string& path) {
    if (path.empty()) {
        return {
            AuditError::invalid_Configuration,
            "The audit log path is empty"
        };
    }
    std::ofstream file(path, std::ios::app);

    if (!file.is_open()) {
        return {
            AuditError::open_Failed,
            "Cannot open audit log: " + path
        };
    }

    return {AuditError::None, ""};
}

int main() {
    std::string path;

    std::cout << "Enter audit log path: ";
    std::getline(std::cin, path);

    AuditResult result = try_open_log(path);

    if (result.ok()) {
        std::cout << "File opened successfully\n";
    } else {
        std::cout << "Operation failed\n";
        std::cout << "Reason: " << result.message << '\n';
    }

    return result.ok() ? 0 : 1;
}