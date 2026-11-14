-- 01  Install the plugin and prove that it is active.
--
-- Shows:  INSTALL SONAME, the plugin type AUDIT in information_schema.PLUGINS,
--         the system variables and the status variables the plugin registers.
-- Needs:  an administrator connection (INSTALL SONAME needs INSERT on mysql.plugin)
--         and campus_audit.so / campus_audit.dll in @@plugin_dir.
--         The server must allow a BETA plugin: plugin_maturity=beta (see README).
-- Real output of every statement here: docs/evidence/demo-windows.txt, step 1.

-- Installing an already installed plugin library is a silent no-op
-- (INSTALL PLUGIN campus_audit SONAME ... would fail with ER 1968).
INSTALL SONAME 'campus_audit';

-- PLUGIN_STATUS must be ACTIVE and PLUGIN_TYPE must be AUDIT.
-- PLUGIN_MATURITY is Beta: that is why the server needs plugin_maturity=beta.
SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY, PLUGIN_MATURITY, PLUGIN_AUTH_VERSION
  FROM information_schema.PLUGINS
 WHERE PLUGIN_NAME = 'campus_audit';

-- Eight system variables (see README "Configuration reference"); all are dynamic
-- except campus_audit_readable_by_all, a startup option.
SHOW GLOBAL VARIABLES LIKE 'campus\_audit\_%';

-- Eleven status variables.  Campus_audit_state is ACTIVE, DEGRADED or CLOSED.
SHOW GLOBAL STATUS LIKE 'Campus\_audit\_%';

-- If INSTALL fails, the error number tells you why:
--   ER 1126  "Loading of beta plugin ... is prohibited by --plugin-maturity=gamma"
--            -> add plugin_maturity=beta to [mysqld] and restart
--   ER 1126  "Can't open shared library"
--            -> the file is not in SELECT @@plugin_dir, or it is for another platform
