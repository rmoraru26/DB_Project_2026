// Server-independent formatting helpers for campus_audit.
//
// Nothing in this file includes MariaDB headers, so it can be unit tested
// without a running server (see plugin/tests/test_record_format.cpp).

#ifndef CAMPUS_AUDIT_RECORD_FORMAT_H
#define CAMPUS_AUDIT_RECORD_FORMAT_H

#include <cstddef>
#include <string>

#include "audit_error.h"

namespace campus_audit {

// Bounded JSON object writer.  It never writes past the buffer it was given;
// if a value does not fit, ok() becomes false and the caller drops the record
// instead of emitting a truncated (invalid) JSON line.
class JsonWriter {
public:
    JsonWriter(char* buffer, size_t capacity);

    void begin_object();
    void end_object();     // also appends the terminating '\n'

    // A NULL pointer is written as JSON null: missing data is never invented.
    void field_string(const char* key, const char* value, size_t length);
    // Writes at most max_length input bytes (cut on a UTF-8 boundary) and
    // reports whether anything was cut.
    void field_string_bounded(const char* key, const char* value, size_t length,
                              size_t max_length, bool* truncated);
    // NUL-terminated input; reads at most max_scan bytes.
    void field_cstring(const char* key, const char* value, size_t max_scan = 512);
    void field_uint(const char* key, unsigned long long value);
    void field_int(const char* key, long long value);
    void field_bool(const char* key, bool value);
    void field_null(const char* key);

    bool ok() const { return ok_; }
    size_t size() const { return length_; }
    const char* data() const { return buffer_; }

private:
    void put(char c);
    void put_raw(const char* s, size_t n);
    void put_key(const char* key);
    void put_escaped(const char* s, size_t n);

    char* buffer_;
    size_t capacity_;
    size_t length_;
    bool ok_;
    bool first_field_;
};

// Produces a statement "digest": the SQL text with every literal (quoted
// strings, numbers, hex/bit literals) replaced by '?', comments removed and
// whitespace collapsed.  Identifiers and keywords are kept.  The output is
// NUL-terminated and at most max_length bytes long (cut on a UTF-8 boundary);
// `out` must therefore hold max_length + 1 bytes.
// Returns the number of bytes written (excluding the NUL).
size_t sql_digest(const char* sql, size_t length, char* out, size_t max_length,
                  bool* truncated);

// A validated, comma-separated list of names from a system variable.
struct NameList {
    static const int kMaxNames = 16;
    static const int kMaxNameLength = 128;
    bool match_all;           // the list was exactly "*"
    int count;
    char names[kMaxNames][kMaxNameLength + 1];
};

enum class NameKind { Database, User };

// Parses "a, b,c" into a NameList.  Empty input gives an empty list.
// "*" is accepted only for databases.  Returns invalid_Configuration with a
// human-readable message for anything it refuses.
AuditResult parse_name_list(const char* text, NameKind kind, NameList* out);

// Database names are compared ASCII-case-insensitively (conservative: on a
// lower_case_table_names=0 server "Foo" and "foo" are both audited).
// System schemas are never matched by "*".
bool database_matches(const NameList& list, const char* db, size_t length);
// User names are compared exactly.
bool user_matches(const NameList& list, const char* user, size_t length);

// "2026-10-25T10:11:12.123456Z"; out must hold at least 32 bytes.
void format_utc_timestamp(long long seconds, long micros, char* out);

// Bounded strlen for server-supplied C strings.
size_t bounded_length(const char* s, size_t max_scan);

// True for the errors the privilege system raises before a statement opens
// any table: ER_DBACCESS_DENIED_ERROR (1044), ER_TABLEACCESS_DENIED_ERROR
// (1142), ER_COLUMNACCESS_DENIED_ERROR (1143), ER_SPECIFIC_ACCESS_DENIED_ERROR
// (1227) and ER_PROCACCESS_DENIED_ERROR (1370).
bool is_access_denied_error(long long code);

// GENERAL events name the session as "priv_user[user] @ host [ip]"
// (make_user_name() in sql/sql_audit.h).  Returns the length of the account
// name at its start (up to the first '['), or the whole length if there is
// no '['.  Used to apply campus_audit_exclude_users; for ordinary accounts it
// equals the login name that TABLE events carry, for anonymous and proxy
// logins it does not, and the refused statement is then recorded.
size_t account_login_length(const char* account, size_t length);

}  // namespace campus_audit

#endif
