-- Initial database checks.
-- Run after schema.sql and seed.sql.
-- Run in the MariaDB interactive client using SOURCE.
-- Tests 4-8 intentionally produce errors.
-- Test changes are rolled back.

USE university_resources;

-- TEST 1: Six tables should exist.
SHOW TABLES;

-- TEST 2: Display bookings with their users and rooms.
-- Expected sample: Alice Student, Room 201, confirmed.
SELECT u.full_name, r.name AS room,
       b.start_time, b.end_time, b.status
FROM bookings b
JOIN users u ON b.user_id = u.user_id
JOIN rooms r ON b.room_id = r.room_id;

-- TEST 3: Display loans with their users and items.
-- Expected sample: Alice Student, Arduino Starter Kit, returned.
SELECT u.full_name, i.name AS item,
       l.status, l.borrowed_at, l.returned_at
FROM loans l
JOIN users u ON l.user_id = u.user_id
JOIN items i ON l.item_id = i.item_id;

-- TEST 4: Reject zero room capacity.
-- Expected: ERROR 4025, chk_rooms_capacity_positive.
START TRANSACTION;

INSERT INTO rooms (name, capacity)
VALUES ('Invalid Test Room', 0);

ROLLBACK;

-- TEST 5: Reject a booking ending before it starts.
-- Expected: ERROR 4025, chk_bookings_time_order.
START TRANSACTION;

INSERT INTO bookings (user_id, room_id, start_time, end_time)
SELECT u.user_id, r.room_id,
       '2030-01-10 11:00:00',
       '2030-01-10 10:00:00'
FROM users u
CROSS JOIN rooms r
WHERE u.email = 'alice.student@example.edu'
  AND r.name = 'Room 201'
  AND r.building = 'Main Building';

ROLLBACK;

-- TEST 6: Reject a duplicate email.
-- Expected: ERROR 1062, uq_users_email.
START TRANSACTION;

INSERT INTO users (full_name, email, role)
VALUES ('Duplicate Test', 'alice.student@example.edu', 'student');

ROLLBACK;

-- TEST 7: Reject a booking referencing a nonexistent user.
-- Select an unused ID above the current maximum.
-- Expected: ERROR 1452, fk_bookings_user.
START TRANSACTION;

SET @missing_user_id = (
    SELECT COALESCE(MAX(user_id), 0) + 1 FROM users
);

INSERT INTO bookings (user_id, room_id, start_time, end_time)
SELECT @missing_user_id, room_id,
       '2030-01-10 10:00:00',
       '2030-01-10 11:00:00'
FROM rooms
WHERE name = 'Room 201'
  AND building = 'Main Building';

ROLLBACK;

-- TEST 8: Reject a returned loan without a return timestamp.
-- Expected: ERROR 4025, chk_loans_status_returned_consistent.
START TRANSACTION;

UPDATE loans l
JOIN users u ON l.user_id = u.user_id
JOIN items i ON l.item_id = i.item_id
SET l.returned_at = NULL
WHERE u.email = 'alice.student@example.edu'
  AND i.asset_tag = 'DEMO-ARD-001'
  AND l.status = 'returned';

ROLLBACK;

SELECT 'Initial database checks finished. Review expected errors above.'
       AS test_summary;
