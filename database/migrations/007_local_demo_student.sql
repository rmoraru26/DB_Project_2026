-- Migration 007: a per-installation demo student.
--
-- Run after migration 006 (scripts/setup_database.sh and the Docker initdb
-- order).  Idempotent, safe to re-run; it creates no row and changes none.
--
-- Why: the seeded identities (database/seed.sql) carry the placeholder
-- 'TEST_HASH_NOT_FOR_LOGIN' and can never log in, and the repository must not
-- publish a shared password.  A demonstration still needs an account that
-- works immediately.  The start-up scripts (scripts/bootstrap_demo.sh,
-- frantastic.ps1) therefore create ONE dedicated student,
--
--     demo.student@frantastic.local
--
-- with a password generated on that machine.  Only its Werkzeug hash reaches
-- MariaDB, through the two procedures below; the plain password is kept in the
-- git-ignored local file .demo-credentials and nowhere else.
--
-- What this migration adds:
--
-- 1. chk_users_demo_is_student: a defence-in-depth guard that the demo
--    identity does not hold the administrator role.  The primary protection
--    is the grant: campus_app has no privilege on users.role
--    (database/app_account.sh), so the application cannot promote anyone.
--    The CHECK constraint additionally refuses ordinary and accidental writes
--    by other accounts (a hand-written UPDATE, a future application version,
--    a restored dump).  It is not a barrier against a privileged operator:
--    root can disable CHECK enforcement for its session
--    (SET check_constraint_checks = 0) or drop the constraint.
--
-- 2. bootstrap_local_demo_student(hash): inserts the row if, and only if, no
--    account with that e-mail address exists.  An existing row is never
--    changed, so an ordinary restart can neither rotate nor reset a password.
--
-- 3. rotate_local_demo_student(hash): replaces the password hash of the
--    existing demo student.  Called only by the explicit reset command
--    (make reset-demo / frantastic.cmd reset-demo).
--
-- Both procedures accept only a Werkzeug hash (scrypt: or pbkdf2:), touch no
-- other row, and are not granted to the web application account campus_app
-- (database/app_account.sh).  That does not make the demo row read-only for
-- the application: campus_app's column grants (INSERT of full_name, email,
-- password_hash; UPDATE of full_name, password_hash) let /register create a
-- student at the demo address if none exists yet, and let the signed-in demo
-- student change its own password.  What campus_app cannot do is write
-- users.role or users.is_active, so the demo identity stays a student.

USE university_resources;

DELIMITER //

BEGIN NOT ATOMIC
    DECLARE v_conflicting BIGINT DEFAULT 0;
    DECLARE v_present BIGINT DEFAULT 0;

    SELECT COUNT(*) INTO v_present
      FROM information_schema.TABLE_CONSTRAINTS
     WHERE CONSTRAINT_SCHEMA = DATABASE()
       AND TABLE_NAME = 'users'
       AND CONSTRAINT_NAME = 'chk_users_demo_is_student'
       AND CONSTRAINT_TYPE = 'CHECK';

    IF v_present = 0 THEN
        -- Someone may have registered or promoted this address before the
        -- migration existed.  Stop with an explanation rather than let ALTER
        -- TABLE fail with a bare ER 4025, and never demote an account here.
        SELECT COUNT(*) INTO v_conflicting
          FROM users
         WHERE email = 'demo.student@frantastic.local' AND role <> 'student';
        IF v_conflicting > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'migration 007: demo.student@frantastic.local has a non-student role; change its role or e-mail, then re-run';
        END IF;

        ALTER TABLE users
            ADD CONSTRAINT chk_users_demo_is_student
            CHECK (email <> 'demo.student@frantastic.local' OR role = 'student');
    END IF;
END //

CREATE OR REPLACE PROCEDURE bootstrap_local_demo_student(IN p_password_hash VARCHAR(255))
    SQL SECURITY DEFINER
    MODIFIES SQL DATA
    COMMENT 'Create the local demo student if it does not exist; never changes an existing row'
BEGIN
    DECLARE v_existing BIGINT DEFAULT 0;

    -- Checked before the handler exists, so a refusal here never runs its
    -- ROLLBACK: the caller's open transaction is neither committed (START
    -- TRANSACTION below would commit it implicitly) nor rolled back.
    IF @@in_transaction <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'bootstrap_local_demo_student: refused inside an open transaction (it would be committed); COMMIT or ROLLBACK first';
    END IF;
    IF p_password_hash IS NULL OR p_password_hash NOT REGEXP '^(scrypt|pbkdf2):' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'bootstrap_local_demo_student: a Werkzeug password hash (scrypt: or pbkdf2:) is required';
    END IF;

    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            RESIGNAL;
        END;

        START TRANSACTION;
        SELECT COUNT(*) INTO v_existing
          FROM users WHERE email = 'demo.student@frantastic.local' FOR UPDATE;

        IF v_existing > 0 THEN
            COMMIT;
            SELECT 'EXISTS' AS result;
        ELSE
            INSERT INTO users (full_name, email, password_hash, role)
            VALUES ('Demo Student', 'demo.student@frantastic.local', p_password_hash, 'student');
            COMMIT;
            SELECT 'CREATED' AS result;
        END IF;
    END;
END //

CREATE OR REPLACE PROCEDURE rotate_local_demo_student(IN p_password_hash VARCHAR(255))
    SQL SECURITY DEFINER
    MODIFIES SQL DATA
    COMMENT 'Replace the password hash of the existing local demo student (explicit reset only)'
BEGIN
    DECLARE v_existing BIGINT DEFAULT 0;
    DECLARE v_students BIGINT DEFAULT 0;

    -- As in bootstrap_local_demo_student: refuse before the handler exists.
    IF @@in_transaction <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'rotate_local_demo_student: refused inside an open transaction (it would be committed); COMMIT or ROLLBACK first';
    END IF;
    IF p_password_hash IS NULL OR p_password_hash NOT REGEXP '^(scrypt|pbkdf2):' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'rotate_local_demo_student: a Werkzeug password hash (scrypt: or pbkdf2:) is required';
    END IF;

    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            RESIGNAL;
        END;

        START TRANSACTION;
        SELECT COUNT(*), COALESCE(SUM(role = 'student'), 0) INTO v_existing, v_students
          FROM users WHERE email = 'demo.student@frantastic.local' FOR UPDATE;

        IF v_existing = 0 THEN
            COMMIT;
            SELECT 'MISSING' AS result;
        ELSEIF v_students = 0 THEN
            -- Unreachable while chk_users_demo_is_student exists; kept so that the
            -- procedure alone never issues a password for a privileged account.
            COMMIT;
            SELECT 'NOT_STUDENT' AS result;
        ELSE
            UPDATE users SET password_hash = p_password_hash
             WHERE email = 'demo.student@frantastic.local' AND role = 'student';
            COMMIT;
            SELECT 'ROTATED' AS result;
        END IF;
    END;
END //

DELIMITER ;
