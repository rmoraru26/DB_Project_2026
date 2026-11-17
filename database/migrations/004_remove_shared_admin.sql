-- Migration 004: the published demo password must never identify an admin.
-- Preserve the seeded fictional Dana row and all related data, but demote it.
-- Other administrator accounts are untouched. This operation is idempotent.

USE university_resources;

UPDATE users
   SET role = 'student'
 WHERE email = 'dana.admin@example.edu'
   AND role = 'admin';
