-- A one-time gate for the first local administrator.  It runs after seed.sql
-- and migration 004 (scripts/setup_database.sh, Docker initdb order), so the
-- seeded Dana account has already been demoted when the gate is evaluated:
-- on a fresh database it opens the gate; on an upgraded database it opens the
-- gate only if migration 004 left no administrator.  INSERT IGNORE keeps the
-- first decision on every later run.
USE university_resources;

CREATE TABLE IF NOT EXISTS local_admin_bootstrap_state (
    singleton TINYINT UNSIGNED NOT NULL PRIMARY KEY,
    bootstrap_pending BOOLEAN NOT NULL
) ENGINE=InnoDB;

INSERT IGNORE INTO local_admin_bootstrap_state (singleton, bootstrap_pending)
SELECT 1, NOT EXISTS (SELECT 1 FROM users WHERE role = 'admin');

DELIMITER //

CREATE OR REPLACE PROCEDURE bootstrap_local_admin(
    IN p_password_hash VARCHAR(255), IN p_force BOOLEAN)
SQL SECURITY DEFINER
BEGIN
    DECLARE v_pending BOOLEAN DEFAULT FALSE;
    DECLARE v_admin_count BIGINT DEFAULT 0;
    DECLARE v_email_count BIGINT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT bootstrap_pending INTO v_pending
      FROM local_admin_bootstrap_state WHERE singleton = 1 FOR UPDATE;
    SELECT COUNT(*) INTO v_admin_count FROM users WHERE role = 'admin';
    SELECT COUNT(*) INTO v_email_count FROM users WHERE email = 'admin@frantastic.local';

    IF v_admin_count > 0 THEN
        COMMIT;
        SELECT 'ADMIN_EXISTS' AS result;
    ELSEIF v_email_count > 0 THEN
        COMMIT;
        SELECT 'EMAIL_RESERVED' AS result;
    ELSEIF NOT v_pending AND NOT p_force THEN
        COMMIT;
        SELECT 'BOOTSTRAP_CLOSED' AS result;
    ELSE
        INSERT INTO users (full_name, email, password_hash, role)
        VALUES ('Local Administrator', 'admin@frantastic.local', p_password_hash, 'admin');
        UPDATE local_admin_bootstrap_state SET bootstrap_pending = FALSE WHERE singleton = 1;
        COMMIT;
        SELECT 'CREATED' AS result;
    END IF;
END//

CREATE OR REPLACE PROCEDURE rotate_local_admin(IN p_password_hash VARCHAR(255))
SQL SECURITY DEFINER
BEGIN
    DECLARE v_admin_count BIGINT DEFAULT 0;
    DECLARE v_pending BOOLEAN DEFAULT FALSE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT bootstrap_pending INTO v_pending
      FROM local_admin_bootstrap_state WHERE singleton = 1 FOR UPDATE;
    SELECT COUNT(*) INTO v_admin_count
      FROM users WHERE email = 'admin@frantastic.local' AND role = 'admin' FOR UPDATE;
    IF v_admin_count = 1 THEN
        UPDATE users SET password_hash = p_password_hash
         WHERE email = 'admin@frantastic.local' AND role = 'admin';
        COMMIT;
        SELECT 'ROTATED' AS result;
    ELSE
        COMMIT;
        SELECT 'LOCAL_ADMIN_MISSING' AS result;
    END IF;
END//

DELIMITER ;
