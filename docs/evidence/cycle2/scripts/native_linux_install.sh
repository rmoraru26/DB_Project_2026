#!/usr/bin/env bash
# Verifies README "Building and installing the plugin yourself" on Linux without the project's
# Docker build or Compose stack: a plain Ubuntu system with the MariaDB 13.0.2 packages (the
# official image the project pins, started as a bare container whose entrypoint is NOT used),
# following the README's commands in order:
#
#   1. install the toolchain and the headers of the server's version (apt);
#   2. make -C plugin test, make -C plugin;
#   3. copy campus_audit.so to @@plugin_dir; plugin_maturity=beta and
#      loose_campus_audit_readable_by_all=ON under [mysqld]; a log directory only the server's
#      account can enter; restart;
#   4. scripts/setup_database.sh, scripts/demo.sh;
#   5. the README's verification SQL;
#   6. the end-to-end harness (with the CHANGE_USER / prepared-statement helper built natively);
#   7. the web application outside Docker: pip install -r requirements.txt, python frontend/app.py,
#      then GET /healthz and /.
#
# Run from the repository root (Git Bash or Linux):
#   bash docs/evidence/cycle2/scripts/native_linux_install.sh <output file>
# The container and its data are removed at the end.  Passwords are random and never printed.
set -u
OUT=${1:?output file}
IMAGE="mariadb:13.0.2-resolute@sha256:0e4bb0f339feba125d1154fbacd36c16ec8518f52e44e1f82ecec7d6771caf39"
N=frt-native-linux-$$
export MSYS_NO_PATHCONV=1
trap 'docker rm -f -v $N >/dev/null 2>&1' EXIT
docker run -d --name $N --entrypoint sleep "$IMAGE" infinity >/dev/null || exit 2
git ls-files -co --exclude-standard | grep -vxF -f <(git ls-files -d) | tar -T - -cf - \
    | docker exec -i $N bash -c 'mkdir -p /src && tar -C /src -xf - && find /src -name "*.sh" -exec sed -i "s/\r$//" {} +'
rh() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
docker exec -i -e ROOT_PW="r$(rh)" -e APP_PW="a$(rh)" -e SECRET="s$(rh)$(rh)" $N bash -s > "$OUT" 2>&1 <<'EOF'
set -u
export DEBIAN_FRONTEND=noninteractive
cd /src
step() { local name=$1; shift; echo; echo "######## $name: $*"; "$@"; local s=$?; echo "######## $name: exit status $s"; return $s; }
echo "# $(date -u +%FT%TZ) $(. /etc/os-release; echo "$PRETTY_NAME"), $(mariadbd --version), package version $MARIADB_VERSION"

echo; echo "######## 1. toolchain and the headers of the server's version"
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gcc g++ make \
    "libmariadbd-dev=$MARIADB_VERSION" "libmariadb-dev=$MARIADB_VERSION" python3 python3-venv curl >/dev/null
echo "######## 1: exit status $?; headers: $(ls /usr/include/mariadb/server/mysql/plugin_audit.h)"

step "2a" make -C plugin test 2>&1 | tail -n 4
step "2b" make -C plugin 2>&1 | tail -n 2
ls -l plugin/build/campus_audit.so

echo; echo "######## 3. server: data directory, start, root password"
mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1; echo "install-db exit $?"
start_server() { (mariadbd --user=mysql > /tmp/mariadbd.log 2>&1 &); for _ in $(seq 1 60); do mariadb-admin ping >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
start_server && echo "server up"
mariadb -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_PW'; CREATE USER 'root'@'127.0.0.1' IDENTIFIED BY '$ROOT_PW'; GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;"
export MYSQL_PWD="$ROOT_PW"
plugin_dir=$(mariadb -uroot -N -e "SELECT @@plugin_dir")
cp plugin/build/campus_audit.so "$plugin_dir" && echo "copied to $plugin_dir"
mkdir -p /var/log/campus_audit && chown mysql:mysql /var/log/campus_audit && chmod 0750 /var/log/campus_audit
cat > /etc/mysql/conf.d/zz-campus-audit.cnf <<'CNF'
[mysqld]
plugin_maturity = beta
loose_campus_audit_readable_by_all = ON
loose_campus_audit_file_path = /var/log/campus_audit/campus_audit.jsonl
CNF
echo "option file:"; sed 's/^/    /' /etc/mysql/conf.d/zz-campus-audit.cnf
mariadb-admin -uroot shutdown; sleep 3; start_server && echo "server restarted: maturity $(mariadb -uroot -N -e 'SELECT @@plugin_maturity')"

export MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306 --skip-ssl-verify-server-cert"
step "4a" env CAMPUS_APP_PASSWORD="$APP_PW" bash scripts/setup_database.sh 2>&1 | tail -n 4
step "4b" bash scripts/demo.sh 2>&1 | tail -n 6

echo; echo "######## 5. verification SQL from the README"
mariadb -uroot -e "SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY, PLUGIN_AUTH_VERSION, PLUGIN_MATURITY FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';"
echo "system variables: $(mariadb -uroot -N -e "SHOW GLOBAL VARIABLES LIKE 'campus_audit%'" | wc -l)"
echo "status variables: $(mariadb -uroot -N -e "SHOW GLOBAL STATUS LIKE 'Campus_audit%'" | wc -l); $(mariadb -uroot -N -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Campus_audit_state','Campus_audit_events_dropped')" | tr '\t\n' '= ')"
echo "log: $(stat -c '%U:%G %a' /var/log/campus_audit/campus_audit.jsonl), $(wc -l < /var/log/campus_audit/campus_audit.jsonl) records"

gcc -O2 -Wall -o /usr/local/bin/campus_change_user tests/plugin/change_user.c $(mariadb_config --cflags --libs)
step "6" env AUDIT_TEST_DIR=/var/log/campus_audit/ CHANGE_USER_CLIENT=/usr/local/bin/campus_change_user CU_HOST=127.0.0.1 CU_PORT=3306 \
    bash tests/plugin/run_plugin_tests.sh 2>&1 | grep -E "^(FAIL|SKIP|== )"

echo; echo "######## 7. web application outside Docker"
python3 -m venv /opt/app && /opt/app/bin/pip install -q -r requirements.txt >/dev/null 2>&1; echo "pip exit $?"
(cd frontend && DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=campus_app DB_PASSWORD="$APP_PW" SECRET_KEY="$SECRET" \
    /opt/app/bin/python app.py > /tmp/app.log 2>&1 &)
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:5080/healthz && break; sleep 1; done
echo "GET /healthz -> $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5080/healthz)  body: $(curl -s http://127.0.0.1:5080/healthz | head -c 200)"
echo "GET /        -> $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5080/)"
echo "GET /lab     -> $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5080/lab)"
echo; echo "# done $(date -u +%FT%TZ)"
EOF
grep -E "^######## .*exit status|^server|copied|maturity|campus_audit	|variables:|^log:|^== |^FAIL|GET /" "$OUT"
