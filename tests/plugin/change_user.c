/*
 * campus_change_user: issues COM_CHANGE_USER through the MariaDB C API
 * (mysql_change_user), which the mariadb command-line client cannot send,
 * so that tests/plugin/run_plugin_tests.sh can check the plugin's
 * change_user / change_user_failed records.
 *
 *   CU_PW1=<password of user1> CU_PW2=<password of user2> \
 *       campus_change_user <user1> <user2>
 *
 * Connects to CU_HOST:CU_PORT if CU_HOST is set, otherwise to the local
 * socket (the Docker image runs it inside the server container).  Passwords
 * come from the environment, never from the command line.
 *
 * Output, one line each:
 *   CONN <id>              CONNECTION_ID() after logging in as user1
 *   CHANGE_OK <account>    mysql_change_user(user2, CU_PW2) succeeded; CURRENT_USER()
 *   CHANGE_ERROR <errno>   ... it failed (unexpected)
 *   CHANGE_FAILED <errno>  mysql_change_user(user1, <wrong password>) failed (expected)
 *   CHANGE_UNEXPECTED_OK   ... it succeeded (unexpected)
 * Exit status 0 when both calls behaved as expected.
 *
 * Second mode: prepared statements over the binary protocol (COM_STMT_PREPARE
 * and COM_STMT_EXECUTE), which the mariadb client cannot send either.
 *
 *   CU_PW1=<password> campus_change_user --prepared <user> <schema> <table>
 *
 * Connects with <schema> as the default schema, prepares
 * "INSERT INTO <table> VALUES (?, ?)", executes it with (9001, 1) and
 * (9002, 1), executes (9001, 1) once more (duplicate key, expected to fail),
 * closes the statement and finally sends one plain COM_QUERY
 * "SET @campus_after_prepared = 1" that touches no table.  Output:
 *   CONN <id>
 *   EXEC_OK <id>           an execution that succeeded (twice)
 *   EXEC_FAILED <errno>    the duplicate (expected, 1062)
 *   QUERY_OK               the final SET
 * Exit status 0 when every step behaved as expected.  The table must have two
 * INT columns and must not contain the ids 9001 and 9002.
 */
#include <mysql.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Executes the prepared INSERT with (id, 1); returns 0 or the error number. */
static unsigned int execute_insert(MYSQL_STMT *stmt, int id)
{
    int value = 1;
    MYSQL_BIND bind[2];
    memset(bind, 0, sizeof(bind));
    bind[0].buffer_type = MYSQL_TYPE_LONG;
    bind[0].buffer = &id;
    bind[1].buffer_type = MYSQL_TYPE_LONG;
    bind[1].buffer = &value;
    if (mysql_stmt_bind_param(stmt, bind) != 0 || mysql_stmt_execute(stmt) != 0)
        return mysql_stmt_errno(stmt) ? mysql_stmt_errno(stmt) : 1;
    return 0;
}

static int run_prepared(const char *host, unsigned int port, const char *user, const char *pw,
                        const char *schema, const char *table)
{
    char sql[256];
    my_bool no_verify = 0;
    MYSQL_STMT *stmt;
    unsigned int rc;
    int ok = 1;
    MYSQL *m = mysql_init(NULL);
    if (!m) {
        fprintf(stderr, "mysql_init failed\n");
        return 2;
    }
    mysql_optionsv(m, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &no_verify);
    if (!mysql_real_connect(m, host, user, pw, schema, port, NULL, 0)) {
        printf("CONNECT_FAILED %u %s\n", mysql_errno(m), mysql_error(m));
        mysql_close(m);
        return 2;
    }
    printf("CONN %lu\n", mysql_thread_id(m));
    if (snprintf(sql, sizeof(sql), "INSERT INTO %s VALUES (?, ?)", table) >= (int)sizeof(sql)
        || (stmt = mysql_stmt_init(m)) == NULL) {
        mysql_close(m);
        return 2;
    }
    if (mysql_stmt_prepare(stmt, sql, (unsigned long)strlen(sql)) != 0) {
        printf("PREPARE_FAILED %u\n", mysql_stmt_errno(stmt));
        mysql_stmt_close(stmt);
        mysql_close(m);
        return 1;
    }
    if ((rc = execute_insert(stmt, 9001)) == 0) printf("EXEC_OK 9001\n"); else { printf("EXEC_ERROR %u\n", rc); ok = 0; }
    if ((rc = execute_insert(stmt, 9002)) == 0) printf("EXEC_OK 9002\n"); else { printf("EXEC_ERROR %u\n", rc); ok = 0; }
    if ((rc = execute_insert(stmt, 9001)) != 0) printf("EXEC_FAILED %u\n", rc); else { printf("EXEC_UNEXPECTED_OK\n"); ok = 0; }
    mysql_stmt_close(stmt);
    if (mysql_query(m, "SET @campus_after_prepared = 1") == 0) printf("QUERY_OK\n");
    else { printf("QUERY_ERROR %u\n", mysql_errno(m)); ok = 0; }
    fflush(stdout);
    mysql_close(m);
    return ok ? 0 : 1;
}

static int print_current_user(MYSQL *m)
{
    MYSQL_RES *res;
    MYSQL_ROW row;
    if (mysql_query(m, "SELECT CURRENT_USER()") != 0 || (res = mysql_store_result(m)) == NULL)
        return 0;
    row = mysql_fetch_row(res);
    printf("CHANGE_OK %s\n", row && row[0] ? row[0] : "?");
    mysql_free_result(res);
    return 1;
}

int main(int argc, char **argv)
{
    const char *host = getenv("CU_HOST");
    const char *port_text = getenv("CU_PORT");
    const char *pw1 = getenv("CU_PW1");
    const char *pw2 = getenv("CU_PW2");
    unsigned int port = port_text ? (unsigned int)strtoul(port_text, NULL, 10) : 0;
    my_bool no_verify = 0;
    int ok = 1;
    MYSQL *m;

    setvbuf(stdout, NULL, _IONBF, 0);   /* each line reaches a pipe at once */
    if (argc == 5 && strcmp(argv[1], "--prepared") == 0) {
        if (!pw1) {
            fprintf(stderr, "usage: CU_PW1=... %s --prepared <user> <schema> <table>\n", argv[0]);
            return 2;
        }
        return run_prepared(host, port, argv[2], pw1, argv[3], argv[4]);
    }
    if (argc != 3 || !pw1 || !pw2) {
        fprintf(stderr, "usage: CU_PW1=... CU_PW2=... %s <user1> <user2>\n", argv[0]);
        return 2;
    }
    m = mysql_init(NULL);
    if (!m) {
        fprintf(stderr, "mysql_init failed\n");
        return 2;
    }
    /* Test helper for a local disposable server with a self-signed
       certificate: do not insist on verifying it. */
    mysql_optionsv(m, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &no_verify);
    if (!mysql_real_connect(m, host, argv[1], pw1, NULL, port, NULL, 0)) {
        printf("CONNECT_FAILED %u %s\n", mysql_errno(m), mysql_error(m));
        mysql_close(m);
        return 2;
    }
    printf("CONN %lu\n", mysql_thread_id(m));

    if (mysql_change_user(m, argv[2], pw2, NULL) == 0) {
        if (!print_current_user(m))
            printf("CHANGE_OK ?\n");
    } else {
        printf("CHANGE_ERROR %u\n", mysql_errno(m));
        ok = 0;
    }

    /* Back to user1 with a wrong password: the target differs from the
       current account, so the test can tell which one the event reports. */
    if (mysql_change_user(m, argv[1], "campus-audit-wrong-password", NULL) != 0) {
        printf("CHANGE_FAILED %u\n", mysql_errno(m));
    } else {
        printf("CHANGE_UNEXPECTED_OK\n");
        ok = 0;
    }
    fflush(stdout);
    mysql_close(m);
    return ok ? 0 : 1;
}
