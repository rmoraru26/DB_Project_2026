// campus_audit: a MariaDB audit plugin for the university resource system.
//
// It subscribes to three audit event classes of the MariaDB audit API
// (include/mysql/plugin_audit.h, MYSQL_AUDIT_INTERFACE_VERSION 0x0303):
//
//   CONNECTION  connect / failed connect / disconnect / change user
//   TABLE       per-statement table access (LOCK) and DDL on watched schemas
//   GENERAL     only the STATUS subclass, to close a statement that touched
//               a watched table with its error code and a literal-free digest,
//               and to record statements the privilege system refused before
//               any table was opened (default schema watched; since 1.1.0)
//
// and appends one JSON object per event to a JSON Lines file.  The audit API
// is notification-only (event_notify returns void), so the plugin can never
// veto or fail the statement it observes: on I/O errors it fails open, counts
// what it lost and writes an explicit "audit_gap" record once it recovers.
//
// See docs/plugin-api-notes.md for the API facts this file relies on.

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

#include <mysql/plugin.h>
#include <mysql/plugin_audit.h>
#include <typelib.h>

// Fail the build with a clear message instead of obscure struct errors.
#ifndef MARIA_PLUGIN_INTERFACE_VERSION
#error "campus_audit must be compiled against MariaDB server headers (maria_declare_plugin is missing; MySQL headers are not supported)"
#endif
#if !defined(MYSQL_AUDIT_INTERFACE_VERSION) || MYSQL_AUDIT_INTERFACE_VERSION < 0x0303
#error "campus_audit needs audit API 0x0303 or newer (mysql_event_general.database/port, mysql_event_table.query_id)"
#endif

#include "audit_error.h"
#include "audit_error_reporter.h"
#include "log_sink.h"
#include "platform.h"
#include "record_format.h"
#include "runtime_config.h"
#include "gap_accounting.h"

using campus_audit::JsonWriter;
using campus_audit::LockGuard;
using campus_audit::LogSink;
using campus_audit::Mutex;
using campus_audit::NameKind;
using campus_audit::NameList;
using campus_audit::RwLock;

namespace {

const char kPluginVersion[] = "1.1.1";
const unsigned int kErUnknownError = 1105;      // ER_UNKNOWN_ERROR (mysqld_error.h)
const size_t kMaxPathLength = 512;
const long long kReopenIntervalSeconds = 5;
const size_t kFieldScan = 256;                  // max bytes read from server C strings
const size_t kRecordBase = 16384;               // record buffer without the digest
const size_t kListBufferSize = NameList::kMaxNames * (NameList::kMaxNameLength + 2) + 1;

// Set by log_config_change(): the GENERAL STATUS event of the same statement
// writes it, which attributes SET GLOBAL campus_audit_* to an account.
// Not kept in the stmt_query_id THDVAR (as 1.1.0 did): update callbacks run
// with LOCK_global_system_variables held (sys_var_pluginvar::global_update),
// and the first THDVAR access of a session takes that mutex again
// (intern_sys_var_ptr -> sync_dynamic_session_variables).  On Linux the mutex
// is not recursive, so an accepted SET GLOBAL as the first statement of a
// connection hung the whole server; on Windows it is a CRITICAL_SECTION,
// which may be re-entered, so the native tests passed.  A statement runs on
// one OS thread up to its STATUS event, also with the thread pool, so a
// thread-local flag reaches the right event.
thread_local bool log_this_statement = false;

// ------------------------------------------------------------ system variables

char* sv_file_path;
char* sv_databases;
char* sv_exclude_users;
char sv_log_reads;
unsigned long sv_connections;
unsigned int sv_max_sql_length;
char sv_reopen_now;
char sv_readable_by_all;

char file_path_buffer[kMaxPathLength + 1];
char databases_buffer[kListBufferSize];
char exclude_users_buffer[kListBufferSize];

enum ConnectionMode { kConnNone = 0, kConnFailed = 1, kConnAll = 2 };
const char* connection_mode_names[] = {"NONE", "FAILED", "ALL", nullptr};
TYPELIB connection_mode_typelib = {3, "", connection_mode_names, nullptr, nullptr};

// ------------------------------------------------------------ runtime state

Mutex sink_lock;                    // guards the block below
LogSink sink;
char active_path[kMaxPathLength + 1];
bool degraded = false;
bool degradation_reported = false;
long long next_reopen_at = 0;
campus_audit::GapAccounting gap_dropped;
char last_error[256] = "";

RwLock filter_lock;                 // guards the two lists below
NameList db_filter;
NameList user_filter;

std::atomic<unsigned long long> next_seq(1);
std::atomic<bool> initialized(false);
campus_audit::RuntimeConfig runtime_config;
char instance_id[48] = "";

std::atomic<unsigned long long> st_written(0), st_dropped(0), st_write_failures(0),
    st_open_failures(0), st_bytes(0), st_filtered(0), st_unexpected(0), st_reopens(0);

// ------------------------------------------------------------ helpers

long long now_seconds() {
    long long s;
    long us;
    campus_audit::wall_clock(&s, &us);
    return s;
}

void copy_bounded(char* dst, size_t cap, const char* src) {
    std::snprintf(dst, cap, "%s", src ? src : "");
}

// Error sink used from init/deinit and SET GLOBAL (never from event_notify):
// the my_print_error service writes to the server error log and, when a
// client session exists, adds a warning the client can read.
void report_to_server(const AuditResult& r) {
    my_printf_error(kErUnknownError, "campus_audit: %s", 64 /* ME_ERROR_LOG */ | 2048 /* ME_WARNING */,
                    r.message.c_str());
}

// Error sink used inside event_notify.  my_printf_error() is deliberately not
// used there: with ME_ERROR_LOG_ONLY the server re-dispatches a GENERAL ERROR
// audit event to every audit plugin through plugin_foreach() (sql/mysqld.cc,
// my_message_sql), i.e. it would re-enter audit plugins from inside a
// callback.  The server's stderr is its error log, so a plain line is enough.
void report_from_callback(const AuditResult& r) {
    long long s;
    long us;
    campus_audit::wall_clock(&s, &us);
    char ts[32];
    campus_audit::format_utc_timestamp(s, us, ts);
    std::fprintf(stderr, "%s [Warning] campus_audit: %s\n", ts, r.message.c_str());
    std::fflush(stderr);
}

// Common leading fields of every record.
void begin_record(JsonWriter& w, const char* event) {
    long long s;
    long us;
    campus_audit::wall_clock(&s, &us);
    char ts[32];
    campus_audit::format_utc_timestamp(s, us, ts);
    w.begin_object();
    w.field_string("ts", ts, std::strlen(ts));
    w.field_uint("seq", next_seq.fetch_add(1));
    w.field_string("instance", instance_id, std::strlen(instance_id));
    w.field_string("event", event, std::strlen(event));
}

void field_lex(JsonWriter& w, const char* key, const MYSQL_CONST_LEX_STRING& s) {
    if (s.str == nullptr || s.length == 0) {
        w.field_null(key);
    } else {
        w.field_string(key, s.str, s.length > kFieldScan ? kFieldScan : s.length);
    }
}

void field_sized(JsonWriter& w, const char* key, const char* s, unsigned int len) {
    if (s == nullptr) {
        w.field_null(key);
    } else {
        w.field_string(key, s, len > kFieldScan ? kFieldScan : len);
    }
}

// Writes a gap marker after an outage; caller holds sink_lock.  The marker
// starts with a newline so that a line torn by a failed partial write ends
// there and does not swallow the marker (readers skip empty and invalid lines).
bool write_gap_marker_locked() {
    char buf[1024];
    buf[0] = '\n';
    JsonWriter w(buf + 1, sizeof(buf) - 1);
    begin_record(w, "audit_gap");
    w.field_uint("dropped_events", gap_dropped.dropped());
    w.field_string("last_error", last_error, std::strlen(last_error));
    w.end_object();
    if (!w.ok()) {
        copy_bounded(last_error, sizeof(last_error), "could not format audit_gap marker");
        return false;
    }
    AuditResult result = sink.write_all(buf, w.size() + 1);
    if (!result.ok()) copy_bounded(last_error, sizeof(last_error), result.message.c_str());
    return gap_dropped.marker_result(result.ok());
}

// Called after the sink was (re)opened successfully; caller holds sink_lock.
bool leave_degraded_state_locked() {
    if (degraded || gap_dropped.dropped() > 0) {
        if (!write_gap_marker_locked()) {
            ++st_write_failures;
            degraded = true;
            degradation_reported = true;
            next_reopen_at = now_seconds() + kReopenIntervalSeconds;
            sink.close();
            return false;
        }
    }
    degraded = false;
    degradation_reported = false;
    return true;
}

// Appends one finished record.  Fail-open: errors are counted and reported
// once per outage, the caller's statement is never affected.
void write_record(const JsonWriter& w, bool from_callback) {
    if (!w.ok()) {
        ++st_dropped;
        AuditResult r = {AuditError::format_Failed, "record did not fit its buffer; dropped"};
        report_audit_error(r, from_callback ? report_from_callback : report_to_server);
        return;
    }
    AuditResult failure = {AuditError::None, ""};
    bool recovered = false;
    unsigned long long recovered_after = 0;
    {
        LockGuard<Mutex> guard(sink_lock);
        if (degraded) {
            long long now = now_seconds();
            if (now < next_reopen_at) {
                ++st_dropped;
                gap_dropped.event_lost_to_io();
                return;
            }
            next_reopen_at = now + kReopenIntervalSeconds;
            ++st_reopens;
            recovered_after = gap_dropped.dropped();
            AuditResult r = sink.open(active_path);
            const bool marker_written = r.ok() && write_gap_marker_locked();
            if (!r.ok() || !marker_written) {
                if (!r.ok()) ++st_open_failures;
                else ++st_write_failures;
                sink.close();
                ++st_dropped;
                gap_dropped.event_lost_to_io();
                return;
            }
            recovered = true;
            degraded = false;
            degradation_reported = false;
        }
        AuditResult r = sink.write_all(w.data(), w.size());
        if (r.ok()) {
            ++st_written;
            st_bytes += w.size();
        } else {
            ++st_write_failures;
            ++st_dropped;
            gap_dropped.event_lost_to_io();
            degraded = true;
            sink.close();
            next_reopen_at = now_seconds() + kReopenIntervalSeconds;
            copy_bounded(last_error, sizeof(last_error), r.message.c_str());
            if (!degradation_reported) {
                degradation_reported = true;
                failure = r;
                failure.message += "; audit records are being dropped (fail-open), retrying every 5 s";
            }
        }
    }
    AuditErrorSink report = from_callback ? report_from_callback : report_to_server;
    report_audit_error(failure, report);
    if (recovered) {
        AuditResult note = {AuditError::unexpected_Failure,
                            "audit log reopened; " + std::to_string(recovered_after) +
                            " event(s) were lost, see the audit_gap record"};
        report(note);
    }
}

// Allocates a record buffer large enough for any record plus the digest.
struct RecordBuffer {
    explicit RecordBuffer(size_t extra)
        : size(kRecordBase + 6 * extra), data(static_cast<char*>(std::malloc(size))) {}
    ~RecordBuffer() { std::free(data); }
    size_t size;
    char* data;
};

bool user_excluded(const char* user, size_t len) {
    filter_lock.read_lock();
    bool excluded = campus_audit::user_matches(user_filter, user, len);
    filter_lock.read_unlock();
    return excluded;
}

// ------------------------------------------------------------ THD-local state

MYSQL_THDVAR_ULONGLONG(stmt_query_id, PLUGIN_VAR_NOSYSVAR | PLUGIN_VAR_NOCMDOPT,
                       "Internal: query id of the statement whose table access was audited",
                       nullptr, nullptr, 0, 0, ~0ULL, 0);

// ------------------------------------------------------------ event handlers

void on_connection(const mysql_event_connection* e) {
    const char* name;
    bool failure = e->status != 0;
    switch (e->event_subclass) {
    case MYSQL_AUDIT_CONNECTION_CONNECT:
        name = failure ? "connect_failed" : "connect";
        break;
    case MYSQL_AUDIT_CONNECTION_DISCONNECT:
        name = "disconnect";
        failure = false;  // status is the disconnect reason, not a failed login
        break;
    case MYSQL_AUDIT_CONNECTION_CHANGE_USER:
        name = failure ? "change_user_failed" : "change_user";
        break;
    default:
        ++st_unexpected;
        return;
    }
    unsigned long mode = runtime_config.connections.load(std::memory_order_relaxed);
    if (mode == kConnNone || (mode == kConnFailed && !failure)) return;
    if (e->user && user_excluded(e->user, e->user_length)) {
        ++st_filtered;
        return;
    }

    RecordBuffer buf(0);
    if (!buf.data) {
        ++st_dropped;
        return;
    }
    JsonWriter w(buf.data, buf.size);
    begin_record(w, name);
    w.field_uint("conn", e->thread_id);
    w.field_int("status", e->status);
    field_sized(w, "user", e->user, e->user_length);
    field_sized(w, "priv_user", e->priv_user, e->priv_user_length);
    field_sized(w, "proxy_user", e->proxy_user, e->proxy_user_length);
    field_sized(w, "host", e->host, e->host_length);
    field_sized(w, "ip", e->ip, e->ip_length);
    w.field_uint("port", e->port);
    field_lex(w, "db", e->database);
    field_sized(w, "tls_version", e->tls_version, e->tls_version_length);
    if (e->event_subclass == MYSQL_AUDIT_CONNECTION_CHANGE_USER) {
        // sql_audit.h fills CHANGE_USER events from the security context
        // that was active *before* the change.
        w.field_string("user_context", "before_change", 13);
    }
    w.end_object();
    write_record(w, true);
}

void on_table(MYSQL_THD thd, const mysql_event_table* e) {
    const char* name;
    switch (e->event_subclass) {
    case MYSQL_AUDIT_TABLE_LOCK:
        if (e->read_only && !runtime_config.log_reads.load(std::memory_order_relaxed)) return;
        name = e->read_only ? "table_read" : "table_write";
        break;
    case MYSQL_AUDIT_TABLE_CREATE: name = "table_create"; break;
    case MYSQL_AUDIT_TABLE_DROP:   name = "table_drop";   break;
    case MYSQL_AUDIT_TABLE_RENAME: name = "table_rename"; break;
    case MYSQL_AUDIT_TABLE_ALTER:  name = "table_alter";  break;
    default:
        ++st_unexpected;
        return;
    }

    filter_lock.read_lock();
    bool watched = campus_audit::database_matches(db_filter, e->database.str, e->database.length) ||
                   (e->event_subclass == MYSQL_AUDIT_TABLE_RENAME &&
                    campus_audit::database_matches(db_filter, e->new_database.str,
                                                   e->new_database.length));
    bool excluded = watched && e->user &&
                    campus_audit::user_matches(user_filter, e->user,
                                               campus_audit::bounded_length(e->user, kFieldScan));
    filter_lock.read_unlock();
    if (!watched) return;
    if (excluded) {
        ++st_filtered;
        return;
    }

    RecordBuffer buf(0);
    if (!buf.data) {
        ++st_dropped;
        return;
    }
    JsonWriter w(buf.data, buf.size);
    begin_record(w, name);
    w.field_uint("conn", e->thread_id);
    w.field_uint("query_id", e->query_id);
    w.field_cstring("user", e->user, kFieldScan);
    w.field_cstring("priv_user", e->priv_user, kFieldScan);
    w.field_cstring("priv_host", e->priv_host, kFieldScan);
    w.field_cstring("host", e->host, kFieldScan);
    w.field_cstring("ip", e->ip, kFieldScan);
    field_lex(w, "db", e->database);
    field_lex(w, "table", e->table);
    if (e->event_subclass == MYSQL_AUDIT_TABLE_RENAME) {
        field_lex(w, "new_db", e->new_database);
        field_lex(w, "new_table", e->new_table);
    }
    w.end_object();
    write_record(w, true);

    if (thd) THDVAR(thd, stmt_query_id) = e->query_id;
}

void write_statement_record(const mysql_event_general* e, bool access_denied);

void on_general(MYSQL_THD thd, const mysql_event_general* e) {
    // LOG, ERROR, RESULT and WARNING are ignored by design: STATUS already
    // carries the final error code and fires once per statement.
    if (e->event_subclass != MYSQL_AUDIT_GENERAL_STATUS || thd == nullptr) return;
    bool config_change = log_this_statement;
    log_this_statement = false;
    unsigned long long pending = THDVAR(thd, stmt_query_id);
    if (config_change || (pending != 0 && pending == e->query_id)) {
        if (pending != 0) THDVAR(thd, stmt_query_id) = 0;
        write_statement_record(e, false);
        return;
    }
    // The privilege check runs before the server opens a table, so a refused
    // statement raised no TABLE event and would otherwise leave no trace
    // (observed with 13.0.2: ER 1142 on a watched table, nothing logged).
    // A GENERAL event does not name the target tables, so the session's
    // default schema decides whether the refusal belongs to a watched schema.
    if (!campus_audit::is_access_denied_error(e->general_error_code)) return;
    filter_lock.read_lock();
    bool watched = campus_audit::database_matches(db_filter, e->database.str, e->database.length);
    bool excluded = watched && e->general_user &&
                    campus_audit::user_matches(
                        user_filter, e->general_user,
                        campus_audit::account_login_length(e->general_user, e->general_user_length));
    filter_lock.read_unlock();
    if (!watched) return;
    if (excluded) {
        ++st_filtered;
        return;
    }
    write_statement_record(e, true);
}

void write_statement_record(const mysql_event_general* e, bool access_denied) {
    unsigned int max_sql = runtime_config.max_sql_length.load(std::memory_order_relaxed);
    RecordBuffer buf(max_sql + 1);
    char* digest = max_sql > 0 ? static_cast<char*>(std::malloc(max_sql + 1)) : nullptr;
    if (!buf.data || (max_sql > 0 && !digest)) {
        std::free(digest);
        ++st_dropped;
        return;
    }
    JsonWriter w(buf.data, buf.size);
    begin_record(w, "statement");
    w.field_uint("conn", e->general_thread_id);
    w.field_uint("query_id", e->query_id);
    field_sized(w, "account", e->general_user, e->general_user_length);
    field_lex(w, "db", e->database);
    field_sized(w, "command", e->general_command, e->general_command_length);
    w.field_int("error_code", e->general_error_code);
    w.field_string("status", e->general_error_code == 0 ? "ok" : "error",
                   e->general_error_code == 0 ? 2 : 5);
    if (access_denied) w.field_bool("access_denied", true);
    if (digest) {
        bool truncated = false;
        size_t n = campus_audit::sql_digest(e->general_query, e->general_query_length,
                                            digest, max_sql, &truncated);
        w.field_string("sql_digest", e->general_query ? digest : nullptr, n);
        w.field_bool("sql_digest_truncated", truncated);
    }
    w.end_object();
    std::free(digest);
    write_record(w, true);
}

void campus_audit_notify(MYSQL_THD thd, unsigned int event_class, const void* event) {
    if (event == nullptr) {
        ++st_unexpected;
        return;
    }
    // Nothing may escape into the server: an exception crossing this C
    // callback boundary would terminate mariadbd.
    try {
        switch (event_class) {
        case MYSQL_AUDIT_CONNECTION_CLASS:
            on_connection(static_cast<const mysql_event_connection*>(event));
            break;
        case MYSQL_AUDIT_TABLE_CLASS:
            on_table(thd, static_cast<const mysql_event_table*>(event));
            break;
        case MYSQL_AUDIT_GENERAL_CLASS:
            on_general(thd, static_cast<const mysql_event_general*>(event));
            break;
        default:
            ++st_unexpected;
            break;
        }
    } catch (...) {
        ++st_dropped;
    }
}

// ------------------------------------------------------------ configuration

// Records a configuration change and asks for the SET statement itself to be
// logged, so the change is attributable to a connection and account.
void log_config_change(MYSQL_THD thd, const char* variable, const char* value) {
    char buf[4096];
    JsonWriter w(buf, sizeof(buf));
    begin_record(w, "config_change");
    w.field_cstring("variable", variable);
    w.field_cstring("value", value, 2048);
    w.end_object();
    write_record(w, false);
    if (thd) log_this_statement = true;    // never THDVAR here, see log_this_statement
}

// Reads a string sysvar value into memory owned by the statement.
const char* read_string_value(MYSQL_THD thd, struct st_mysql_value* value, int* length) {
    char local[kMaxPathLength + 1];
    *length = static_cast<int>(sizeof(local));
    const char* s = value->val_str(value, local, length);
    if (s == nullptr) return nullptr;
    return thd_strmake(thd, s, static_cast<size_t>(*length));
}

int check_file_path(MYSQL_THD thd, struct st_mysql_sys_var*, void* save,
                    struct st_mysql_value* value) {
    int length = 0;
    const char* s = read_string_value(thd, value, &length);
    if (s == nullptr) {
        report_to_server({AuditError::invalid_Configuration, "campus_audit_file_path cannot be NULL"});
        return 1;
    }
    // Opening (and creating) the file here lets SET GLOBAL fail with a
    // reason (including errno) instead of silently switching to an
    // unwritable destination.  update_file_path() opens it again for real.
    LogSink probe;
    probe.set_readable_by_all(sv_readable_by_all != 0);
    AuditResult r = probe.open(s);
    probe.close();
    if (!r.ok()) {
        report_to_server(r);
        return 1;
    }
    *static_cast<const char**>(save) = s;
    return 0;
}

void update_file_path(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    const char* requested = *static_cast<const char* const*>(save);
    AuditResult failure = {AuditError::None, ""};
    char previous[kMaxPathLength + 1];
    {
        LockGuard<Mutex> guard(sink_lock);
        copy_bounded(previous, sizeof(previous), active_path);
        AuditResult r = sink.open(requested);
        if (r.ok()) {
            copy_bounded(active_path, sizeof(active_path), requested);
            copy_bounded(file_path_buffer, sizeof(file_path_buffer), requested);
            *static_cast<char**>(var_ptr) = file_path_buffer;
            if (!leave_degraded_state_locked()) {
                failure = {AuditError::write_Failed,
                           "could not write audit_gap marker; retrying log recovery"};
            }
        } else {
            ++st_open_failures;
            failure = r;
            failure.message += "; keeping the previous audit log";
        }
    }
    report_audit_error(failure, report_to_server);
    if (failure.ok()) {
        std::string value = std::string(requested) + " (previous: " + previous + ")";
        log_config_change(thd, "campus_audit_file_path", value.c_str());
    }
}

int check_name_list(MYSQL_THD thd, void* save, struct st_mysql_value* value, NameKind kind) {
    int length = 0;
    const char* s = read_string_value(thd, value, &length);
    if (s == nullptr) s = thd_strmake(thd, "", 0);
    NameList parsed;
    AuditResult r = campus_audit::parse_name_list(s, kind, &parsed);
    if (!r.ok()) {
        report_to_server(r);
        return 1;
    }
    *static_cast<const char**>(save) = s;
    return 0;
}

int check_databases(MYSQL_THD thd, struct st_mysql_sys_var*, void* save,
                    struct st_mysql_value* value) {
    return check_name_list(thd, save, value, NameKind::Database);
}

int check_exclude_users(MYSQL_THD thd, struct st_mysql_sys_var*, void* save,
                        struct st_mysql_value* value) {
    return check_name_list(thd, save, value, NameKind::User);
}

void update_name_list(MYSQL_THD thd, void* var_ptr, const void* save, NameKind kind,
                      NameList* target, char* storage, const char* variable) {
    const char* s = *static_cast<const char* const*>(save);
    NameList parsed;
    if (!campus_audit::parse_name_list(s, kind, &parsed).ok()) return;  // checked already
    filter_lock.write_lock();
    *target = parsed;
    copy_bounded(storage, kListBufferSize, s);
    *static_cast<char**>(var_ptr) = storage;
    filter_lock.write_unlock();
    log_config_change(thd, variable, s);
}

void update_databases(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    update_name_list(thd, var_ptr, save, NameKind::Database, &db_filter, databases_buffer,
                     "campus_audit_databases");
}

void update_exclude_users(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    update_name_list(thd, var_ptr, save, NameKind::User, &user_filter, exclude_users_buffer,
                     "campus_audit_exclude_users");
}

void update_log_reads(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    char v = *static_cast<const char*>(save);
    *static_cast<char*>(var_ptr) = v;
    runtime_config.log_reads.store(v != 0, std::memory_order_relaxed);
    log_config_change(thd, "campus_audit_log_reads", v ? "ON" : "OFF");
}

void update_connections(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    unsigned long v = *static_cast<const unsigned long*>(save);
    *static_cast<unsigned long*>(var_ptr) = v;
    runtime_config.connections.store(v, std::memory_order_relaxed);
    log_config_change(thd, "campus_audit_connections", v < 3 ? connection_mode_names[v] : "?");
}

void update_max_sql_length(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    unsigned int v = *static_cast<const unsigned int*>(save);
    *static_cast<unsigned int*>(var_ptr) = v;
    runtime_config.max_sql_length.store(v, std::memory_order_relaxed);
    log_config_change(thd, "campus_audit_max_sql_length", std::to_string(v).c_str());
}

// SET GLOBAL campus_audit_reopen_now = ON: close and reopen the same path,
// e.g. after logrotate renamed the file.  The variable always reads OFF.
void update_reopen_now(MYSQL_THD thd, struct st_mysql_sys_var*, void* var_ptr, const void* save) {
    *static_cast<char*>(var_ptr) = 0;
    if (!*static_cast<const char*>(save)) return;
    AuditResult failure = {AuditError::None, ""};
    {
        LockGuard<Mutex> guard(sink_lock);
        ++st_reopens;
        sink.close();
        AuditResult r = sink.open(active_path);
        if (r.ok()) {
            if (!leave_degraded_state_locked()) {
                failure = {AuditError::write_Failed,
                           "could not write audit_gap marker; retrying log recovery"};
            }
        } else {
            ++st_open_failures;
            degraded = true;
            degradation_reported = true;
            next_reopen_at = now_seconds() + kReopenIntervalSeconds;
            copy_bounded(last_error, sizeof(last_error), r.message.c_str());
            failure = r;
        }
    }
    report_audit_error(failure, report_to_server);
    if (failure.ok()) log_config_change(thd, "campus_audit_reopen_now", "ON");
}

MYSQL_SYSVAR_STR(file_path, sv_file_path, PLUGIN_VAR_RQCMDARG,
                 "Audit log file (JSON Lines). Relative paths are relative to the data "
                 "directory. Changing it opens the new file first and keeps the old one "
                 "if that fails.",
                 check_file_path, update_file_path, "campus_audit.jsonl");

MYSQL_SYSVAR_STR(databases, sv_databases, PLUGIN_VAR_RQCMDARG,
                 "Comma-separated schemas whose table access and DDL is audited; '*' means "
                 "every schema except mysql, information_schema, performance_schema and sys",
                 check_databases, update_databases, "university_resources");

MYSQL_SYSVAR_STR(exclude_users, sv_exclude_users, PLUGIN_VAR_RQCMDARG,
                 "Comma-separated login names whose activity is not audited",
                 check_exclude_users, update_exclude_users, "");

MYSQL_SYSVAR_BOOL(log_reads, sv_log_reads, PLUGIN_VAR_OPCMDARG,
                  "Also audit read-only table access (SELECT). Off by default: reads "
                  "dominate log volume",
                  nullptr, update_log_reads, 0);

MYSQL_SYSVAR_ENUM(connections, sv_connections, PLUGIN_VAR_RQCMDARG,
                  "Connection events to audit: NONE, FAILED (failed logins and "
                  "change-user attempts) or ALL",
                  nullptr, update_connections, kConnFailed, &connection_mode_typelib);

MYSQL_SYSVAR_UINT(max_sql_length, sv_max_sql_length, PLUGIN_VAR_RQCMDARG,
                  "Maximum bytes of the literal-free statement digest; 0 disables digests",
                  nullptr, update_max_sql_length, 1024, 0, 8192, 0);

MYSQL_SYSVAR_BOOL(reopen_now, sv_reopen_now, PLUGIN_VAR_OPCMDARG | PLUGIN_VAR_NOCMDOPT,
                  "Set to ON to close and reopen the audit log (log rotation)",
                  nullptr, update_reopen_now, 0);

// Startup option.  On Linux, LOAD_FILE() (the project's import of the log)
// reads only files that are readable by all; the log directory must then keep
// other OS users out (the Docker image: 0750 mysql:mysql).  No effect on Windows.
MYSQL_SYSVAR_BOOL(readable_by_all, sv_readable_by_all, PLUGIN_VAR_OPCMDARG | PLUGIN_VAR_READONLY,
                  "Make audit log files readable by all OS users, as LOAD_FILE() requires; "
                  "protect their directory instead",
                  nullptr, nullptr, 0);

struct st_mysql_sys_var* system_variables[] = {
    MYSQL_SYSVAR(file_path),
    MYSQL_SYSVAR(databases),
    MYSQL_SYSVAR(exclude_users),
    MYSQL_SYSVAR(log_reads),
    MYSQL_SYSVAR(connections),
    MYSQL_SYSVAR(max_sql_length),
    MYSQL_SYSVAR(reopen_now),
    MYSQL_SYSVAR(readable_by_all),
    MYSQL_SYSVAR(stmt_query_id),
    nullptr
};

// ------------------------------------------------------------ status variables

int show_counter(struct st_mysql_show_var* var, void* buff, unsigned long long value) {
    var->type = SHOW_ULONGLONG;
    var->value = buff;
    *static_cast<unsigned long long*>(buff) = value;
    return 0;
}

int show_text(struct st_mysql_show_var* var, void* buff, const char* text) {
    var->type = SHOW_CHAR;
    var->value = buff;
    copy_bounded(static_cast<char*>(buff), SHOW_VAR_FUNC_BUFF_SIZE, text);
    return 0;
}

#define CAMPUS_AUDIT_COUNTER(fn, counter)                                              \
    int fn(MYSQL_THD, struct st_mysql_show_var* var, void* buff,                        \
           struct system_status_var*, enum enum_var_type) {                             \
        return show_counter(var, buff, counter.load());                                 \
    }

CAMPUS_AUDIT_COUNTER(show_written, st_written)
CAMPUS_AUDIT_COUNTER(show_dropped, st_dropped)
CAMPUS_AUDIT_COUNTER(show_write_failures, st_write_failures)
CAMPUS_AUDIT_COUNTER(show_open_failures, st_open_failures)
CAMPUS_AUDIT_COUNTER(show_bytes, st_bytes)
CAMPUS_AUDIT_COUNTER(show_filtered, st_filtered)
CAMPUS_AUDIT_COUNTER(show_unexpected, st_unexpected)
CAMPUS_AUDIT_COUNTER(show_reopens, st_reopens)

int show_state(MYSQL_THD, struct st_mysql_show_var* var, void* buff,
               struct system_status_var*, enum enum_var_type) {
    LockGuard<Mutex> guard(sink_lock);
    return show_text(var, buff, degraded ? "DEGRADED" : (sink.is_open() ? "ACTIVE" : "CLOSED"));
}

int show_file(MYSQL_THD, struct st_mysql_show_var* var, void* buff,
              struct system_status_var*, enum enum_var_type) {
    LockGuard<Mutex> guard(sink_lock);
    return show_text(var, buff, active_path);
}

int show_last_error(MYSQL_THD, struct st_mysql_show_var* var, void* buff,
                    struct system_status_var*, enum enum_var_type) {
    LockGuard<Mutex> guard(sink_lock);
    return show_text(var, buff, last_error);
}

struct st_mysql_show_var status_variables[] = {
    {"campus_audit_state", reinterpret_cast<void*>(&show_state), SHOW_SIMPLE_FUNC},
    {"campus_audit_file", reinterpret_cast<void*>(&show_file), SHOW_SIMPLE_FUNC},
    {"campus_audit_last_error", reinterpret_cast<void*>(&show_last_error), SHOW_SIMPLE_FUNC},
    {"campus_audit_events_written", reinterpret_cast<void*>(&show_written), SHOW_SIMPLE_FUNC},
    {"campus_audit_events_dropped", reinterpret_cast<void*>(&show_dropped), SHOW_SIMPLE_FUNC},
    {"campus_audit_events_filtered", reinterpret_cast<void*>(&show_filtered), SHOW_SIMPLE_FUNC},
    {"campus_audit_events_unexpected", reinterpret_cast<void*>(&show_unexpected), SHOW_SIMPLE_FUNC},
    {"campus_audit_write_failures", reinterpret_cast<void*>(&show_write_failures), SHOW_SIMPLE_FUNC},
    {"campus_audit_open_failures", reinterpret_cast<void*>(&show_open_failures), SHOW_SIMPLE_FUNC},
    {"campus_audit_reopens", reinterpret_cast<void*>(&show_reopens), SHOW_SIMPLE_FUNC},
    {"campus_audit_bytes_written", reinterpret_cast<void*>(&show_bytes), SHOW_SIMPLE_FUNC},
    {nullptr, nullptr, SHOW_UNDEF}
};

// ------------------------------------------------------------ init / deinit

const char* connection_mode_name() {
    const unsigned long mode = runtime_config.connections.load(std::memory_order_relaxed);
    return mode < 3 ? connection_mode_names[mode] : "?";
}

int campus_audit_init(void*) {
    // Plugin option values are stable during init. Publish an atomic runtime
    // copy before event callbacks can observe the plugin.
    runtime_config.log_reads.store(sv_log_reads != 0, std::memory_order_relaxed);
    runtime_config.connections.store(sv_connections, std::memory_order_relaxed);
    runtime_config.max_sql_length.store(sv_max_sql_length, std::memory_order_relaxed);
    // Option values from my.cnf / the command line do not pass through the
    // check functions above, so everything is validated again here.
    NameList dbs, users;
    AuditResult r = campus_audit::parse_name_list(sv_databases, NameKind::Database, &dbs);
    if (r.ok()) r = campus_audit::parse_name_list(sv_exclude_users, NameKind::User, &users);
    if (!r.ok()) {
        r.message = "invalid configuration, plugin not started: " + r.message;
        report_to_server(r);
        return 1;
    }
    {
        LockGuard<Mutex> guard(sink_lock);
        sink.set_readable_by_all(sv_readable_by_all != 0);   // read-only: fixed until restart
        r = sink.open(sv_file_path);
        if (r.ok()) copy_bounded(active_path, sizeof(active_path), sv_file_path);
    }
    if (!r.ok()) {
        ++st_open_failures;
        r.message = "plugin not started: " + r.message;
        report_to_server(r);
        return 1;
    }
    filter_lock.write_lock();
    db_filter = dbs;
    user_filter = users;
    filter_lock.write_unlock();

    long long s;
    long us;
    campus_audit::wall_clock(&s, &us);
    std::snprintf(instance_id, sizeof(instance_id), "%llx-%lx",
                  static_cast<unsigned long long>(s) * 1000000ULL + static_cast<unsigned long long>(us),
                  campus_audit::process_id());

    char buf[4096];
    JsonWriter w(buf, sizeof(buf));
    begin_record(w, "plugin_start");
    w.field_cstring("version", kPluginVersion);
    w.field_cstring("file_path", sv_file_path, kMaxPathLength);
    w.field_cstring("databases", sv_databases, 2048);
    w.field_cstring("exclude_users", sv_exclude_users, 2048);
    w.field_bool("log_reads", sv_log_reads != 0);
    w.field_cstring("connections", connection_mode_name());
    w.field_uint("max_sql_length", sv_max_sql_length);
    w.field_bool("readable_by_all", sv_readable_by_all != 0);
    w.end_object();
    write_record(w, false);
    initialized = true;
    return 0;
}

int campus_audit_deinit(void*) {
    // The server also calls deinit after init() has failed (observed with
    // 13.0.2: finalize_audit_plugin() runs for the failed plugin), so only
    // an initialized plugin writes plugin_stop.
    if (!initialized.exchange(false)) return 0;
    char buf[1024];
    JsonWriter w(buf, sizeof(buf));
    begin_record(w, "plugin_stop");
    w.field_uint("events_written", st_written.load());
    w.field_uint("events_dropped", st_dropped.load());
    w.end_object();
    write_record(w, false);
    LockGuard<Mutex> guard(sink_lock);
    sink.close();
    degraded = false;
    return 0;
}

struct st_mysql_audit campus_audit_descriptor = {
    MYSQL_AUDIT_INTERFACE_VERSION,
    nullptr,  // release_thd: the plugin keeps no per-THD resources to release
    campus_audit_notify,
    {MYSQL_AUDIT_GENERAL_CLASSMASK | MYSQL_AUDIT_CONNECTION_CLASSMASK | MYSQL_AUDIT_TABLE_CLASSMASK}
};

}  // namespace

maria_declare_plugin(campus_audit)
{
    MYSQL_AUDIT_PLUGIN,
    &campus_audit_descriptor,
    "campus_audit",
    "DB_Project_2026 team, Constructor University",
    "Structured JSON Lines audit of table access, DDL and logins for watched schemas",
    PLUGIN_LICENSE_GPL,
    campus_audit_init,
    campus_audit_deinit,
    0x0101,
    status_variables,
    system_variables,
    kPluginVersion,
    MariaDB_PLUGIN_MATURITY_BETA
}
maria_declare_plugin_end;
