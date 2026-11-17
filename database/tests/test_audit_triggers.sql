-- Manual integration test: run only in a development/test database.
-- Assumes schema.sql, the migrations, triggers.sql and seed.sql have been
-- applied (scripts/setup_database.sh).  database/triggers.sql replaced the
-- earlier sql/audit_triggers.sql and drops its triggers, so each change below
-- must produce exactly one history row.  tests/database/test_audit_triggers.sh
-- runs this file and checks the counts automatically.
-- Every change is made inside a transaction and rolled back at the end.
USE university_resources;

START TRANSACTION;

SET @test_user_id = (SELECT user_id FROM users WHERE email = 'alice.student@example.edu');
SET @test_room_id = (SELECT room_id FROM rooms WHERE name = 'Project Room 12');
SET @test_item_id = (SELECT item_id FROM items WHERE asset_tag = 'DEMO-SCOPE-001');

-- Verify these are non-NULL before continuing.
SELECT @test_user_id AS test_user_id, @test_room_id AS test_room_id,
       @test_item_id AS test_item_id;

SET @audit_start = (SELECT COALESCE(MAX(event_id), 0) FROM audit_events);

-- Booking INSERT, UPDATE, DELETE
INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
VALUES (@test_user_id, @test_room_id,
        DATE_ADD(NOW(6), INTERVAL 10 DAY),
        DATE_ADD(NOW(6), INTERVAL 10 DAY) + INTERVAL 1 HOUR,
        'confirmed');
SET @test_booking_id = LAST_INSERT_ID();

UPDATE bookings SET status = 'cancelled' WHERE booking_id = @test_booking_id;
DELETE FROM bookings WHERE booking_id = @test_booking_id;

-- Loan INSERT, UPDATE, DELETE
INSERT INTO loans (user_id, item_id, borrowed_at, due_at, status)
VALUES (@test_user_id, @test_item_id, NOW(6),
        DATE_ADD(NOW(6), INTERVAL 7 DAY), 'active');
SET @test_loan_id = LAST_INSERT_ID();

UPDATE loans
SET status = 'returned', returned_at = NOW(6)
WHERE loan_id = @test_loan_id;
DELETE FROM loans WHERE loan_id = @test_loan_id;

-- Expected: six new events total, all from this session (connection_id),
-- database_user = USER(), event_source = direct_sql (no @app_user_id).
-- Other sessions may write history concurrently, hence the connection filter.
SELECT event_id, event_time, action, entity_table, entity_id,
       database_user, application_user_id, connection_id,
       old_values, new_values, event_source
FROM audit_events
WHERE event_id > @audit_start
  AND connection_id = CONNECTION_ID()
ORDER BY event_id;

-- Expected: one row per table and action, each with event_count 1.
SELECT entity_table, action, COUNT(*) AS event_count
FROM audit_events
WHERE event_id > @audit_start
  AND connection_id = CONNECTION_ID()
GROUP BY entity_table, action
ORDER BY entity_table, action;

ROLLBACK;
