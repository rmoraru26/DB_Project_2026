#!/usr/bin/env bash
# Post-audit experiment: case of system schema names (13.0.2, lower_case_table_names=0).
set -u
SO=$1; IMAGE=$2; N=frt-postaudit-schema-$$
trap 'docker rm -f -v $N >/dev/null 2>&1' EXIT
MSYS_NO_PATHCONV=1 docker run -d --name $N -e MARIADB_ROOT_PASSWORD=expRootPw12345 -e CAMPUS_APP_PASSWORD=expAppPw123456 "$IMAGE" >/dev/null
for i in $(seq 1 90); do r=$(docker exec -e MYSQL_PWD=expRootPw12345 $N mariadb -uroot -N -e "SELECT COUNT(*) FROM university_resources.users WHERE email='alice.student@example.edu'" 2>/dev/null | tr -d '\r'); [ "$r" = 1 ] && break; sleep 2; done; sleep 8
run() {
docker exec -i -e MYSQL_PWD=expRootPw12345 $N bash -s <<'EOF' 2>&1
L=/var/log/campus_audit/campus_audit.jsonl
q(){ printf '%s\n' "$1" | mariadb -uroot --batch --skip-column-names --force 2>&1; }
q "SELECT CONCAT('plugin ', PLUGIN_AUTH_VERSION, ', lower_case_table_names=', @@lower_case_table_names, ', ', @@version) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';"
q "SET GLOBAL campus_audit_databases='*'; SET GLOBAL campus_audit_log_reads=ON;"
before=$(wc -l < $L)
q "CREATE DATABASE IF NOT EXISTS \`MySQL\`; CREATE DATABASE IF NOT EXISTS \`Sys\`; CREATE TABLE IF NOT EXISTS \`MySQL\`.t (id INT); CREATE TABLE IF NOT EXISTS \`Sys\`.t (id INT);" >/dev/null
q "INSERT INTO \`MySQL\`.t VALUES (1); INSERT INTO \`Sys\`.t VALUES (1); UPDATE university_resources.rooms SET capacity=capacity WHERE room_id=0;"
echo "name resolution: INFORMATION_SCHEMA=$(q 'SELECT COUNT(*) > 0 FROM INFORMATION_SCHEMA.SCHEMATA;') Performance_Schema=$(q 'SELECT COUNT(*) >= 0 FROM Performance_Schema.threads;') | $(q 'SELECT COUNT(*) FROM MYSQL.user;' | tail -1) | $(q 'SELECT COUNT(*) FROM SYS.version;' | tail -1)"
q "SELECT COUNT(*) FROM mysql.user; SELECT COUNT(*) FROM performance_schema.threads; SELECT COUNT(*) FROM PERFORMANCE_SCHEMA.threads;" >/dev/null
tail -n +$((before + 1)) $L > /tmp/new.jsonl
for db in MySQL Sys university_resources mysql sys performance_schema PERFORMANCE_SCHEMA; do
  echo "table records for db=$db: $(grep '"event":"table_' /tmp/new.jsonl | grep -c "\"db\":\"$db\",")"
done
EOF
}
docker exec -e MYSQL_PWD=expRootPw12345 $N mariadb -uroot -e "INSTALL SONAME 'campus_audit';"
echo "== 1. plugin from the image (Phase 1 tree before this fix)"; run
docker exec -e MYSQL_PWD=expRootPw12345 $N mariadb -uroot -e "UNINSTALL SONAME 'campus_audit';"
docker cp "$SO" $N:/usr/lib/mysql/plugin/campus_audit.so >/dev/null
docker exec -e MYSQL_PWD=expRootPw12345 $N mariadb -uroot -e "INSTALL SONAME 'campus_audit';"
echo; echo "== 2. plugin built from the post-audit working tree"; run
