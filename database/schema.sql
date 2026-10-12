-- University Resource Management System
-- Initial MariaDB schema for development.
--
-- This is a starting point, not the final schema. In particular, audit_events is
-- a proposed storage interface. Confirm that the chosen MariaDB plugin API can
-- capture and write the intended events before relying on it.
--
-- To use:
--   1. Connect to MariaDB with an account allowed to create databases.
--   2. Execute this file.
--   3. Optionally execute seed.sql after it has been created.
--
-- Do not put real passwords or secrets in this file.

CREATE DATABASE IF NOT EXISTS university_resources
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE university_resources;

-- People who can use the application.
-- Authentication/password handling can be added once the team's login approach
-- is agreed. Never store plaintext passwords.
CREATE TABLE IF NOT EXISTS users (
    user_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name VARCHAR(150) NOT NULL,
    email VARCHAR(254) NOT NULL,
    role ENUM('student', 'admin') NOT NULL DEFAULT 'student',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_email (email),
    CONSTRAINT chk_users_email_nonempty CHECK (CHAR_LENGTH(TRIM(email)) > 0)
) ENGINE=InnoDB;

-- Each room that can be booked.
CREATE TABLE IF NOT EXISTS rooms (
    room_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    building VARCHAR(100) NULL,
    location_details VARCHAR(255) NULL,
    capacity SMALLINT UNSIGNED NOT NULL,
    status ENUM('available', 'maintenance', 'retired')
        NOT NULL DEFAULT 'available',
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (room_id),
    KEY idx_rooms_status (status),
    CONSTRAINT chk_rooms_capacity_positive CHECK (capacity > 0),
    CONSTRAINT chk_rooms_name_nonempty CHECK (CHAR_LENGTH(TRIM(name)) > 0)
) ENGINE=InnoDB;

-- Each row represents one physical item (e.g. Arduino Kit #17).
CREATE TABLE IF NOT EXISTS items (
    item_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name VARCHAR(150) NOT NULL,
    description TEXT NULL,
    category VARCHAR(100) NULL,
    asset_tag VARCHAR(100) NULL,
    status ENUM('available', 'maintenance', 'retired')
        NOT NULL DEFAULT 'available',
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (item_id),
    UNIQUE KEY uq_items_asset_tag (asset_tag),
    KEY idx_items_status (status),
    KEY idx_items_category (category),
    CONSTRAINT chk_items_name_nonempty CHECK (CHAR_LENGTH(TRIM(name)) > 0)
) ENGINE=InnoDB;

-- A room reservation. Application logic must prevent overlapping active
-- bookings for the same room; a CHECK constraint cannot enforce this cross-row rule.
CREATE TABLE IF NOT EXISTS bookings (
    booking_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id BIGINT UNSIGNED NOT NULL,
    room_id BIGINT UNSIGNED NOT NULL,
    start_time DATETIME(6) NOT NULL,
    end_time DATETIME(6) NOT NULL,
    status ENUM('confirmed', 'cancelled', 'completed')
        NOT NULL DEFAULT 'confirmed',
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (booking_id),
    KEY idx_bookings_room_time (room_id, status, start_time, end_time),
    KEY idx_bookings_user_time (user_id, start_time),
    CONSTRAINT fk_bookings_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_bookings_room
        FOREIGN KEY (room_id) REFERENCES rooms (room_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_bookings_time_order CHECK (end_time > start_time)
) ENGINE=InnoDB;

-- One borrowing transaction for one physical item.
-- Application logic must prevent more than one active loan per item, including
-- concurrent requests, and should enforce this inside a transaction.
CREATE TABLE IF NOT EXISTS loans (
    loan_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id BIGINT UNSIGNED NOT NULL,
    item_id BIGINT UNSIGNED NOT NULL,
    borrowed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    due_at DATETIME(6) NULL,
    returned_at DATETIME(6) NULL,
    status ENUM('active', 'returned', 'lost') NOT NULL DEFAULT 'active',
    created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (loan_id),
    KEY idx_loans_item_status (item_id, status),
    KEY idx_loans_user_status (user_id, status),
    KEY idx_loans_due_at (due_at),
    CONSTRAINT fk_loans_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_loans_item
        FOREIGN KEY (item_id) REFERENCES items (item_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_loans_due_after_borrow CHECK (
        due_at IS NULL OR due_at >= borrowed_at
    ),
    CONSTRAINT chk_loans_return_after_borrow CHECK (
        returned_at IS NULL OR returned_at >= borrowed_at
    ),
    CONSTRAINT chk_loans_status_returned_consistent CHECK (
        (status = 'returned' AND returned_at IS NOT NULL)
        OR (status <> 'returned' AND returned_at IS NULL)
    )
) ENGINE=InnoDB;

-- Proposed history table for the admin interface.
-- Plugin API, event coverage and storage design still need technical validation.
-- old_values/new_values hold JSON-formatted text when available.
CREATE TABLE IF NOT EXISTS audit_events (
    event_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    event_time TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    action ENUM('INSERT', 'UPDATE', 'DELETE') NOT NULL,
    entity_table VARCHAR(64) NOT NULL,
    entity_id VARCHAR(191) NOT NULL,
    database_user VARCHAR(288) NULL,
    application_user_id BIGINT UNSIGNED NULL,
    client_host VARCHAR(255) NULL,
    old_values LONGTEXT NULL,
    new_values LONGTEXT NULL,
    event_source ENUM('application', 'direct_sql', 'unknown')
        NOT NULL DEFAULT 'unknown',
    PRIMARY KEY (event_id),
    KEY idx_audit_time (event_time),
    KEY idx_audit_entity (entity_table, entity_id, event_time),
    KEY idx_audit_app_user (application_user_id, event_time),
    KEY idx_audit_action (action, event_time),
    CONSTRAINT fk_audit_application_user
        FOREIGN KEY (application_user_id) REFERENCES users (user_id)
        ON UPDATE RESTRICT ON DELETE SET NULL,
    CONSTRAINT chk_audit_old_values_json CHECK (
        old_values IS NULL OR JSON_VALID(old_values)
    ),
    CONSTRAINT chk_audit_new_values_json CHECK (
        new_values IS NULL OR JSON_VALID(new_values)
    )
) ENGINE=InnoDB;
