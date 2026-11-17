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
 */
#include <mysql.h>
#include <stdio.h>
#include <stdlib.h>

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
