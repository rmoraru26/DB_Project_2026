// skeleton_audit: the smallest useful MariaDB audit plugin.
//
// It counts the audit events the server hands it, per event class, and shows
// the counts as status variables:
//
//   INSTALL SONAME 'skeleton_audit';
//   SHOW GLOBAL STATUS LIKE 'skeleton\_audit\_%';
//
// Everything campus_audit adds (filters, JSON records, a log file, failure
// handling, configuration) is left out, so the three parts every audit plugin
// needs are easy to see: (1) the callback, (2) the descriptor that subscribes
// it to event classes, (3) the declaration the server reads when it opens the
// library.  Walkthrough: examples/skeleton_plugin/README.md.

#include <mysql/plugin.h>
#include <mysql/plugin_audit.h>

// Counters shown as status variables.  The server calls the callback from
// many connection threads at once, hence the atomic increments.
static unsigned long long general_events = 0;
static unsigned long long connection_events = 0;
static unsigned long long table_events = 0;

static void count(unsigned long long* counter) {
    __atomic_add_fetch(counter, 1, __ATOMIC_RELAXED);
}

// (1) The callback.  The server calls it synchronously, in the thread of the
// session that caused the event, for every event of a subscribed class.  It
// returns void: an audit plugin can observe a statement but never refuse it.
// `event` points to a class-specific struct (mysql_event_general,
// mysql_event_connection, mysql_event_table in mysql/plugin_audit.h) that is
// valid only during this call.
static void skeleton_notify(MYSQL_THD thd, unsigned int event_class, const void* event) {
    (void)thd;
    (void)event;
    switch (event_class) {
    case MYSQL_AUDIT_GENERAL_CLASS:    count(&general_events); break;
    case MYSQL_AUDIT_CONNECTION_CLASS: count(&connection_events); break;
    case MYSQL_AUDIT_TABLE_CLASS:      count(&table_events); break;
    }
}

// (2) The audit descriptor: interface version, an optional release_thd hook,
// the callback, and the bit mask of the event classes to receive.
static struct st_mysql_audit skeleton_descriptor = {
    MYSQL_AUDIT_INTERFACE_VERSION,
    nullptr,
    skeleton_notify,
    {MYSQL_AUDIT_GENERAL_CLASSMASK | MYSQL_AUDIT_CONNECTION_CLASSMASK | MYSQL_AUDIT_TABLE_CLASSMASK}
};

// Status variables: name, address, type.  SHOW GLOBAL STATUS reads them.
static struct st_mysql_show_var skeleton_status[] = {
    {"skeleton_audit_general_events", &general_events, SHOW_ULONGLONG},
    {"skeleton_audit_connection_events", &connection_events, SHOW_ULONGLONG},
    {"skeleton_audit_table_events", &table_events, SHOW_ULONGLONG},
    {nullptr, nullptr, SHOW_UNDEF}
};

// init runs at INSTALL SONAME and at every server start, deinit at UNINSTALL
// and shutdown.  A non-zero return from init refuses the load.
static int skeleton_init(void*) { return 0; }
static int skeleton_deinit(void*) { return 0; }

// Compile with -DSKELETON_EXPERIMENTAL to see the server refuse a plugin whose
// maturity is below plugin_maturity (README, step 5).
#ifdef SKELETON_EXPERIMENTAL
#define SKELETON_MATURITY MariaDB_PLUGIN_MATURITY_EXPERIMENTAL
#else
#define SKELETON_MATURITY MariaDB_PLUGIN_MATURITY_BETA
#endif

// (3) The declaration.  maria_declare_plugin defines the symbols the server
// looks up when it opens the library: the plugin interface version, the size
// of the struct below, and this table of plugins (a library may hold several).
maria_declare_plugin(skeleton_audit)
{
    MYSQL_AUDIT_PLUGIN,          // plugin type
    &skeleton_descriptor,        // type-specific descriptor
    "skeleton_audit",            // name in INSTALL PLUGIN and information_schema.PLUGINS
    "FRANtastic",                // author
    "Counts audit events per class (tutorial skeleton)",
    PLUGIN_LICENSE_GPL,          // the server headers are GPL
    skeleton_init,
    skeleton_deinit,
    0x0100,                      // version 1.0, shown as PLUGIN_VERSION
    skeleton_status,             // status variables
    nullptr,                     // system variables: none
    "1.0",                       // version string, shown as PLUGIN_AUTH_VERSION
    SKELETON_MATURITY
}
maria_declare_plugin_end;
