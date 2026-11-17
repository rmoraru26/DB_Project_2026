#!/usr/bin/env bash
# The booking catalogue (database/catalogue.sql) on the server.
#
#   1. Installed database: every room and item the booking pages offer exists
#      exactly once (18 item types x copies A-C, 5 rooms), and running
#      catalogue.sql again changes nothing: same rows, same ids, same
#      updated_at, and not one new row in audit_events (no trigger fired).
#   2. Scratch database (copies of the items/rooms definitions, created and
#      dropped by this test): a first run loads 54 items and 5 rooms in the
#      order of the booking page; after rows were edited, removed and added by
#      hand, a further run restores only what is missing and leaves every
#      existing row untouched; no run ever creates a duplicate.
#   3. Concurrency: two overlapping runs under READ COMMITTED create no
#      duplicate room (the named lock 'frantastic_catalogue' serialises them),
#      the lock is released afterwards, and a run that cannot get the lock
#      stops with an explanation and changes nothing.
#
#   MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" MYSQL_PWD=<admin password> \
#       bash tests/database/test_catalogue.sh
#
# ADMINISTRATOR ACCESS (creates and drops one scratch database).  In the
# installed database the only statements that can write are those of
# catalogue.sql itself, which is what `make up` runs on every start.

set -u
cd "$(dirname "$0")/../.."

CLIENT=(${MARIADB_CLIENT:-mariadb})
ADMIN_USER=${DB_ADMIN_USER:-root}
SCRATCH=frt_catalogue_test_$$
U=university_resources
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "      $2"; }
sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names 2>&1 | tr -d '\r'; }
check() {       # check "<description>" "<expected>" "<statement>"
    local got
    got=$(sql "$3")
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1" "expected '$2', got '$got'"; fi
}
catalogue_for() { tr -d '\r' < database/catalogue.sql | sed "s/^USE university_resources;/USE $1;/"; }
run_catalogue() { catalogue_for "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch 2>&1 | tr -d '\r'; }

cleanup() { sql "DROP DATABASE IF EXISTS $SCRATCH;" >/dev/null 2>&1; }
trap cleanup EXIT

ITEM_NAMES="'Vacuum','Mop','Iron','Broom','Chess','Monopoly','Settlers of Catan','Scrabble','Battleship','Basketball','Football','Frisbee','Tennis Racket','Speaker','PS5 Controller','Headphones','Nintendo Switch','Gameboy'"
ROOM_NAMES="'Study Room','Meeting Room','Studio Room','Practice Room','Cinema Room'"
# One line per catalogue item / room with everything that must not change.
ITEMS_STATE="SELECT COALESCE(MD5(GROUP_CONCAT(CONCAT_WS('|', item_id, name, IFNULL(description, ''), IFNULL(category, ''), asset_tag, status, created_at, updated_at) ORDER BY item_id SEPARATOR '\n')), 'none')"
ROOMS_STATE="SELECT COALESCE(MD5(GROUP_CONCAT(CONCAT_WS('|', room_id, name, IFNULL(building, ''), capacity, status, created_at, updated_at) ORDER BY room_id SEPARATOR '\n')), 'none')"

# ---------------------------------------------------------------- 1. installed database
check "installed: 18 item types, each with copies A, B and C (54 rows)" "18|54|54" \
      "SELECT CONCAT_WS('|', COUNT(DISTINCT name), COUNT(*), SUM(asset_tag IN (CONCAT(name, ' A'), CONCAT(name, ' B'), CONCAT(name, ' C')))) FROM $U.items WHERE name IN ($ITEM_NAMES) AND asset_tag LIKE CONCAT(name, ' _');"
check "installed: every item type has exactly three copies" "0" \
      "SELECT COUNT(*) FROM (SELECT name FROM $U.items WHERE name IN ($ITEM_NAMES) AND asset_tag LIKE CONCAT(name, ' _') GROUP BY name HAVING COUNT(*) <> 3) AS wrong;"
check "installed: the five rooms of the booking page exist, each once" "5|5" \
      "SELECT CONCAT_WS('|', COUNT(DISTINCT name), COUNT(*)) FROM $U.rooms WHERE name IN ($ROOM_NAMES);"
check "installed: catalogue rooms and items are bookable (status available) unless changed locally" "1" \
      "SELECT (SELECT COUNT(*) FROM $U.rooms WHERE name IN ($ROOM_NAMES) AND status = 'available') > 0 AND (SELECT COUNT(*) FROM $U.items WHERE name IN ($ITEM_NAMES) AND status = 'available') > 0;"

before=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $U.items; $ROOMS_STATE FROM $U.rooms; SELECT COUNT(*) FROM $U.items; SELECT COUNT(*) FROM $U.rooms; SELECT COUNT(*) FROM $U.audit_events WHERE entity_table IN ('items', 'rooms');")
out=$(run_catalogue "$U"; run_catalogue "$U")
after=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $U.items; $ROOMS_STATE FROM $U.rooms; SELECT COUNT(*) FROM $U.items; SELECT COUNT(*) FROM $U.rooms; SELECT COUNT(*) FROM $U.audit_events WHERE entity_table IN ('items', 'rooms');")
if [ -z "$out" ]; then pass "installed: catalogue.sql re-runs without error"; else fail "installed: catalogue.sql re-runs without error" "$out"; fi
if [ -n "$before" ] && [ "$before" = "$after" ]; then
    pass "installed: two more runs changed no row of items or rooms and wrote no history row (rows, ids, updated_at, audit_events count identical)"
else
    fail "installed: re-running catalogue.sql must change nothing" "before: $(printf '%s' "$before" | tr '\n' ' ') after: $(printf '%s' "$after" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 2. scratch database
out=$(sql "DROP DATABASE IF EXISTS $SCRATCH; CREATE DATABASE $SCRATCH CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
           CREATE TABLE $SCRATCH.items LIKE $U.items; CREATE TABLE $SCRATCH.rooms LIKE $U.rooms;")
if [ -z "$out" ]; then pass "scratch copies of items and rooms created (empty)"; else fail "scratch copies of items and rooms created" "$out"; fi
if [ "$(catalogue_for "$SCRATCH" | grep -c "^USE $SCRATCH;")" != 1 ] || catalogue_for "$SCRATCH" | grep -v '^--' | grep -q "$U"; then
    fail "catalogue.sql can be redirected to the scratch database"; echo "== $PASS passed, $FAIL failed"; exit 1
fi

out=$(run_catalogue "$SCRATCH")
if [ -z "$out" ]; then pass "fresh database: catalogue.sql applies"; else fail "fresh database: catalogue.sql applies" "$out"; fi
check "fresh database: 54 items and 5 rooms" "54|5" "SELECT CONCAT_WS('|', (SELECT COUNT(*) FROM $SCRATCH.items), (SELECT COUNT(*) FROM $SCRATCH.rooms));"
check "fresh database: items are numbered in the order of the booking page (Vacuum A first, Gameboy C last)" "Vacuum A|Vacuum B|Mop A|Gameboy C" \
      "SELECT CONCAT_WS('|', (SELECT asset_tag FROM $SCRATCH.items ORDER BY item_id LIMIT 1), (SELECT asset_tag FROM $SCRATCH.items ORDER BY item_id LIMIT 1 OFFSET 1), (SELECT asset_tag FROM $SCRATCH.items ORDER BY item_id LIMIT 1 OFFSET 3), (SELECT asset_tag FROM $SCRATCH.items ORDER BY item_id DESC LIMIT 1));"
check "fresh database: rooms in the order of the booking page with their capacities" "Study Room:4,Meeting Room:10,Studio Room:4,Practice Room:2,Cinema Room:15" \
      "SELECT GROUP_CONCAT(CONCAT(name, ':', capacity) ORDER BY room_id) FROM $SCRATCH.rooms;"
check "fresh database: categories as on the booking page" "Board Games:15,Cleaning Items:12,Electronics:15,Sports Items:12" \
      "SELECT GROUP_CONCAT(CONCAT(category, ':', n) ORDER BY category) FROM (SELECT category, COUNT(*) AS n FROM $SCRATCH.items GROUP BY category) AS c;"

# Local changes an operator may have made: they must survive.
sql "UPDATE $SCRATCH.items SET status = 'maintenance', description = 'being repaired' WHERE asset_tag = 'Chess B';
     UPDATE $SCRATCH.items SET status = 'retired' WHERE asset_tag = 'Mop C';
     UPDATE $SCRATCH.rooms SET status = 'maintenance', capacity = 3, building = 'Annex' WHERE name = 'Studio Room';
     INSERT INTO $SCRATCH.items (name, category, asset_tag) VALUES ('Telescope', 'Electronics', 'LOCAL-TEL-1');
     INSERT INTO $SCRATCH.rooms (name, capacity) VALUES ('Workshop', 6);
     DELETE FROM $SCRATCH.items WHERE asset_tag IN ('Frisbee A', 'Gameboy C');
     DELETE FROM $SCRATCH.rooms WHERE name = 'Cinema Room';" >/dev/null
kept=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $SCRATCH.items; $ROOMS_STATE FROM $SCRATCH.rooms;")
out=$(run_catalogue "$SCRATCH")
if [ -z "$out" ]; then pass "existing database: catalogue.sql applies"; else fail "existing database: catalogue.sql applies" "$out"; fi
check "existing database: the removed rows are back, nothing is duplicated (55 items incl. the local one, 6 rooms)" "55|55|6|6" \
      "SELECT CONCAT_WS('|', (SELECT COUNT(*) FROM $SCRATCH.items), (SELECT COUNT(DISTINCT asset_tag) FROM $SCRATCH.items), (SELECT COUNT(*) FROM $SCRATCH.rooms), (SELECT COUNT(DISTINCT name) FROM $SCRATCH.rooms));"
check "existing database: locally changed rows keep their status, description, capacity and building" "maintenance|being repaired|retired|maintenance|3|Annex" \
      "SELECT CONCAT_WS('|', (SELECT status FROM $SCRATCH.items WHERE asset_tag = 'Chess B'), (SELECT description FROM $SCRATCH.items WHERE asset_tag = 'Chess B'), (SELECT status FROM $SCRATCH.items WHERE asset_tag = 'Mop C'), (SELECT status FROM $SCRATCH.rooms WHERE name = 'Studio Room'), (SELECT capacity FROM $SCRATCH.rooms WHERE name = 'Studio Room'), (SELECT building FROM $SCRATCH.rooms WHERE name = 'Studio Room'));"
check "existing database: locally added rows are kept" "1|1" \
      "SELECT CONCAT_WS('|', (SELECT COUNT(*) FROM $SCRATCH.items WHERE asset_tag = 'LOCAL-TEL-1'), (SELECT COUNT(*) FROM $SCRATCH.rooms WHERE name = 'Workshop'));"
still=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $SCRATCH.items WHERE asset_tag NOT IN ('Frisbee A', 'Gameboy C'); $ROOMS_STATE FROM $SCRATCH.rooms WHERE name <> 'Cinema Room';")
if [ -n "$kept" ] && [ "$kept" = "$still" ]; then pass "existing database: every row that existed before the run is byte-for-byte unchanged (ids, values, updated_at)"
else fail "existing database: every row that existed before the run is unchanged"; fi

twice=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $SCRATCH.items; $ROOMS_STATE FROM $SCRATCH.rooms;")
out=$(run_catalogue "$SCRATCH"; run_catalogue "$SCRATCH"; run_catalogue "$SCRATCH")
again=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $SCRATCH.items; $ROOMS_STATE FROM $SCRATCH.rooms;")
if [ -z "$out" ] && [ "$twice" = "$again" ]; then pass "three further runs change nothing"
else fail "three further runs change nothing" "$out"; fi

# ---------------------------------------------------------------- 3. concurrent runs (named lock)
# rooms has no unique key on name.  When the items are complete and the rooms
# are missing, two runs at the same time under READ COMMITTED inserted every
# room twice before the lock existed (post-audit evidence; with missing items
# the second run instead failed on the items' unique asset_tag, ER 1062).  The
# first run here is held inside its transaction for two seconds while the
# second one starts.
sql "DELETE FROM $SCRATCH.rooms;" >/dev/null
items_before=$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $SCRATCH.items;")
slow_run() {   # the catalogue, READ COMMITTED, paused before its COMMIT
    { echo "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;"
      catalogue_for "$SCRATCH" | sed 's/^COMMIT;$/SELECT SLEEP(2) INTO @frt_pause; COMMIT;/'; } \
        | "${CLIENT[@]}" -u"$ADMIN_USER" --batch 2>&1 | tr -d '\r'
}
fast_run() { { echo "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;"; catalogue_for "$SCRATCH"; } \
        | "${CLIENT[@]}" -u"$ADMIN_USER" --batch 2>&1 | tr -d '\r'; }
slow_run > "${TMPDIR:-/tmp}/frt_cat_a_$$" & first=$!
sleep 0.5
second_out=$(fast_run)
wait "$first"; first_out=$(cat "${TMPDIR:-/tmp}/frt_cat_a_$$"); rm -f "${TMPDIR:-/tmp}/frt_cat_a_$$"
if [ -z "$first_out$second_out" ]; then pass "two overlapping runs under READ COMMITTED both succeed"
else fail "two overlapping runs under READ COMMITTED" "$first_out $second_out"; fi
check "two overlapping runs under READ COMMITTED create no duplicate room (5 rooms, 5 distinct names)" "5|5" \
      "SELECT CONCAT_WS('|', (SELECT COUNT(*) FROM $SCRATCH.rooms), (SELECT COUNT(DISTINCT name) FROM $SCRATCH.rooms));"
if [ "$(sql "SET SESSION group_concat_max_len = 1000000; $ITEMS_STATE FROM $SCRATCH.items;")" = "$items_before" ]; then
    pass "the overlapping runs left the existing items unchanged"
else fail "the overlapping runs changed existing items"; fi
check "the catalogue lock is released after the runs" "1" "SELECT IS_FREE_LOCK('frantastic_catalogue');"

# A run that cannot get the lock stops before changing anything (wait shortened to 1 s).
sql "DELETE FROM $SCRATCH.rooms WHERE name = 'Cinema Room';" >/dev/null
printf '%s\n' "SELECT GET_LOCK('frantastic_catalogue', 0) INTO @held; SELECT SLEEP(4) INTO @frt_hold;" \
    | "${CLIENT[@]}" -u"$ADMIN_USER" --batch >/dev/null 2>&1 & holder=$!
sleep 1
out=$(catalogue_for "$SCRATCH" | sed "s/GET_LOCK('frantastic_catalogue', 60)/GET_LOCK('frantastic_catalogue', 1)/" \
        | "${CLIENT[@]}" -u"$ADMIN_USER" --batch 2>&1 | tr -d '\r')
wait "$holder"
if printf '%s' "$out" | grep -q "another run holds the lock frantastic_catalogue"; then
    pass "while another session holds the lock, a run stops with an explanation"
else fail "run while the lock is held" "$out"; fi
check "that run changed nothing (Cinema Room still missing, 4 rooms)" "4" "SELECT COUNT(*) FROM $SCRATCH.rooms;"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
