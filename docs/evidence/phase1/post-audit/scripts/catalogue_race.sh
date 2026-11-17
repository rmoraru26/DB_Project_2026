#!/usr/bin/env bash
# Post-audit experiment: two concurrent runs of catalogue.sql's room INSERT on an empty scratch copy of rooms.
set -u
IMAGE=$1; CATALOGUE=$2; N=frt-postaudit-cat-$$
trap 'docker rm -f -v $N >/dev/null 2>&1' EXIT
MSYS_NO_PATHCONV=1 docker run -d --name $N -e MARIADB_ROOT_PASSWORD=expRootPw12345 -e CAMPUS_APP_PASSWORD=expAppPw123456 "$IMAGE" >/dev/null
for i in $(seq 1 90); do r=$(docker exec -e MYSQL_PWD=expRootPw12345 $N mariadb -uroot -N -e "SELECT COUNT(*) FROM university_resources.users WHERE email='alice.student@example.edu'" 2>/dev/null | tr -d '\r'); [ "$r" = 1 ] && break; sleep 2; done; sleep 8
tr -d '\r' < "$CATALOGUE" | MSYS_NO_PATHCONV=1 docker exec -i $N bash -c 'cat > /tmp/catalogue.sql'
docker exec -i -e MYSQL_PWD=expRootPw12345 $N bash -s <<'EOF' 2>&1
q(){ printf '%s\n' "$1" | mariadb -uroot --batch --skip-column-names --force 2>&1; }
# The rooms statement of catalogue.sql, pointed at a scratch schema.
stmt=$(awk '/^INSERT INTO rooms/,/^ORDER BY c.position;/' /tmp/catalogue.sql)
for iso in "REPEATABLE READ" "READ COMMITTED"; do
  q "DROP DATABASE IF EXISTS cat_exp; CREATE DATABASE cat_exp; CREATE TABLE cat_exp.rooms LIKE university_resources.rooms;"
  ( q "SET SESSION TRANSACTION ISOLATION LEVEL $iso; USE cat_exp; START TRANSACTION; $stmt SELECT SLEEP(4); COMMIT;" | sed 's/^/  A: /' ) &
  sleep 1
  ( q "SET SESSION TRANSACTION ISOLATION LEVEL $iso; SET SESSION innodb_lock_wait_timeout = 20; USE cat_exp; START TRANSACTION; $stmt COMMIT;" | sed 's/^/  B: /' ) &
  wait
  echo "== $iso: rooms=$(q 'SELECT COUNT(*) FROM cat_exp.rooms;') distinct names=$(q 'SELECT COUNT(DISTINCT name) FROM cat_exp.rooms;')"
done
EOF
