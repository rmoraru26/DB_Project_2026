#!/usr/bin/env bash
# Post-audit experiments on MariaDB 13.0.2 (throw-away container):
#   A. LOAD_FILE() and max_allowed_packet;  B. check_constraint_checks;
#   C. P2-1: does any event sequence leave the plugin's "pending statement"
#      (stmt_query_id) set, so that scope SESSION suppresses the next
#      table-less statement?  Probe: after each sequence `SET @<probe>=1` must
#      be recorded (default schema watched, scope SESSION).
set -u
# Random throw-away passwords, never printed; they exist only in the container
# this script starts and removes.  (Literal throw-away values were used when the
# recorded runs were made; replaced afterwards, behaviour unchanged.)
rand_pw() { printf '%s%s' "$1" "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
ROOT_PW=$(rand_pw r); APP_PW=$(rand_pw a); USER_PW=$(rand_pw u)
IMAGE=$1; SO=$2; N=frt-postaudit-probes-$$
trap 'docker rm -f -v $N >/dev/null 2>&1' EXIT
MSYS_NO_PATHCONV=1 docker run -d --name $N -e MARIADB_ROOT_PASSWORD="$ROOT_PW" -e CAMPUS_APP_PASSWORD="$APP_PW" "$IMAGE" >/dev/null
for i in $(seq 1 90); do
    r=$(docker exec -e MYSQL_PWD="$ROOT_PW" $N mariadb -uroot -N -e "SELECT COUNT(*) FROM university_resources.users WHERE email='alice.student@example.edu'" 2>/dev/null | tr -d '\r')
    [ "$r" = 1 ] && break; sleep 2
done
sleep 8
docker cp "$SO" $N:/usr/lib/mysql/plugin/campus_audit.so >/dev/null
docker exec -i -e MYSQL_PWD="$ROOT_PW" -e EXP_USER_PW="$USER_PW" $N bash -s 2>&1 <<'EOF'
q(){ printf '%s\n' "$1" | mariadb -uroot --batch --skip-column-names --force 2>&1; }
L=/var/log/campus_audit/campus_audit.jsonl; D=/var/log/campus_audit
q "INSTALL SONAME 'campus_audit';"
q "SELECT CONCAT('server ', @@version, ', plugin ', PLUGIN_AUTH_VERSION) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='campus_audit';"

echo "== A. LOAD_FILE() and max_allowed_packet"
head -c 3000 /dev/zero | tr '\0' x > $D/a3000.txt
head -c 2048 /dev/zero | tr '\0' y > $D/a2048.txt
head -c 2047 /dev/zero | tr '\0' y > $D/a2047.txt
chmod 644 $D/a*.txt
echo "-- default (GLOBAL, SESSION):"; q "SELECT @@GLOBAL.max_allowed_packet, @@SESSION.max_allowed_packet;"
echo "-- SET SESSION:"; q "SET SESSION max_allowed_packet = 2048;"
echo "-- SET GLOBAL = 2048, then in the SAME connection (session value, LENGTH of the 3000-byte file):"
q "SET GLOBAL max_allowed_packet = 2048; SELECT @@SESSION.max_allowed_packet, LENGTH(LOAD_FILE('$D/a3000.txt'));"
echo "-- a NEW connection (session value; LENGTH of files of 3000, 2048 and 2047 bytes):"
q "SELECT @@SESSION.max_allowed_packet, LENGTH(LOAD_FILE('$D/a3000.txt')), LENGTH(LOAD_FILE('$D/a2048.txt')), LENGTH(LOAD_FILE('$D/a2047.txt')); SHOW WARNINGS;"
echo "-- range of the GLOBAL value (set 100, 2000000000, 3000; read back):"
q "SET GLOBAL max_allowed_packet = 100; SELECT @@GLOBAL.max_allowed_packet; SET GLOBAL max_allowed_packet = 2000000000; SELECT @@GLOBAL.max_allowed_packet; SET GLOBAL max_allowed_packet = 3000; SELECT @@GLOBAL.max_allowed_packet;"
q "SET GLOBAL max_allowed_packet = 16777216;" >/dev/null
rm -f $D/a*.txt

echo; echo "== B. check_constraint_checks"
q "CREATE USER exp_u@'%' IDENTIFIED BY '$EXP_USER_PW'; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, LOCK TABLES, EXECUTE, CREATE ROUTINE, ALTER ROUTINE ON university_resources.* TO exp_u@'%'; GRANT FILE ON *.* TO exp_u@'%';"
q "INSERT INTO university_resources.users (full_name, email, password_hash, role) VALUES ('Demo Student', 'demo.student@frantastic.local', 'scrypt:x', 'student');"
echo "-- root, ordinary UPDATE to admin:"; q "UPDATE university_resources.users SET role = 'admin' WHERE email = 'demo.student@frantastic.local';"
echo "-- root, with check_constraint_checks = 0 (resulting role):"
q "SET SESSION check_constraint_checks = 0; UPDATE university_resources.users SET role = 'admin' WHERE email = 'demo.student@frantastic.local'; SELECT role FROM university_resources.users WHERE email = 'demo.student@frantastic.local';"
echo "-- a non-SUPER account sets it for its session (value read back):"
printf 'SET SESSION check_constraint_checks = 0; SELECT @@SESSION.check_constraint_checks;\n' | MYSQL_PWD="$EXP_USER_PW" mariadb -uexp_u -N 2>&1
q "DELETE FROM university_resources.users WHERE email = 'demo.student@frantastic.local';" >/dev/null

echo; echo "== C. P2-1 probes (scope SESSION, default schema watched)"
q "SET GLOBAL campus_audit_statement_scope = 'SESSION'; CREATE TABLE university_resources.exp_t (id INT PRIMARY KEY, v INT) ENGINE=InnoDB;"
mariadb -uroot 2>&1 <<'SQL'
USE university_resources;
DELIMITER //
CREATE FUNCTION exp_f() RETURNS INT MODIFIES SQL DATA BEGIN INSERT INTO exp_t VALUES (9,9) ON DUPLICATE KEY UPDATE v=v+1; RETURN 1; END //
CREATE TRIGGER exp_trg BEFORE INSERT ON exp_t FOR EACH ROW BEGIN IF NEW.id = 77 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no'; END IF; END //
CREATE PROCEDURE exp_p() BEGIN SET SESSION sql_log_off = 1; INSERT INTO exp_t VALUES (8,8) ON DUPLICATE KEY UPDATE v=v+1; SET SESSION sql_log_off = 0; END //
DELIMITER ;
SQL
printf '3\t3\n' > $D/ld.txt; chmod 644 $D/ld.txt
probe(){ grep -c "\"sql_digest\":\"SET @$1=?\"" $L; }
run(){ q "USE university_resources; $2 SET @$1=1;" >/dev/null; echo "$(probe $1)  $1: $3"; }
echo "(1 = the probe after the sequence was recorded, i.e. nothing was left pending)"
run p01 "SET SESSION sql_log_off=1; INSERT INTO exp_t VALUES (1,1); SET SESSION sql_log_off=0;" "INSERT with sql_log_off=1 at top level"
run p02 "CALL exp_p();" "INSERT inside a procedure that sets sql_log_off=1"
run p03 "LOAD DATA INFILE '$D/ld.txt' INTO TABLE exp_t;" "LOAD DATA INFILE"
run p04 "HANDLER exp_t OPEN; HANDLER exp_t READ FIRST; HANDLER exp_t CLOSE;" "HANDLER OPEN/READ/CLOSE"
run p05 "CREATE TABLE exp_c AS SELECT * FROM exp_t;" "CREATE TABLE ... SELECT"
run p06 "USE mysql; SELECT university_resources.exp_f(); USE university_resources;" "stored function writing a watched table, called from SELECT in another schema"
run p07 "INSERT INTO exp_t VALUES (1,1);" "duplicate-key error after the table event (ER 1062)"
run p08 "INSERT INTO exp_t VALUES (77,1);" "trigger SIGNAL aborting the statement (ER 1644)"
run p09 "XA START 'x1'; INSERT INTO exp_t VALUES (6,6); XA END 'x1'; XA PREPARE 'x1'; XA COMMIT 'x1';" "XA transaction"
run p10 "INSERT DELAYED INTO exp_t VALUES (12,12);" "INSERT DELAYED"
run p11 "SET @s = 'INSERT INTO exp_t VALUES (13,13)'; EXECUTE IMMEDIATE @s;" "EXECUTE IMMEDIATE"
run p12 "PREPARE s FROM 'INSERT INTO exp_t VALUES (?, ?)'; SET @a = 14; EXECUTE s USING @a, @a; DEALLOCATE PREPARE s;" "SQL-level PREPARE / EXECUTE"
run p13 "UPDATE exp_t SET v = v + 1 WHERE id = 1; KILL QUERY CONNECTION_ID();" "KILL QUERY of the own connection after a recorded statement"
run p14 "START TRANSACTION; INSERT INTO exp_t VALUES (15,15); ROLLBACK;" "rolled-back transaction"
run p15 "LOCK TABLES exp_t WRITE; INSERT INTO exp_t VALUES (16,16); UNLOCK TABLES;" "LOCK TABLES section"
q "SET GLOBAL init_connect = 'INSERT INTO university_resources.exp_t VALUES (2,2) ON DUPLICATE KEY UPDATE v=v+1';"
printf 'USE university_resources;\nSET @p16=1;\n' | MYSQL_PWD="$EXP_USER_PW" mariadb -uexp_u -N >/dev/null 2>&1
q "SET GLOBAL init_connect = '';"
echo "$(probe p16)  p16: init_connect writing a watched table (non-SUPER account)"
echo "Not covered: binary-protocol COM_STMT_PREPARE/EXECUTE from a client library (no such client in the image)."
EOF
