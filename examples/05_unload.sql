-- 05  Unload the plugin cleanly, and load it again.
--
-- Shows:  the shutdown path of the plugin: a final plugin_stop record with the
--         counters, then the library can be replaced or deleted.
-- Needs:  01 installed.  Administrator connection.
-- Run with:  mariadb --force -uroot -p < examples/05_unload.sql

-- Writes a plugin_stop record (counters of this instance) and closes the file.
UNINSTALL SONAME 'campus_audit';

-- Gone from the active plugins:
SELECT COUNT(*) AS still_active
  FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';          -- 0

-- A second UNINSTALL is an error:  [ERROR 1305] SONAME campus_audit.so does not exist (.dll on Windows)
UNINSTALL SONAME 'campus_audit';

-- Load it again: a new instance id and a plugin_start record in the same file.
INSTALL SONAME 'campus_audit';
SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS
 WHERE PLUGIN_NAME = 'campus_audit';

-- Installing a library that does not exist fails cleanly (server keeps running):
--   INSTALL SONAME 'campus_audit_missing';     -- [ERROR 1126] Can't open shared library
