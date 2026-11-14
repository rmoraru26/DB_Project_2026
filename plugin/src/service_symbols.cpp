// Service pointers used by campus_audit, for builds that cannot link
// libmysqlservices (e.g. a MinGW/Zig toolchain cannot link the MSVC-built
// mysqlservices.lib because it carries /DEFAULTLIB:MSVCRT directives).
//
// This is exactly what libservices/<name>_service.c in the MariaDB source tree
// contains: a variable holding the service *version*.  When the server loads
// the plugin it looks the symbol up, checks the version and overwrites the
// variable with the address of the real service structure
// (sql/sql_plugin.cc, plugin_dl_add / list_of_services).
//
// Builds that link libmysqlservices.a / mysqlservices.lib must NOT compile
// this file (duplicate symbols); plugin/Makefile adds it only when it finds no
// libmysqlservices.a (SERVICES_LIB), and plugin/build_windows.ps1 always does.

#include <service_versions.h>

extern "C" {
SERVICE_VERSION my_print_error_service = (void*)VERSION_my_print_error;
SERVICE_VERSION thd_alloc_service = (void*)VERSION_thd_alloc;
}
