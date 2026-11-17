-- Booking catalogue of the web application.
--
-- The booking pages offer a fixed catalogue (frontend/app.py: items_home and
-- rooms_home): 18 item types, each in three copies A-C, and five rooms.  The
-- pages address rooms and items by these names, so without the rows every
-- booking attempt answers "This item does not exist." / "This room does not
-- exist.".  This is reference data the application needs, not demo data; it
-- is therefore part of the installation order (scripts/setup_database.sh and
-- the Docker initdb order, right after seed.sql) and is also applied when an
-- existing database is upgraded (SKIP_SEED=1 skips seed.sql, not this file).
--
-- Safe to run any number of times, on a new or an existing database:
--
-- * a row is inserted only if it is absent (items by their unique asset_tag,
--   rooms by name), so there are never duplicates;
-- * an existing row is never updated: a status set to 'maintenance' or
--   'retired', an edited description, and every booking or loan that refers
--   to the row stay exactly as they are (no ON DUPLICATE KEY UPDATE, which
--   would also fire the UPDATE triggers and write history rows on each run);
-- * both INSERTs run in one transaction;
-- * concurrent runs are serialised by the named lock 'frantastic_catalogue'.
--   items has a UNIQUE asset_tag, but rooms has no unique key on name, and
--   adding one could fail on existing databases that already hold two rooms
--   with the same name.  Without the lock, on a database whose items were
--   complete but whose rooms were missing, two simultaneous runs under READ
--   COMMITTED both inserted all five rooms (10 rows, measured on 13.0.2;
--   under the default REPEATABLE READ the second run waited and inserted
--   nothing; with items missing too, the second run failed on the items'
--   unique asset_tag, ER 1062).  A run that cannot take the lock within 60 seconds stops with
--   an error and changes nothing; the lock is released at the end of the
--   file or when the connection closes (also after an error).
--
-- It runs with the administrator connection of the setup scripts.  The web
-- application account campus_app has no INSERT privilege on items or rooms
-- (database/app_account.sh) and does not need one.
--
-- The inserted rows pass through the items/rooms triggers like any other
-- change: audit_events shows them with the setup account as database_user,
-- no application user and event_source 'direct_sql'.
--
-- Operators who maintain items and rooms themselves can leave the catalogue
-- out with SKIP_CATALOGUE=1 (scripts/setup_database.sh).
--
-- frontend/seed.py holds the same catalogue as a stand-alone utility;
-- frontend/tests/test_seed.py checks that the two lists are identical.

USE university_resources;

DELIMITER //
BEGIN NOT ATOMIC
    IF COALESCE(GET_LOCK('frantastic_catalogue', 60), 0) <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'catalogue.sql: another run holds the lock frantastic_catalogue; nothing was changed, run it again';
    END IF;
END //
DELIMITER ;

START TRANSACTION;

-- Item types in the order of the booking page; item_id follows this order, and
-- the application offers the lowest free item_id first.
INSERT INTO items (name, category, asset_tag, status)
SELECT c.name, c.category, CONCAT(c.name, ' ', v.copy), 'available'
FROM (
              SELECT  1 AS position, 'Vacuum' AS name, 'Cleaning Items' AS category
    UNION ALL SELECT  2, 'Mop', 'Cleaning Items'
    UNION ALL SELECT  3, 'Iron', 'Cleaning Items'
    UNION ALL SELECT  4, 'Broom', 'Cleaning Items'
    UNION ALL SELECT  5, 'Chess', 'Board Games'
    UNION ALL SELECT  6, 'Monopoly', 'Board Games'
    UNION ALL SELECT  7, 'Settlers of Catan', 'Board Games'
    UNION ALL SELECT  8, 'Scrabble', 'Board Games'
    UNION ALL SELECT  9, 'Battleship', 'Board Games'
    UNION ALL SELECT 10, 'Basketball', 'Sports Items'
    UNION ALL SELECT 11, 'Football', 'Sports Items'
    UNION ALL SELECT 12, 'Frisbee', 'Sports Items'
    UNION ALL SELECT 13, 'Tennis Racket', 'Sports Items'
    UNION ALL SELECT 14, 'Speaker', 'Electronics'
    UNION ALL SELECT 15, 'PS5 Controller', 'Electronics'
    UNION ALL SELECT 16, 'Headphones', 'Electronics'
    UNION ALL SELECT 17, 'Nintendo Switch', 'Electronics'
    UNION ALL SELECT 18, 'Gameboy', 'Electronics'
) AS c
CROSS JOIN (
              SELECT 'A' AS copy
    UNION ALL SELECT 'B'
    UNION ALL SELECT 'C'
) AS v
WHERE NOT EXISTS (
    SELECT 1 FROM items AS i WHERE i.asset_tag = CONCAT(c.name, ' ', v.copy)
)
ORDER BY c.position, v.copy;

INSERT INTO rooms (name, capacity, status)
SELECT c.name, c.capacity, 'available'
FROM (
              SELECT 1 AS position, 'Study Room' AS name, 4 AS capacity
    UNION ALL SELECT 2, 'Meeting Room', 10
    UNION ALL SELECT 3, 'Studio Room', 4
    UNION ALL SELECT 4, 'Practice Room', 2
    UNION ALL SELECT 5, 'Cinema Room', 15
) AS c
WHERE NOT EXISTS (
    SELECT 1 FROM rooms AS r WHERE r.name = c.name
)
ORDER BY c.position;

COMMIT;

DO RELEASE_LOCK('frantastic_catalogue');
