// Unit tests for the server-independent parts of campus_audit:
// JSON escaping, the literal-masking statement digest, name-list parsing and
// timestamp formatting.  Exit code 0 means every check passed.

#include "../src/record_format.h"

#include <cstring>
#include <iostream>
#include <string>

using namespace campus_audit;

static int failures = 0;

static void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS: " : "FAIL: ") << name << '\n';
    if (!condition) ++failures;
}

static std::string digest(const std::string& sql, size_t max = 1024, bool* truncated = nullptr) {
    std::string out(max + 1, '\0');
    bool t = false;
    size_t n = sql_digest(sql.data(), sql.size(), &out[0], max, &t);
    if (truncated) *truncated = t;
    out.resize(n);
    return out;
}

static std::string json_of(const char* value, size_t len) {
    char buf[512];
    JsonWriter w(buf, sizeof(buf));
    w.begin_object();
    w.field_string("v", value, len);
    w.end_object();
    return w.ok() ? std::string(w.data(), w.size()) : std::string("<overflow>");
}

int main() {
    // ---- JSON escaping
    check(json_of("plain", 5) == "{\"v\":\"plain\"}\n", "JSON plain string");
    check(json_of("a\"b\\c", 5) == "{\"v\":\"a\\\"b\\\\c\"}\n", "JSON quotes and backslashes escaped");
    check(json_of("l1\nl2\t\r", 7) == "{\"v\":\"l1\\nl2\\t\\r\"}\n", "JSON newline/tab/CR escaped");
    {
        const char ctl[] = {'x', '\x01', '\x1f', '\x7f'};
        check(json_of(ctl, 4) == "{\"v\":\"x\\u0001\\u001f\\u007f\"}\n", "JSON control characters escaped");
    }
    {
        const char nul[] = {'a', '\0', 'b'};
        check(json_of(nul, 3) == "{\"v\":\"a\\u0000b\"}\n", "JSON embedded NUL escaped, length respected");
    }
    check(json_of("Gr\xC3\xBC\xC3\x9F" "e \xE2\x82\xAC \xF0\x9F\x98\x80", 16) ==
              "{\"v\":\"Gr\xC3\xBC\xC3\x9F" "e \xE2\x82\xAC \xF0\x9F\x98\x80\"}\n",
          "JSON valid UTF-8 kept as is");
    check(json_of("bad\xC3(\xFF", 6) == "{\"v\":\"bad\\ufffd(\\ufffd\"}\n",
          "JSON invalid UTF-8 replaced by U+FFFD");
    check(json_of("\xED\xA0\x80", 3) == "{\"v\":\"\\ufffd\\ufffd\\ufffd\"}\n",
          "JSON UTF-16 surrogate encoded in UTF-8 rejected");
    check(json_of("\xC0\xAF", 2) == "{\"v\":\"\\ufffd\\ufffd\"}\n", "JSON overlong encoding rejected");
    check(json_of(nullptr, 0) == "{\"v\":null}\n", "JSON NULL pointer becomes null");
    check(json_of("", 0) == "{\"v\":\"\"}\n", "JSON empty string stays empty string");

    {
        char small[16];
        JsonWriter w(small, sizeof(small));
        w.begin_object();
        w.field_string("key", "this value is far too long", 26);
        w.end_object();
        check(!w.ok(), "JSON overflow detected instead of writing past the buffer");
        check(std::strlen(small) < sizeof(small), "JSON overflow keeps buffer NUL-terminated");
    }
    {
        char buf[256];
        JsonWriter w(buf, sizeof(buf));
        bool truncated = false;
        w.begin_object();
        w.field_string_bounded("v", "ab\xE2\x82\xAC" "cd", 7, 4, &truncated);
        w.end_object();
        check(truncated && std::string(w.data()) == "{\"v\":\"ab\"}\n",
              "bounded field cut before a multi-byte character");
    }
    {
        char buf[256];
        JsonWriter w(buf, sizeof(buf));
        w.begin_object();
        w.field_uint("u", 18446744073709551615ULL);
        w.field_int("i", -1045);
        w.field_bool("b", true);
        w.field_null("n");
        w.end_object();
        check(std::string(w.data()) ==
                  "{\"u\":18446744073709551615,\"i\":-1045,\"b\":true,\"n\":null}\n",
              "JSON numbers, booleans and null");
    }

    // ---- statement digest
    check(digest("INSERT INTO rooms (name, capacity) VALUES ('Lab', 12)") ==
              "INSERT INTO rooms (name, capacity) VALUES (?, ?)",
          "digest masks string and number literals");
    check(digest("SELECT * FROM t WHERE a = \"x\" AND b = 'it''s' AND c = 'a\\'b'") ==
              "SELECT * FROM t WHERE a = ? AND b = ? AND c = ?",
          "digest masks double-quoted, doubled-quote and backslash-escaped strings");
    // NO_BACKSLASH_ESCAPES: 'C:\' ends at its second quote; read with the
    // default rules the literal would run on and 'pw123' would leak.
    check(digest("INSERT INTO t VALUES ('C:\\', 'pw123')") == "INSERT INTO t VALUES (?",
          "a backslash before a quote masks the rest (no leak under NO_BACKSLASH_ESCAPES)");
    check(digest("UPDATE t SET note = 'it\\'s my secret' WHERE id = 5") == "UPDATE t SET note = ?",
          "the same rule hides the rest of a default-mode escaped quote");
    check(digest("SELECT 'C:\\\\', 'x'") == "SELECT ?, ?",
          "an escaped backslash before the quote ends the literal in both modes (structure kept)");
    check(digest("CREATE USER bob IDENTIFIED BY 'S3cret!pw'") == "CREATE USER bob IDENTIFIED BY ?",
          "digest hides passwords given as literals");
    check(digest("UPDATE users SET password_hash = 'pbkdf2:sha256:600000$abc$def' WHERE user_id = 7")
              .find("pbkdf2") == std::string::npos,
          "digest hides password hashes");
    check(digest("SELECT x'4142', X'43', 0x4445, b'01', 0b11, N'nat', _utf8mb4'intro'") ==
              "SELECT ?, ?, ?, ?, ?, ?, ?",
          "digest masks hex, bit, national and introducer literals");
    check(digest("SELECT 1.5e-3, .5, -7, 3E+2") == "SELECT ?, ?, -?, ?",
          "digest masks decimals and exponents");
    check(digest("SELECT t1.col2 FROM `my table` AS t1") == "SELECT t1.col2 FROM `my table` AS t1",
          "digest keeps identifiers containing digits and backtick identifiers");
    check(digest("SELECT `we``ird` FROM t") == "SELECT `we``ird` FROM t",
          "digest keeps doubled backticks inside identifiers");
    check(digest("SELECT `a\\` FROM t WHERE x = 'y'") == "SELECT `a\\` FROM t WHERE x = ?",
          "digest: a backslash is not an escape inside `identifiers` (the closing backtick still closes)");
    check(digest("SELECT 1 -- token=abc\nFROM t # secret\n/* key=42 */ WHERE /*!50000 a='x' */ b=2") ==
              "SELECT ? FROM t WHERE b=?",
          "digest removes all comment styles including executable comments");
    check(digest("  SELECT\n\t\t1  ") == "SELECT ?", "digest collapses whitespace");
    check(digest("SELECT a--b FROM t") == "SELECT a--b FROM t", "'--' without trailing space is not a comment");
    check(digest("") == "", "digest of empty statement");
    check(digest("SELECT 'unterminated") == "SELECT ?", "digest handles an unterminated string");
    check(digest("SELECT /* unterminated") == "SELECT", "digest handles an unterminated comment");
    check(digest("SELECT @v, @@sql_mode, @'q'") == "SELECT @v, @@sql_mode, @?",
          "digest keeps variable names but masks quoted ones");
    {
        bool truncated = false;
        std::string d = digest("SELECT abcdefghij FROM t", 10, &truncated);
        check(truncated && d == "SELECT abc", "digest truncates at max length and reports it");
    }
    {
        bool truncated = false;
        std::string d = digest("SELECT `\xC3\xA4\xC3\xA4`", 10, &truncated);
        check(truncated && d == "SELECT `\xC3\xA4", "digest never ends inside a UTF-8 sequence");
    }
    {
        bool truncated = true;
        std::string d = digest("SELECT 1", 0, &truncated);
        check(truncated && d.empty(), "digest with max length 0 is empty and marked truncated");
    }
    {
        std::string longsql = "INSERT INTO t VALUES ('" + std::string(100000, 'x') + "')";
        bool truncated = true;
        std::string d = digest(longsql, 1024, &truncated);
        check(!truncated && d == "INSERT INTO t VALUES (?)", "100 kB literal collapses to one '?'");
    }
    {
        bool truncated = true;
        char out[8];
        size_t n = sql_digest(nullptr, 5, out, 7, &truncated);
        check(n == 0 && out[0] == '\0' && !truncated, "digest of a NULL statement");
    }

    // ---- name lists
    {
        NameList l;
        AuditResult r = parse_name_list("university_resources, campus_demo ,x$1", NameKind::Database, &l);
        check(r.ok() && l.count == 3 && std::string(l.names[1]) == "campus_demo",
              "database list parsed and trimmed");
        check(database_matches(l, "University_Resources", 20), "database match is case-insensitive");
        check(!database_matches(l, "university", 10), "database match needs the whole name");
        check(!database_matches(l, nullptr, 0), "NULL database never matches");
    }
    {
        NameList l;
        check(parse_name_list("", NameKind::Database, &l).ok() && l.count == 0 && !l.match_all,
              "empty database list watches nothing");
        check(!database_matches(l, "university_resources", 20), "empty list matches nothing");
    }
    {
        NameList l;
        check(parse_name_list("*", NameKind::Database, &l).ok() && l.match_all, "'*' accepted for databases");
        check(database_matches(l, "anything", 8), "'*' matches user schemas");
        check(!database_matches(l, "mysql", 5) && !database_matches(l, "PERFORMANCE_SCHEMA", 18),
              "'*' never matches system schemas");
    }
    {
        NameList l;
        check(parse_name_list("a,,b", NameKind::Database, &l).code == AuditError::invalid_Configuration,
              "empty element rejected");
        check(parse_name_list("a,", NameKind::Database, &l).code == AuditError::invalid_Configuration,
              "trailing comma rejected");
        check(parse_name_list("bad name", NameKind::Database, &l).code == AuditError::invalid_Configuration,
              "space inside a name rejected");
        check(parse_name_list("a;DROP", NameKind::Database, &l).code == AuditError::invalid_Configuration,
              "punctuation rejected");
        check(parse_name_list("*,a", NameKind::Database, &l).code == AuditError::invalid_Configuration,
              "'*' cannot be mixed with names");
        check(parse_name_list("*", NameKind::User, &l).code == AuditError::invalid_Configuration,
              "'*' rejected for users");
        std::string many;
        for (int i = 0; i < 17; ++i) many += (i ? ",d" : "d") + std::to_string(i);
        check(parse_name_list(many.c_str(), NameKind::Database, &l).code == AuditError::invalid_Configuration,
              "more than 16 names rejected");
        std::string longname(129, 'a');
        check(parse_name_list(longname.c_str(), NameKind::Database, &l).code ==
                  AuditError::invalid_Configuration,
              "name longer than 128 characters rejected");
    }
    {
        NameList l;
        check(parse_name_list("monitor, backup.user,svc-1@x", NameKind::User, &l).ok() && l.count == 3,
              "user list with '.', '-' and '@' accepted");
        check(user_matches(l, "monitor", 7) && !user_matches(l, "Monitor", 7),
              "user match is exact and case-sensitive");
        check(!user_matches(l, "monitorx", 8), "user match needs the whole name");
        // Security: a shorter login must not inherit the exclusion of a longer listed name,
        // otherwise a user called "mon" could hide from the audit by being a prefix of "monitor".
        check(!user_matches(l, "mon", 3) && !user_matches(l, "backup", 6) && !user_matches(l, "", 0),
              "user match: a login that is only a prefix of an excluded name is still audited");
    }

    // ---- timestamps
    {
        char ts[32];
        format_utc_timestamp(0, 0, ts);
        check(std::string(ts) == "1970-01-01T00:00:00.000000Z", "timestamp of the epoch");
        format_utc_timestamp(1792922400LL, 123456, ts);
        check(std::string(ts) == "2026-10-25T10:00:00.123456Z", "timestamp 2026-10-25");
        format_utc_timestamp(951782400LL, 1, ts);
        check(std::string(ts) == "2000-02-29T00:00:00.000001Z", "timestamp on a leap day");
        format_utc_timestamp(-1, 999999, ts);
        check(std::string(ts) == "1969-12-31T23:59:59.999999Z", "timestamp one second before the epoch");
        format_utc_timestamp(-86400, 0, ts);
        check(std::string(ts) == "1969-12-31T00:00:00.000000Z", "timestamp exactly one day before the epoch");
    }

    check(bounded_length("abcdef", 3) == 3 && bounded_length(nullptr, 3) == 0,
          "bounded_length stops at the limit and accepts NULL");

    // ---- refused statements (recorded although no TABLE event announced them)
    check(is_access_denied_error(1142) && is_access_denied_error(1044) && is_access_denied_error(1143) &&
              is_access_denied_error(1227) && is_access_denied_error(1370),
          "privilege errors are recognised (1044, 1142, 1143, 1227, 1370)");
    check(!is_access_denied_error(0) && !is_access_denied_error(1045) && !is_access_denied_error(1146) &&
              !is_access_denied_error(4025) && !is_access_denied_error(1064),
          "other errors are not access denials (0, 1045 login, 1146, 4025, 1064)");
    {
        const char account[] = "campus_app[campus_app] @ localhost [127.0.0.1]";
        check(account_login_length(account, sizeof(account) - 1) == 10,
              "login name is the part of the account before '['");
        check(account_login_length("root", 4) == 4 && account_login_length(nullptr, 5) == 0 &&
                  account_login_length("ab[", 1) == 1,
              "account without '[', NULL account and the length bound");
    }

    std::cout << "Failures: " << failures << '\n';
    return failures == 0 ? 0 : 1;
}
