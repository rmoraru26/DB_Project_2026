#!/usr/bin/env bash
# Post-audit: plugin harness and database test scripts of this checkout, in a
# throw-away server from the stack image, with this checkout's plugin build and
# migrations 007, 008 and catalogue.sql applied as `make migrate` would.
set -u
# Random throw-away passwords, never printed; they exist only in the container
# this script starts and removes.  (Literal throw-away values were used when the
# recorded runs were made; replaced afterwards, behaviour unchanged.)
rand_pw() { printf '%s%s' "$1" "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
ROOT_PW=$(rand_pw r); APP_PW=$(rand_pw a)
IMAGE=$1; SO=$2; N=frt-postaudit-db-$$
trap 'docker rm -f -v $N >/dev/null 2>&1' EXIT
MSYS_NO_PATHCONV=1 docker run -d --name $N -e MARIADB_ROOT_PASSWORD="$ROOT_PW" -e CAMPUS_APP_PASSWORD="$APP_PW" "$IMAGE" >/dev/null
for i in $(seq 1 90); do r=$(docker exec -e MYSQL_PWD="$ROOT_PW" $N mariadb -uroot -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='campus_app'" 2>/dev/null | tr -d '\r'); [ "$r" = 1 ] && break; sleep 2; done; sleep 8
tar --exclude='*.jsonl' -cf - database scripts tests | MSYS_NO_PATHCONV=1 docker exec -i $N bash -c 'mkdir -p /opt/checkout && tar -C /opt/checkout -xf - && find /opt/checkout -type f \( -name "*.sh" -o -name "*.sql" \) -exec sed -i "s/\r$//" {} +'
docker cp "$SO" $N:/usr/lib/mysql/plugin/campus_audit.so >/dev/null
docker exec -i -e MYSQL_PWD="$ROOT_PW" $N bash -s <<'EOF' 2>&1
cd /opt/checkout
mariadb -uroot -e "INSTALL SONAME 'campus_audit';"
echo "plugin: $(mariadb -uroot -N -e "SELECT CONCAT(PLUGIN_STATUS, ' ', PLUGIN_AUTH_VERSION) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit'")"
for f in database/migrations/007_local_demo_student.sql database/catalogue.sql; do
  mariadb -uroot < "$f" && echo "applied $f" || echo "FAILED to apply $f"
done
export MARIADB_CLIENT=mariadb DB_ADMIN_USER=root AUDIT_TEST_DIR=/var/log/campus_audit/ CHANGE_USER_CLIENT=/usr/local/bin/campus_change_user CU_HOST=127.0.0.1 CU_PORT=3306
overall=0
for t in tests/database/test_demo_student.sh tests/database/test_catalogue.sh; do
  echo; echo "######## $t"; bash "$t"; s=$?; echo "######## $t: exit status $s"; [ $s -eq 0 ] || overall=1
done
echo; echo "######## overall exit status $overall"; exit $overall
EOF
