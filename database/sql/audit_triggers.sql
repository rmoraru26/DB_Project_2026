-- Audit triggers for bookings and loans. Apply after schema.sql.
-- Run only in a development database first.
-- Trigger writes share the source transaction; test audit-failure behaviour.
USE university_resources;

DROP TRIGGER IF EXISTS trg_bookings_ai_audit;
DROP TRIGGER IF EXISTS trg_bookings_au_audit;
DROP TRIGGER IF EXISTS trg_bookings_ad_audit;
DROP TRIGGER IF EXISTS trg_loans_ai_audit;
DROP TRIGGER IF EXISTS trg_loans_au_audit;
DROP TRIGGER IF EXISTS trg_loans_ad_audit;

DELIMITER //
CREATE TRIGGER trg_bookings_ai_audit
AFTER INSERT ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO audit_events (
        event_time, action, entity_table, entity_id,
        database_user, application_user_id, client_host,
        old_values, new_values, event_source
    )
    VALUES (
        CURRENT_TIMESTAMP(6), 'INSERT', 'bookings', CAST(NEW.booking_id AS CHAR),
        CURRENT_USER(), NULL, NULL,
        NULL,
        JSON_OBJECT(
            'booking_id',
            NEW.booking_id,
            'user_id',
            NEW.user_id,
            'room_id',
            NEW.room_id,
            'start_time',
            DATE_FORMAT(NEW.start_time, '%Y-%m-%d %H:%i:%s.%f'),
            'end_time',
            DATE_FORMAT(NEW.end_time, '%Y-%m-%d %H:%i:%s.%f'),
            'status',
            NEW.status,
            'created_at',
            DATE_FORMAT(NEW.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(NEW.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        'unknown'
    );
END//

CREATE TRIGGER trg_bookings_au_audit
AFTER UPDATE ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO audit_events (
        event_time, action, entity_table, entity_id,
        database_user, application_user_id, client_host,
        old_values, new_values, event_source
    )
    VALUES (
        CURRENT_TIMESTAMP(6), 'UPDATE', 'bookings', CAST(NEW.booking_id AS CHAR),
        CURRENT_USER(), NULL, NULL,
        JSON_OBJECT(
            'booking_id',
            OLD.booking_id,
            'user_id',
            OLD.user_id,
            'room_id',
            OLD.room_id,
            'start_time',
            DATE_FORMAT(OLD.start_time, '%Y-%m-%d %H:%i:%s.%f'),
            'end_time',
            DATE_FORMAT(OLD.end_time, '%Y-%m-%d %H:%i:%s.%f'),
            'status',
            OLD.status,
            'created_at',
            DATE_FORMAT(OLD.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(OLD.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        JSON_OBJECT(
            'booking_id',
            NEW.booking_id,
            'user_id',
            NEW.user_id,
            'room_id',
            NEW.room_id,
            'start_time',
            DATE_FORMAT(NEW.start_time, '%Y-%m-%d %H:%i:%s.%f'),
            'end_time',
            DATE_FORMAT(NEW.end_time, '%Y-%m-%d %H:%i:%s.%f'),
            'status',
            NEW.status,
            'created_at',
            DATE_FORMAT(NEW.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(NEW.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        'unknown'
    );
END//

CREATE TRIGGER trg_bookings_ad_audit
AFTER DELETE ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO audit_events (
        event_time, action, entity_table, entity_id,
        database_user, application_user_id, client_host,
        old_values, new_values, event_source
    )
    VALUES (
        CURRENT_TIMESTAMP(6), 'DELETE', 'bookings', CAST(OLD.booking_id AS CHAR),
        CURRENT_USER(), NULL, NULL,
        JSON_OBJECT(
            'booking_id',
            OLD.booking_id,
            'user_id',
            OLD.user_id,
            'room_id',
            OLD.room_id,
            'start_time',
            DATE_FORMAT(OLD.start_time, '%Y-%m-%d %H:%i:%s.%f'),
            'end_time',
            DATE_FORMAT(OLD.end_time, '%Y-%m-%d %H:%i:%s.%f'),
            'status',
            OLD.status,
            'created_at',
            DATE_FORMAT(OLD.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(OLD.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        NULL,
        'unknown'
    );
END//

CREATE TRIGGER trg_loans_ai_audit
AFTER INSERT ON loans
FOR EACH ROW
BEGIN
    INSERT INTO audit_events (
        event_time, action, entity_table, entity_id,
        database_user, application_user_id, client_host,
        old_values, new_values, event_source
    )
    VALUES (
        CURRENT_TIMESTAMP(6), 'INSERT', 'loans', CAST(NEW.loan_id AS CHAR),
        CURRENT_USER(), NULL, NULL,
        NULL,
        JSON_OBJECT(
            'loan_id',
            NEW.loan_id,
            'user_id',
            NEW.user_id,
            'item_id',
            NEW.item_id,
            'borrowed_at',
            DATE_FORMAT(NEW.borrowed_at, '%Y-%m-%d %H:%i:%s.%f'),
            'due_at',
            IF(NEW.due_at IS NULL, NULL, DATE_FORMAT(NEW.due_at, '%Y-%m-%d %H:%i:%s.%f')),
            'returned_at',
            IF(NEW.returned_at IS NULL, NULL, DATE_FORMAT(NEW.returned_at, '%Y-%m-%d %H:%i:%s.%f')),
            'status',
            NEW.status,
            'created_at',
            DATE_FORMAT(NEW.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(NEW.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        'unknown'
    );
END//

CREATE TRIGGER trg_loans_au_audit
AFTER UPDATE ON loans
FOR EACH ROW
BEGIN
    INSERT INTO audit_events (
        event_time, action, entity_table, entity_id,
        database_user, application_user_id, client_host,
        old_values, new_values, event_source
    )
    VALUES (
        CURRENT_TIMESTAMP(6), 'UPDATE', 'loans', CAST(NEW.loan_id AS CHAR),
        CURRENT_USER(), NULL, NULL,
        JSON_OBJECT(
            'loan_id',
            OLD.loan_id,
            'user_id',
            OLD.user_id,
            'item_id',
            OLD.item_id,
            'borrowed_at',
            DATE_FORMAT(OLD.borrowed_at, '%Y-%m-%d %H:%i:%s.%f'),
            'due_at',
            IF(OLD.due_at IS NULL, NULL, DATE_FORMAT(OLD.due_at, '%Y-%m-%d %H:%i:%s.%f')),
            'returned_at',
            IF(OLD.returned_at IS NULL, NULL, DATE_FORMAT(OLD.returned_at, '%Y-%m-%d %H:%i:%s.%f')),
            'status',
            OLD.status,
            'created_at',
            DATE_FORMAT(OLD.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(OLD.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        JSON_OBJECT(
            'loan_id',
            NEW.loan_id,
            'user_id',
            NEW.user_id,
            'item_id',
            NEW.item_id,
            'borrowed_at',
            DATE_FORMAT(NEW.borrowed_at, '%Y-%m-%d %H:%i:%s.%f'),
            'due_at',
            IF(NEW.due_at IS NULL, NULL, DATE_FORMAT(NEW.due_at, '%Y-%m-%d %H:%i:%s.%f')),
            'returned_at',
            IF(NEW.returned_at IS NULL, NULL, DATE_FORMAT(NEW.returned_at, '%Y-%m-%d %H:%i:%s.%f')),
            'status',
            NEW.status,
            'created_at',
            DATE_FORMAT(NEW.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(NEW.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        'unknown'
    );
END//

CREATE TRIGGER trg_loans_ad_audit
AFTER DELETE ON loans
FOR EACH ROW
BEGIN
    INSERT INTO audit_events (
        event_time, action, entity_table, entity_id,
        database_user, application_user_id, client_host,
        old_values, new_values, event_source
    )
    VALUES (
        CURRENT_TIMESTAMP(6), 'DELETE', 'loans', CAST(OLD.loan_id AS CHAR),
        CURRENT_USER(), NULL, NULL,
        JSON_OBJECT(
            'loan_id',
            OLD.loan_id,
            'user_id',
            OLD.user_id,
            'item_id',
            OLD.item_id,
            'borrowed_at',
            DATE_FORMAT(OLD.borrowed_at, '%Y-%m-%d %H:%i:%s.%f'),
            'due_at',
            IF(OLD.due_at IS NULL, NULL, DATE_FORMAT(OLD.due_at, '%Y-%m-%d %H:%i:%s.%f')),
            'returned_at',
            IF(OLD.returned_at IS NULL, NULL, DATE_FORMAT(OLD.returned_at, '%Y-%m-%d %H:%i:%s.%f')),
            'status',
            OLD.status,
            'created_at',
            DATE_FORMAT(OLD.created_at, '%Y-%m-%d %H:%i:%s.%f'),
            'updated_at',
            DATE_FORMAT(OLD.updated_at, '%Y-%m-%d %H:%i:%s.%f')
        ),
        NULL,
        'unknown'
    );
END//

DELIMITER ;
