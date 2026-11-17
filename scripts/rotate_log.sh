#!/usr/bin/env bash
# Rotates the campus_audit log without losing or duplicating a record, and
# imports log files of any size.
#
#   make rotate-log                         rotate, then import both files
#   make import-log FILE=<path>             import one existing file (no rotation)
#   docker compose exec -T mariadb bash /usr/local/share/campus/scripts/rotate_log.sh [--import <path>]
#
# Runs INSIDE the mariadb container (it renames a file in the server's log
# directory), as root, with the administrator password of the service
# (scripts/mariadb_admin_auth.sh).  On a native server run it on the server
# host as a user who may rename the log file, with MYSQL_PWD set.
#
# Why: campus_audit.import_plugin_log() reads a complete file with
# LOAD_FILE().  Measured on 13.0.2 (docs/evidence/phase1/post-audit/):
#
#   * LOAD_FILE() returns NULL, with warning 1301, for a file whose size is
#     greater than OR EQUAL TO the connection's max_allowed_packet;
#   * the SESSION value of max_allowed_packet is read-only (ER 1621); SET
#     GLOBAL changes it only for connections opened afterwards;
#   * the GLOBAL value is at most 1073741824 (1 GiB) and is rounded down to a
#     multiple of 1024.
#
# A file at or above the limit -- an archive made from a log that had already
# grown too large, or any file of 1 GiB or more -- therefore cannot be read in
# one call.  This script checks the size of every file BEFORE it imports it:
#
#   * size < limit: one CALL import_plugin_log(<file>);
#   * size >= limit: the file is copied into line-aligned parts that are each
#     below the limit (a record is one line and is never split), the parts are
#     imported one after the other and then removed.  The file itself is only
#     read, never changed.  The primary key (instance, seq) makes the result
#     identical to a single import, and a repeated import adds nothing.
#   * a single line at or above the limit cannot be imported by any means
#     short of raising the limit: the script stops BEFORE importing anything
#     and says so.
#
# How the rotation loses nothing:
#   1. rename the active file to <name>-<UTC time>.jsonl.  The plugin keeps
#      writing to the renamed file through its open descriptor;
#   2. SET GLOBAL campus_audit_reopen_now = ON: the plugin closes that
#      descriptor and opens the configured path again, which creates a new,
#      empty file.  Every record is in exactly one of the two files;
#   3. import the archived file completely (in parts if necessary), then the
#      new one.
#
# Failures.  The active log is never left renamed without being reopened.  The
# archived file is never deleted or modified; if its import fails, the message
# names the `--import` command that retries it (safe to repeat).  Only the
# temporary part files this script created are removed.  Parts need free disk
# space of about the size of the file, in the file's own directory (which must
# be readable for LOAD_FILE(), i.e. inside secure_file_priv).
#
# If the plugin cannot create the new file (step 2 fails, e.g. the log
# directory is not writable for the server), it has already closed its
# descriptor and is DEGRADED: records are counted in
# Campus_audit_events_dropped and announced by an audit_gap record once
# writing resumes (fail-open, docs/design-decisions.md).  The script then
# renames the archive back and reopens that original file at once, and says
# whether the plugin is ACTIVE again.
#
# The archived files stay in the log directory.  They are no longer needed by
# the database once they were imported; keep or delete them according to your
# retention rules (this script never deletes a log or an archive).
#
# Exit status: 0 rotated and imported (or imported); 1 failure (the message
# says how far it got and what to run next); 2 usage or credentials.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/mariadb_admin_auth.sh"

mode=rotate
import_target=
case "${1:-}" in
    "") ;;
    --import)
        [ $# -eq 2 ] && [ -n "$2" ] || { echo "Usage: rotate_log.sh [--import <file>]" >&2; exit 2; }
        mode=import; import_target=$2 ;;
    *) echo "Usage: rotate_log.sh [--import <file>]" >&2; exit 2 ;;
esac

ADMIN_USER=${DB_ADMIN_USER:-root}
frantastic_require_admin_password "$ADMIN_USER" rotate_log || exit 2
CLIENT=(${MARIADB_CLIENT:-mariadb})
sql() { printf '%s\n' "$1" | "${CLIENT[@]}" -u"$ADMIN_USER" --batch --skip-column-names; }
fail() { echo "rotate_log: $*" >&2; exit 1; }

parts_dir=
cleanup_parts() { if [ -n "$parts_dir" ] && [ -d "$parts_dir" ]; then rm -rf -- "$parts_dir"; fi; parts_dir=; }
trap cleanup_parts EXIT

# import_file <path>: prints "<lines>\t<invalid>\t<new>" summed over all calls,
# or returns 1 with the reason on stderr.  Nothing is imported when the file
# cannot be imported completely for a reason that is known in advance.
import_file() {
    local file=$1 limit size longest part_size result lines=0 invalid=0 new=0 part n
    case "$file" in *"'"*|*'\'*) echo "the path '$file' contains a quote or backslash" >&2; return 1 ;; esac
    [ -f "$file" ] && [ ! -L "$file" ] || { echo "'$file' is not a regular file on this machine" >&2; return 1; }
    # A new connection's session value equals the GLOBAL value at that moment.
    limit=$(sql "SELECT @@SESSION.max_allowed_packet;") || { echo "cannot query the server" >&2; return 1; }
    size=$(stat -c %s -- "$file")
    if [ "$size" -lt "$limit" ]; then
        result=$(sql "CALL campus_audit.import_plugin_log('$file');") || return 1
        printf '%s' "$result" | awk -F'\t' '{print $2 "\t" $3 "\t" $4}'
        return 0
    fi
    # Too large for one LOAD_FILE().  Every part must stay strictly below the
    # limit; 1 KiB of headroom keeps a part well clear of it.
    part_size=$(( limit - 1024 ))
    # Byte lengths (C locale), +1 for the newline that ends each line.
    longest=$(LC_ALL=C awk '{ if (length($0) + 1 > m) m = length($0) + 1 } END { print m + 0 }' "$file")
    if [ "$longest" -gt "$part_size" ]; then
        echo "'$file' contains a line of $longest bytes, which no import below max_allowed_packet = $limit can read." >&2
        echo "  Nothing was imported.  Raise the limit above that line (SET GLOBAL max_allowed_packet = <bytes>, at most 1073741824; it applies to new connections), then run: rotate_log.sh --import '$file'" >&2
        return 1
    fi
    echo "'$file' has $size bytes, at or above max_allowed_packet = $limit: importing it in line-aligned parts of at most $part_size bytes (the file itself is not changed)." >&2
    parts_dir=$(mktemp -d "$(dirname -- "$file")/.import-parts.XXXXXXXX") \
        || { echo "cannot create a directory for the parts next to '$file'" >&2; return 1; }
    # The server (user mysql) must be able to read the parts: LOAD_FILE()
    # requires a file readable by all.  The log directory keeps others out.
    chmod 0755 "$parts_dir"
    if ! split -C "$part_size" -d -a 6 -- "$file" "$parts_dir/part-"; then
        cleanup_parts
        echo "could not write the parts of '$file' (disk space?); nothing was imported" >&2
        return 1
    fi
    chmod 0644 "$parts_dir"/part-*
    n=0
    for part in "$parts_dir"/part-*; do
        n=$((n + 1))
        if ! result=$(sql "CALL campus_audit.import_plugin_log('$part');"); then
            cleanup_parts
            echo "part $n of '$file' could not be imported; the parts before it were imported (re-importing them is harmless)" >&2
            return 1
        fi
        read -r lines invalid new <<EOF
$(printf '%s' "$result" | awk -F'\t' -v l="$lines" -v i="$invalid" -v w="$new" '{print l + $2, i + $3, w + $4}')
EOF
    done
    cleanup_parts
    echo "Imported '$file' in $n parts." >&2
    printf '%s\t%s\t%s\n' "$lines" "$invalid" "$new"
}
summary() { printf '%s' "$1" | awk -F'\t' '{print $1 " lines, " $2 " invalid, " $3 " new"}'; }

state=$(sql "SELECT PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'campus_audit';") \
    || fail "cannot query the server"

if [ "$mode" = import ]; then
    counts=$(import_file "$import_target") \
        || fail "'$import_target' was not imported completely; it is unchanged.  Fix the cause above and run the same command again (safe to repeat)."
    echo "Imported $import_target: $(summary "$counts")"
    exit 0
fi

[ "$state" = ACTIVE ] || fail "the campus_audit plugin is not ACTIVE; nothing to rotate"
path=$(sql "SELECT IF(@@GLOBAL.campus_audit_file_path LIKE '/%', @@GLOBAL.campus_audit_file_path, CONCAT(@@GLOBAL.datadir, @@GLOBAL.campus_audit_file_path));")
[ -n "$path" ] && [ -f "$path" ] || fail "the active log file '$path' is not a regular file on this machine (run the script where the server runs)"
case "$path" in
    *.jsonl) archive="${path%.jsonl}-$(date -u +%Y%m%dT%H%M%SZ).jsonl" ;;
    *)       archive="$path-$(date -u +%Y%m%dT%H%M%SZ)" ;;
esac
[ ! -e "$archive" ] || fail "'$archive' exists already; wait a second and retry"
case "$archive" in *"'"*|*'\'*) fail "the log path contains a quote or backslash; rotate it by hand" ;; esac

size=$(stat -c %s "$path")
mv -- "$path" "$archive" || fail "could not rename the active log"
if ! sql "SET GLOBAL campus_audit_reopen_now = ON;" >/dev/null 2>&1 || [ ! -f "$path" ]; then
    # The reopen closed the plugin's descriptor and failed, so the plugin is
    # DEGRADED and writes nothing.  Put the name back and reopen that file:
    # it exists, so no new file has to be created in the directory.
    [ -e "$path" ] || mv -- "$archive" "$path"
    sql "SET GLOBAL campus_audit_reopen_now = ON;" >/dev/null 2>&1
    state=$(sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'CAMPUS_AUDIT_STATE';" 2>/dev/null)
    if [ "$state" = ACTIVE ]; then
        fail "the plugin could not create a new log file; the rename was undone and the plugin writes to $path again (records of the failed moment are counted in Campus_audit_events_dropped and announced by an audit_gap record)"
    fi
    fail "the plugin could not create a new log file and could not reopen $path either (state: ${state:-unknown}); it retries on the next event every 5 seconds.  Fix the cause (permissions of the log directory), then SET GLOBAL campus_audit_reopen_now = ON"
fi
echo "Rotated: $archive ($size bytes); the plugin now writes to $path"

archived=$(import_file "$archive") \
    || fail "the archived file could not be imported; it is kept unchanged at $archive.  Fix the cause above, then run: rotate_log.sh --import '$archive'   (make import-log FILE=$archive; safe to repeat)"
current=$(import_file "$path") \
    || fail "the new log could not be imported; the archived file was imported.  Retry with: rotate_log.sh --import '$path'"
echo "Imported the archived file: $(summary "$archived")"
echo "Imported the new file:      $(summary "$current")"
echo "The archived file is no longer needed by the database; keep or remove it according to your retention rules."
