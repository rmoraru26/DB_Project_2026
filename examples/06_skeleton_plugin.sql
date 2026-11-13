-- 06  Write your own: the smallest audit plugin, loaded next to campus_audit.
--
-- Shows:  examples/skeleton_plugin/skeleton_audit.cpp (about 60 lines without
--         comments).  The server calls every installed audit plugin for every
--         event of the classes it subscribed to, so the counters grow with
--         every statement, table access and login.
-- Needs:  skeleton_audit.so / skeleton_audit.dll in @@plugin_dir (the Docker
--         image contains it; natively build it as in
--         examples/skeleton_plugin/README.md).  Administrator connection.
-- Run with:  mariadb --force --table -uroot -p < examples/06_skeleton_plugin.sql
-- Real output: docs/evidence/windows-2026-11-03/12-skeleton-plugin.txt

INSTALL SONAME 'skeleton_audit';

-- Two audit plugins are now ACTIVE; the server notifies both, in turn.
SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY, PLUGIN_MATURITY
  FROM information_schema.PLUGINS WHERE PLUGIN_TYPE = 'AUDIT';

SHOW GLOBAL STATUS LIKE 'skeleton\_audit\_%';

-- One statement that opens one table ...
SELECT COUNT(*) AS rooms FROM university_resources.rooms;

-- ... moved the counters: several GENERAL events per statement (subclasses
-- LOG, RESULT, STATUS, also for the SHOW statements themselves) and one TABLE
-- event for the opened table.  campus_audit filters and formats these same
-- events; the skeleton only counts them.
SHOW GLOBAL STATUS LIKE 'skeleton\_audit\_%';

UNINSTALL SONAME 'skeleton_audit';
