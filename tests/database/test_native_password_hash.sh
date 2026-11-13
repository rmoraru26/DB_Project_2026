#!/usr/bin/env bash
# Checks database/native_password_hash.sh against the server itself:
#   1. for many random passwords the hash equals SELECT PASSWORD('...');
#   2. an account created with IDENTIFIED BY PASSWORD '<hash>' (the way
#      database/app_account.sh creates campus_app) accepts the plain password.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_native_password_hash.sh
#
# ADMINISTRATOR ACCESS (creates and drops one throwaway account).

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
ROUNDS=${HASH_TEST_ROUNDS:-100}
PASS=0
FAIL=0

sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }
sql_literal() { local s=${1//\\/\\\\}; s=${s//\'/\\\'}; printf "'%s'" "$s"; }
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Printable ASCII including quote, backslash, percent and space, so that
# both the shell side and the SQL side meet the awkward characters.
charset=' !"#$%&()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'"'"
mismatches=0
for i in $(seq 1 "$ROUNDS"); do
    len=$((RANDOM % 40 + 1))
    pw=""
    for _ in $(seq 1 "$len"); do pw+="${charset:RANDOM % ${#charset}:1}"; done
    ours=$(printf '%s' "$pw" | bash database/native_password_hash.sh)
    server=$(sql "SELECT PASSWORD($(sql_literal "$pw"));")
    if [ "$ours" != "$server" ]; then
        mismatches=$((mismatches + 1))
        [ "$mismatches" -le 3 ] && echo "      mismatch for a password of length $len: ours=$ours server=$server"
    fi
done
if [ "$mismatches" -eq 0 ]; then
    pass "hash equals PASSWORD() for $ROUNDS random passwords (quotes, backslashes, %, spaces)"
else
    fail "hash differs from PASSWORD() for $mismatches of $ROUNDS passwords"
fi

user="pwhash_test_$$"
pw="t$(date +%s)_Pw.$RANDOM-x"
hash=$(printf '%s' "$pw" | bash database/native_password_hash.sh)
sql "CREATE USER '$user'@'%' IDENTIFIED BY PASSWORD '$hash';"
if [ "$(printf 'SELECT 1;\n' | MYSQL_PWD="$pw" "${CLIENT[@]}" -u"$user" --batch --skip-column-names 2>&1)" = "1" ]; then
    pass "account created from the hash accepts the plain password"
else
    fail "account created from the hash accepts the plain password"
fi
if printf 'SELECT 1;\n' | MYSQL_PWD="${pw}x" "${CLIENT[@]}" -u"$user" --batch 2>&1 | grep -q "ERROR 1045"; then
    pass "a wrong password is still rejected (ER 1045)"
else
    fail "a wrong password is still rejected (ER 1045)"
fi
sql "DROP USER '$user'@'%';"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
