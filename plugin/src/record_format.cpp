#include "record_format.h"

#include <cstdio>
#include <cstring>

namespace campus_audit {

namespace {

const char kHex[] = "0123456789abcdef";

bool is_ident_char(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '$' || c >= 0x80;
}

bool is_digit(unsigned char c) { return c >= '0' && c <= '9'; }

bool is_space(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

char ascii_lower(char c) {
    return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

// Length of the valid UTF-8 sequence starting at s[0], or 0 if invalid.
size_t utf8_sequence_length(const unsigned char* s, size_t n) {
    unsigned char b = s[0];
    if (b < 0x80) return 1;
    size_t need;
    unsigned char lo = 0x80, hi = 0xBF;
    if (b >= 0xC2 && b <= 0xDF) {
        need = 1;
    } else if (b >= 0xE0 && b <= 0xEF) {
        need = 2;
        if (b == 0xE0) lo = 0xA0;
        if (b == 0xED) hi = 0x9F;  // no UTF-16 surrogates
    } else if (b >= 0xF0 && b <= 0xF4) {
        need = 3;
        if (b == 0xF0) lo = 0x90;
        if (b == 0xF4) hi = 0x8F;
    } else {
        return 0;
    }
    if (n < need + 1) return 0;
    if (s[1] < lo || s[1] > hi) return 0;
    for (size_t i = 2; i <= need; ++i) {
        if (s[i] < 0x80 || s[i] > 0xBF) return 0;
    }
    return need + 1;
}

// Largest prefix length <= max that does not split a UTF-8 sequence.
size_t utf8_safe_cut(const char* s, size_t n, size_t max) {
    if (n <= max) return n;
    size_t k = max;
    while (k > 0 && (static_cast<unsigned char>(s[k]) & 0xC0) == 0x80) --k;
    return k;
}

bool name_char_allowed(unsigned char c, NameKind kind) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '_' || c == '$') {
        return true;
    }
    if (kind == NameKind::User) {
        return c == '.' || c == '-' || c == '@';
    }
    return c == '-';
}

const char* const kSystemSchemas[] = {
    "mysql", "information_schema", "performance_schema", "sys"
};

bool equals_ignore_case(const char* a, size_t alen, const char* b) {
    size_t blen = std::strlen(b);
    if (alen != blen) return false;
    for (size_t i = 0; i < alen; ++i) {
        if (ascii_lower(a[i]) != ascii_lower(b[i])) return false;
    }
    return true;
}

}  // namespace

// ---------------------------------------------------------------- JsonWriter

JsonWriter::JsonWriter(char* buffer, size_t capacity)
    : buffer_(buffer), capacity_(capacity), length_(0),
      ok_(buffer != nullptr && capacity > 0), first_field_(true) {}

void JsonWriter::put(char c) {
    if (!ok_) return;
    if (length_ + 1 >= capacity_) {  // keep room for a final NUL
        ok_ = false;
        return;
    }
    buffer_[length_++] = c;
    buffer_[length_] = '\0';
}

void JsonWriter::put_raw(const char* s, size_t n) {
    for (size_t i = 0; i < n && ok_; ++i) put(s[i]);
}

void JsonWriter::put_key(const char* key) {
    if (!first_field_) put(',');
    first_field_ = false;
    put('"');
    put_raw(key, std::strlen(key));
    put('"');
    put(':');
}

void JsonWriter::put_escaped(const char* s, size_t n) {
    const unsigned char* p = reinterpret_cast<const unsigned char*>(s);
    size_t i = 0;
    while (i < n && ok_) {
        unsigned char c = p[i];
        if (c == '"' || c == '\\') {
            put('\\');
            put(static_cast<char>(c));
            ++i;
        } else if (c == '\n') {
            put_raw("\\n", 2); ++i;
        } else if (c == '\r') {
            put_raw("\\r", 2); ++i;
        } else if (c == '\t') {
            put_raw("\\t", 2); ++i;
        } else if (c < 0x20 || c == 0x7F) {
            char esc[7] = {'\\', 'u', '0', '0', kHex[c >> 4], kHex[c & 0xF], 0};
            put_raw(esc, 6);
            ++i;
        } else if (c < 0x80) {
            put(static_cast<char>(c));
            ++i;
        } else {
            size_t len = utf8_sequence_length(p + i, n - i);
            if (len == 0) {
                // Not valid UTF-8 (or a non-UTF-8 client charset): substitute
                // U+FFFD rather than emitting bytes that make the line invalid.
                put_raw("\\ufffd", 6);
                ++i;
            } else {
                put_raw(s + i, len);
                i += len;
            }
        }
    }
}

void JsonWriter::begin_object() {
    put('{');
    first_field_ = true;
}

void JsonWriter::end_object() {
    put('}');
    put('\n');
}

void JsonWriter::field_string(const char* key, const char* value, size_t length) {
    put_key(key);
    if (value == nullptr) {
        put_raw("null", 4);
        return;
    }
    put('"');
    put_escaped(value, length);
    put('"');
}

void JsonWriter::field_string_bounded(const char* key, const char* value,
                                      size_t length, size_t max_length,
                                      bool* truncated) {
    size_t keep = value ? utf8_safe_cut(value, length, max_length) : 0;
    if (truncated) *truncated = value != nullptr && keep < length;
    field_string(key, value, keep);
}

void JsonWriter::field_cstring(const char* key, const char* value, size_t max_scan) {
    field_string(key, value, value ? bounded_length(value, max_scan) : 0);
}

void JsonWriter::field_uint(const char* key, unsigned long long value) {
    char digits[24];
    int n = std::snprintf(digits, sizeof(digits), "%llu", value);
    put_key(key);
    put_raw(digits, static_cast<size_t>(n));
}

void JsonWriter::field_int(const char* key, long long value) {
    char digits[24];
    int n = std::snprintf(digits, sizeof(digits), "%lld", value);
    put_key(key);
    put_raw(digits, static_cast<size_t>(n));
}

void JsonWriter::field_bool(const char* key, bool value) {
    put_key(key);
    if (value) put_raw("true", 4); else put_raw("false", 5);
}

void JsonWriter::field_null(const char* key) {
    put_key(key);
    put_raw("null", 4);
}

// ---------------------------------------------------------------- digest

size_t sql_digest(const char* sql, size_t length, char* out, size_t max_length,
                  bool* truncated) {
    const unsigned char* s = reinterpret_cast<const unsigned char*>(sql);
    size_t i = 0, o = 0;
    bool pending_space = false;
    bool cut = false;
    if (truncated) *truncated = false;
    if (out == nullptr) return 0;
    if (sql == nullptr) {
        out[0] = '\0';
        return 0;
    }

    // Appends one byte; on overflow marks the digest as cut and stops.
    auto emit = [&](unsigned char c) -> bool {
        if (o >= max_length) {
            cut = true;
            return false;
        }
        out[o++] = static_cast<char>(c);
        return true;
    };
    auto flush_space = [&]() -> bool {
        if (pending_space && o > 0) {
            pending_space = false;
            return emit(' ');
        }
        pending_space = false;
        return true;
    };
    // Skips a quoted literal starting at s[i] (the quote character).
    // A backslash right before the quote is the one place where sql_mode
    // decides where a literal ends: an escaped quote by default, the end of
    // the literal under NO_BACKSLASH_ESCAPES, where reading on would put the
    // next literal into the digest ('C:\', 'secret').  The plugin cannot see
    // the session's sql_mode, so the rest of the statement counts as one
    // literal, which hides every literal under either reading.  (\\ pairs end
    // a literal at the same place in both modes.)
    auto skip_quoted = [&](unsigned char quote) {
        ++i;
        while (i < length) {
            unsigned char c = s[i];
            if (c == '\\' && quote != '`' && i + 1 < length) {
                if (s[i + 1] == quote) {
                    i = length;
                    return;
                }
                i += 2;
                continue;
            }
            if (c == quote) {
                if (i + 1 < length && s[i + 1] == quote) {  // doubled quote
                    i += 2;
                    continue;
                }
                ++i;
                return;
            }
            ++i;
        }
    };

    while (i < length && !cut) {
        unsigned char c = s[i];

        if (is_space(c)) {
            pending_space = true;
            ++i;
            continue;
        }
        // Comments are dropped entirely (including /*! executable */ ones):
        // they can carry literals, and the digest is not meant to be replayed.
        if (c == '#' ||
            (c == '-' && i + 1 < length && s[i + 1] == '-' &&
             (i + 2 >= length || is_space(s[i + 2])))) {
            while (i < length && s[i] != '\n') ++i;
            pending_space = true;
            continue;
        }
        if (c == '/' && i + 1 < length && s[i + 1] == '*') {
            i += 2;
            while (i + 1 < length && !(s[i] == '*' && s[i + 1] == '/')) ++i;
            i = (i + 1 < length) ? i + 2 : length;
            pending_space = true;
            continue;
        }

        if (!flush_space()) break;

        if (c == '\'' || c == '"') {
            // Double-quoted text is masked too: it is a string literal unless
            // sql_mode contains ANSI_QUOTES, and masking is the safe choice.
            skip_quoted(c);
            emit('?');
        } else if (c == '`') {
            size_t start = i;
            skip_quoted('`');
            for (size_t k = start; k < i && !cut; ++k) emit(s[k]);
        } else if (is_digit(c) || (c == '.' && i + 1 < length && is_digit(s[i + 1]))) {
            // Numbers, 0x.. hex and 0b.. bit literals, 1.5e-3 ...
            ++i;
            while (i < length) {
                unsigned char d = s[i];
                if (is_ident_char(d) || d == '.') {
                    ++i;
                } else if ((d == '+' || d == '-') && (s[i - 1] == 'e' || s[i - 1] == 'E')) {
                    ++i;
                } else {
                    break;
                }
            }
            emit('?');
        } else if (is_ident_char(c)) {
            size_t start = i;
            while (i < length && is_ident_char(s[i])) ++i;
            size_t n = i - start;
            // X'..', B'..', N'..' and _charset'..' prefixes belong to the literal.
            bool prefix = (n == 1 && (ascii_lower(static_cast<char>(s[start])) == 'x' ||
                                      ascii_lower(static_cast<char>(s[start])) == 'b' ||
                                      ascii_lower(static_cast<char>(s[start])) == 'n')) ||
                          s[start] == '_';
            if (prefix && i < length && s[i] == '\'') {
                skip_quoted('\'');
                emit('?');
            } else {
                for (size_t k = start; k < i && !cut; ++k) emit(s[k]);
            }
        } else {
            emit(c);
            ++i;
        }
    }

    // A cut digest must not end inside a multi-byte UTF-8 sequence.
    if (cut && o > 0) {
        size_t start = o - 1;
        while (start > 0 && (static_cast<unsigned char>(out[start]) & 0xC0) == 0x80) --start;
        if (static_cast<unsigned char>(out[start]) >= 0x80 &&
            utf8_sequence_length(reinterpret_cast<unsigned char*>(out) + start,
                                 o - start) != o - start) {
            o = start;
        }
    }
    out[o] = '\0';
    if (truncated) *truncated = cut;
    return o;
}

// ---------------------------------------------------------------- name lists

AuditResult parse_name_list(const char* text, NameKind kind, NameList* out) {
    out->match_all = false;
    out->count = 0;
    const char* what = kind == NameKind::Database ? "database" : "user";
    if (text == nullptr) return {AuditError::None, ""};

    const char* p = text;
    while (*p) {
        while (*p == ' ' || *p == '\t') ++p;
        const char* start = p;
        while (*p && *p != ',') ++p;
        const char* end = p;
        while (end > start && (end[-1] == ' ' || end[-1] == '\t')) --end;
        size_t n = static_cast<size_t>(end - start);

        if (n == 0) {
            if (*p == ',' || out->count > 0) {
                return {AuditError::invalid_Configuration,
                        std::string("empty ") + what + " name in list"};
            }
        } else if (n == 1 && *start == '*' && kind == NameKind::Database) {
            out->match_all = true;
        } else {
            if (n > static_cast<size_t>(NameList::kMaxNameLength)) {
                return {AuditError::invalid_Configuration,
                        std::string(what) + " name longer than 128 characters"};
            }
            for (size_t k = 0; k < n; ++k) {
                if (!name_char_allowed(static_cast<unsigned char>(start[k]), kind)) {
                    return {AuditError::invalid_Configuration,
                            std::string("unsupported character in ") + what +
                            " name '" + std::string(start, n) + "'"};
                }
            }
            if (out->count == NameList::kMaxNames) {
                return {AuditError::invalid_Configuration,
                        std::string("more than 16 ") + what + " names"};
            }
            std::memcpy(out->names[out->count], start, n);
            out->names[out->count][n] = '\0';
            ++out->count;
        }
        if (*p == ',') {
            ++p;
            if (*p == '\0') {
                return {AuditError::invalid_Configuration,
                        std::string("trailing comma in ") + what + " list"};
            }
        }
    }
    if (out->match_all && out->count > 0) {
        return {AuditError::invalid_Configuration,
                "'*' cannot be combined with explicit database names"};
    }
    return {AuditError::None, ""};
}

bool database_matches(const NameList& list, const char* db, size_t length) {
    if (db == nullptr || length == 0) return false;
    if (list.match_all) {
        for (const char* sys : kSystemSchemas) {
            if (equals_ignore_case(db, length, sys)) return false;
        }
        return true;
    }
    for (int k = 0; k < list.count; ++k) {
        if (equals_ignore_case(db, length, list.names[k])) return true;
    }
    return false;
}

bool user_matches(const NameList& list, const char* user, size_t length) {
    if (user == nullptr) return false;
    for (int k = 0; k < list.count; ++k) {
        if (std::strlen(list.names[k]) == length &&
            std::memcmp(list.names[k], user, length) == 0) {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- misc

void format_utc_timestamp(long long seconds, long micros, char* out) {
    long long days = seconds >= 0 ? seconds / 86400 : (seconds - 86399) / 86400;
    long long rem = seconds - days * 86400;
    // Civil-from-days (H. Hinnant), valid for the proleptic Gregorian calendar.
    long long z = days + 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    long long doe = z - era * 146097;
    long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long long y = yoe + era * 400;
    long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long long mp = (5 * doy + 2) / 153;
    long long d = doy - (153 * mp + 2) / 5 + 1;
    long long m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) ++y;
    // Keep every field inside the range of a valid timestamp so the 32-byte
    // buffer of the callers can never be too small (the server never passes
    // values outside years 0001-9999; this only bounds a corrupt input).
    unsigned year = static_cast<unsigned>(y < 0 ? 0 : (y > 9999 ? 9999 : y));
    unsigned month = static_cast<unsigned>(m < 1 ? 1 : (m > 12 ? 12 : m));
    unsigned day = static_cast<unsigned>(d < 1 ? 1 : (d > 31 ? 31 : d));
    unsigned hour = static_cast<unsigned>(rem / 3600) % 24;
    unsigned minute = static_cast<unsigned>(rem / 60 % 60);
    unsigned second = static_cast<unsigned>(rem % 60);
    unsigned micro = static_cast<unsigned>(micros < 0 ? 0 : (micros > 999999 ? 999999 : micros));
    std::snprintf(out, 32, "%04u-%02u-%02uT%02u:%02u:%02u.%06uZ", year, month, day, hour, minute,
                  second, micro);
}

size_t bounded_length(const char* s, size_t max_scan) {
    if (s == nullptr) return 0;
    size_t n = 0;
    while (n < max_scan && s[n] != '\0') ++n;
    return n;
}

bool is_access_denied_error(long long code) {
    return code == 1044 || code == 1142 || code == 1143 || code == 1227 || code == 1370;
}

size_t account_login_length(const char* account, size_t length) {
    if (account == nullptr) return 0;
    size_t n = 0;
    while (n < length && account[n] != '[' && account[n] != '\0') ++n;
    return n;
}

}  // namespace campus_audit
