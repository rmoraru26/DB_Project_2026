#!/usr/bin/env bash
# Which audit-API fields campus_audit uses exist in which MariaDB release?  Reads the official
# include/mysql/plugin_audit.h at five release tags from github.com/MariaDB/server (raw files, no
# credentials) and prints the interface version and, per event struct, the fields the plugin reads
# that are not in every release.
#   bash docs/evidence/cycle3/scripts/compare_audit_headers.sh
set -u
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "# $(date -u +%FT%TZ) include/mysql/plugin_audit.h at the release tags (github.com/MariaDB/server)"
printf '%-9s %-9s %-12s %-12s %-12s %-12s %-12s %s\n' tag version gen.database gen.query_id gen.port tab.query_id conn.port conn.tls_version
for v in 10.11.15 11.4.9 11.8.9 12.0.2 13.0.2; do
    f=$tmp/$v.h
    code=$(curl -s -o "$f" -w '%{http_code}' "https://raw.githubusercontent.com/MariaDB/server/mariadb-$v/include/mysql/plugin_audit.h")
    [ "$code" = 200 ] || { echo "$v: HTTP $code"; continue; }
    ver=$(sed -n 's/^#define MYSQL_AUDIT_INTERFACE_VERSION \(0x[0-9a-fA-F]*\).*/\1/p' "$f")
    has() { sed -n "/^struct $1/,/^};/p" "$f" | grep -qE "[ *]$2;" && echo yes || echo NO; }
    printf '%-9s %-9s %-12s %-12s %-12s %-12s %-12s %s\n' "$v" "$ver" \
        "$(has mysql_event_general database)" "$(has mysql_event_general query_id)" "$(has mysql_event_general port)" \
        "$(has mysql_event_table query_id)" "$(has mysql_event_connection port)" "$(has mysql_event_connection tls_version)"
done
echo "campus_audit reads: gen.database, gen.query_id, tab.query_id (required); conn.port and conn.tls_version"
echo "(recorded as null when the headers are older than 0x0303); it does not read gen.port."
