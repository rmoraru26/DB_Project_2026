-- Sample data for the University Resource Management System.
-- Run this after schema.sql.
--
-- These are fictional demonstration records. The inserts are repeatable:
-- fixed unique emails and asset tags prevent duplicate logical records.
-- The script looks up IDs by unique values rather than assuming AUTO_INCREMENT IDs.
--
-- Use only in a development/demo database, not a production database.

USE university_resources;

START TRANSACTION;

-- Users
INSERT INTO users (full_name, email, role)
VALUES
    ('Alice Student', 'alice.student@example.edu', 'student'),
    ('Bob Student', 'bob.student@example.edu', 'student'),
    ('Dana Administrator', 'dana.admin@example.edu', 'admin')
ON DUPLICATE KEY UPDATE
    full_name = VALUES(full_name),
    role = VALUES(role);

-- Rooms
INSERT INTO rooms (name, building, location_details, capacity, status)
SELECT 'Room 201', 'Main Building', 'First floor', 8, 'available'
WHERE NOT EXISTS (
    SELECT 1 FROM rooms
    WHERE name = 'Room 201' AND building = 'Main Building'
);

INSERT INTO rooms (name, building, location_details, capacity, status)
SELECT 'Project Room 12', 'Engineering Building', 'Ground floor', 6, 'available'
WHERE NOT EXISTS (
    SELECT 1 FROM rooms
    WHERE name = 'Project Room 12' AND building = 'Engineering Building'
);

INSERT INTO rooms (name, building, location_details, capacity, status)
SELECT 'Electronics Lab', 'Engineering Building', 'Lab wing', 12, 'maintenance'
WHERE NOT EXISTS (
    SELECT 1 FROM rooms
    WHERE name = 'Electronics Lab' AND building = 'Engineering Building'
);

-- Individual physical items
INSERT INTO items (name, description, category, asset_tag, status)
VALUES
    ('Arduino Starter Kit', 'Microcontroller board and starter components', 'Electronics', 'DEMO-ARD-001', 'available'),
    ('USB Oscilloscope', 'Portable USB oscilloscope for lab exercises', 'Electronics', 'DEMO-SCOPE-001', 'available'),
    ('Digital Camera', 'Camera for documentation and project work', 'Media', 'DEMO-CAM-001', 'maintenance')
ON DUPLICATE KEY UPDATE
    name = VALUES(name),
    description = VALUES(description),
    category = VALUES(category),
    status = VALUES(status);

-- A future booking for Alice in Room 201.
-- Use a relative date so the demo remains useful when run on another day.
INSERT INTO bookings (user_id, room_id, start_time, end_time, status)
SELECT u.user_id, r.room_id,
       TIMESTAMP(DATE_ADD(CURRENT_DATE, INTERVAL 1 DAY), '10:00:00'),
       TIMESTAMP(DATE_ADD(CURRENT_DATE, INTERVAL 1 DAY), '11:00:00'),
       'confirmed'
FROM users AS u
JOIN rooms AS r
  ON r.name = 'Room 201' AND r.building = 'Main Building'
WHERE u.email = 'alice.student@example.edu'
  AND NOT EXISTS (
      SELECT 1
      FROM bookings AS b
      WHERE b.user_id = u.user_id
        AND b.room_id = r.room_id
        AND b.start_time = TIMESTAMP(DATE_ADD(CURRENT_DATE, INTERVAL 1 DAY), '10:00:00')
  );

-- A returned historical loan demonstrates that an item can be borrowed repeatedly.
INSERT INTO loans (user_id, item_id, borrowed_at, due_at, returned_at, status)
SELECT u.user_id, i.item_id,
       DATE_SUB(NOW(), INTERVAL 3 DAY),
       DATE_SUB(NOW(), INTERVAL 2 DAY),
       DATE_SUB(NOW(), INTERVAL 2 DAY),
       'returned'
FROM users AS u
JOIN items AS i ON i.asset_tag = 'DEMO-ARD-001'
WHERE u.email = 'alice.student@example.edu'
  AND NOT EXISTS (
      SELECT 1
      FROM loans AS l
      WHERE l.user_id = u.user_id
        AND l.item_id = i.item_id
        AND l.borrowed_at = DATE_SUB(NOW(), INTERVAL 3 DAY)
  );

COMMIT;
