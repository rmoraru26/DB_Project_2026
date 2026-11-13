#!/usr/bin/env bash
# Reads a password on stdin and prints the value MariaDB stores for
# IDENTIFIED BY '<password>' with the mysql_native_password plugin:
#
#   '*' followed by the upper-case hex of SHA1(SHA1(password))
#
#   printf '%s' "$CAMPUS_APP_PASSWORD" | bash database/native_password_hash.sh
#
# Scripts use it to create accounts with IDENTIFIED BY PASSWORD '<hash>', so
# the password itself never appears in SQL text: whatever characters it
# contains, the statement only ever holds '*' and 40 hex digits.  The result
# is checked against the server's own PASSWORD() function in
# tests/database/test_native_password_hash.sh.
#
# Needs bash and one of sha1sum (Linux, Git for Windows), shasum (macOS) or openssl.

set -eu

sha1_hex() {
    if command -v sha1sum >/dev/null 2>&1; then
        sha1sum
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 1
    else
        openssl dgst -sha1 -r
    fi | cut -c1-40
}

password=$(cat)
if [ -z "$password" ]; then
    echo "native_password_hash.sh: empty password on stdin" >&2
    exit 1
fi

stage1=$(printf '%s' "$password" | sha1_hex)
# The second round hashes the 20 raw bytes of the first digest; printf turns
# the \xHH escapes into bytes (escapes are output as bytes, never re-read as
# format directives, so a 0x25 '%' byte is safe; 0x00 is written as a NUL).
raw_escapes=$(printf '%s' "$stage1" | sed 's/../\\x&/g')
stage2=$(printf "$raw_escapes" | sha1_hex | tr 'a-f' 'A-F')

if ! printf '%s' "$stage2" | grep -Eq '^[0-9A-F]{40}$'; then
    echo "native_password_hash.sh: could not compute SHA-1" >&2
    exit 1
fi
printf '*%s\n' "$stage2"
