#!/usr/bin/env bash
# Provides the per-installation demo student (demo.student@frantastic.local)
# and keeps its local credential file consistent with MariaDB.
#
#   bash scripts/bootstrap_demo.sh            ordinary start (make up)
#   bash scripts/bootstrap_demo.sh --reset    explicit rotation (make reset-demo)
#
# The repository contains no demo password.  On the first start one is
# generated in the web container (frontend/bootstrap_demo.py, `secrets`),
# hashed there with Werkzeug, stored as a hash by migration 007's procedure,
# and written in plain text only to .demo-credentials (mode 0600, git-ignored):
#
#     line 1  demo.student@frantastic.local
#     line 2  the password
#
# Rules of the ordinary start.  It never rotates a password and never
# overwrites a credential file whose password still works:
#
#   file  account in MariaDB       action
#   ----  -----------------------  ---------------------------------------------
#   no    missing                  generate, create the account, save the file
#   yes   matches the file         nothing ("valid; no rotation performed")
#   yes   missing                  create the account with the SAVED password
#                                  (database volume re-created; file reused)
#   no    exists                   NOTHING is changed; the recovery is printed
#   yes   exists, does not match   NOTHING is changed; the recovery is printed
#
# The last two rows are reported, not failed: the application is fully usable
# (registration works), only the convenience login is unavailable on this
# machine.  The explicit recovery is `make reset-demo`.
#
# Interrupted runs.  The new password is written to .demo-credentials.pending
# BEFORE MariaDB is changed and promoted to .demo-credentials only after the
# account has been verified with it.  A later start finishes or discards a
# leftover pending file according to what MariaDB actually holds, so the
# script can be re-run after any failure.
#
# Passwords travel in environment variables (docker compose exec -e NAME) and
# are never placed on a command line or printed.
#
# Exit status: 0 done or nothing to do (including the two reported rows),
# 1 failure (nothing was half-applied: see the message), 2 usage.
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=${1:-start}
if [[ "$mode" == --reset ]]; then mode=rotate; fi
if [[ "$mode" != start && "$mode" != rotate ]]; then
  echo "Usage: scripts/bootstrap_demo.sh [--reset]" >&2; exit 2
fi

DEMO_EMAIL=demo.student@frantastic.local
PASSWORD_PATTERN='^[A-Za-z0-9_-]{20,}$'
COMPOSE=(${COMPOSE:-docker compose})
credential_name=${FRANTASTIC_DEMO_CREDENTIAL_FILE:-.demo-credentials}
credential_file=$credential_name
pending_file="${credential_file}.pending"
[[ "$credential_file" = /* ]] || credential_file="$PWD/$credential_file"
[[ "$pending_file" = /* ]] || pending_file="$PWD/$pending_file"

fail() { echo "Demo student setup: $*" >&2; exit 1; }
recovery() {
  cat <<EOF
  To issue a new demo password for THIS database (replaces the stored hash and
  writes a new $credential_name):   make reset-demo
  Without it the application is unaffected: register an account on /register.
EOF
}
location() {
  echo "Demo student login: $DEMO_EMAIL; password on line 2 of $credential_name (private local file; not printed)."
}

# Prints the password of a well-formed, private credential file; fails otherwise.
read_credential() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ $(stat -c '%u:%h' "$path") == "$(id -u):1" ]] || return 1
  chmod 600 -- "$path" || return 1
  [[ $(stat -c '%a' "$path") == 600 ]] || return 1
  local -a lines=()
  mapfile -t lines < "$path"
  [[ ${#lines[@]} -eq 2 ]] || return 1
  lines[0]=${lines[0]%$'\r'}
  lines[1]=${lines[1]%$'\r'}
  [[ "${lines[0]}" == "$DEMO_EMAIL" && "${lines[1]}" =~ $PASSWORD_PATTERN ]] || return 1
  printf '%s' "${lines[1]}"
}
write_protected() {
  local path=$1 password=$2 temp
  mkdir -p "$(dirname "$path")"
  [[ ! -L "$path" ]] || fail "refusing to replace a symbolic link: $path"
  temp=$(mktemp "${path}.tmp.XXXXXXXX") || fail "cannot create a protected temporary credential file"
  chmod 600 "$temp" || { rm -f -- "$temp"; fail "cannot protect the temporary credential file"; }
  if ! printf '%s\n%s\n' "$DEMO_EMAIL" "$password" > "$temp"; then
    rm -f -- "$temp"; fail "cannot write the temporary credential file"
  fi
  chmod 600 "$temp" && mv -fT -- "$temp" "$path" || { rm -f -- "$temp"; fail "cannot atomically save the credential file"; }
  [[ $(stat -c '%a' "$path") == 600 && ! -L "$path" ]] || fail "credential file permissions could not be verified"
}

# "<role> <is_active>" of the account, or "MISSING -".
db_state() {
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD mariadb bash /usr/local/share/campus/scripts/provision_local_demo_db.sh state | tr -d '\r'
}
# db_action bootstrap|rotate <password>: prints the procedure's result word.
db_action() {
  local action=$1 password=$2 hash pattern='^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$'
  hash=$(FRANTASTIC_DEMO_PASSWORD="$password" "${COMPOSE[@]}" exec -T -e FRANTASTIC_DEMO_PASSWORD web python /app/bootstrap_demo.py --hash-environment | tr -d '\r')
  [[ "$hash" =~ $pattern ]] || fail "password hash generation failed"
  FRANTASTIC_DEMO_HASH=$hash "${COMPOSE[@]}" exec -T -e MYSQL_PWD -e FRANTASTIC_DEMO_HASH mariadb bash /usr/local/share/campus/scripts/provision_local_demo_db.sh "$action" | tr -d '\r'
}
# check <password>: MATCH, MISMATCH, MISSING, NOT_STUDENT or INACTIVE, as the
# login route would decide it (the web container reads the row as campus_app).
check() {
  FRANTASTIC_DEMO_PASSWORD="$1" "${COMPOSE[@]}" exec -T -e FRANTASTIC_DEMO_PASSWORD web python /app/bootstrap_demo.py --check-environment | tr -d '\r'
}
new_password() {
  local password
  password=$("${COMPOSE[@]}" exec -T web python /app/bootstrap_demo.py --password-only | tr -d '\r')
  [[ "$password" =~ $PASSWORD_PATTERN ]] || fail "password generation failed"
  printf '%s' "$password"
}
promote_pending() {
  local password
  password=$(read_credential "$pending_file") || fail "the pending credential file is malformed; it was preserved"
  write_protected "$credential_file" "$password"
  rm -f -- "$pending_file"
}
# create_account <password> <file that holds it>: insert the row, then prove the login.
create_account() {
  local result
  result=$(db_action bootstrap "$1") || fail "the account could not be created; $2 was preserved"
  [[ "$result" == CREATED || "$result" == EXISTS ]] || fail "unexpected answer from MariaDB while creating the account; $2 was preserved"
  [[ "$(check "$1")" == MATCH ]] || fail "the new account did not authenticate; $2 was preserved"
}

state=$(db_state) || fail "cannot inspect the demo account; the database may not be ready"
read -r role active <<< "$state"
[[ -n "${role:-}" ]] || fail "the database returned an invalid demo-account state"
if [[ "$role" != MISSING && "$role" != student ]]; then
  fail "$DEMO_EMAIL is not a student account in this database; refusing to manage it"
fi

if [[ "$mode" == rotate ]]; then
  password=$(new_password)
  write_protected "$pending_file" "$password"
  if [[ "$role" == student ]]; then
    result=$(db_action rotate "$password") || fail "the database update failed; the protected pending file was retained"
    [[ "$result" == ROTATED ]] || fail "MariaDB did not rotate the demo password ($result); the protected pending file was retained"
  else
    result=$(db_action bootstrap "$password") || fail "the account could not be created; the protected pending file was retained"
    [[ "$result" == CREATED ]] || fail "MariaDB did not create the demo account ($result); the protected pending file was retained"
  fi
  verdict=$(check "$password") || fail "the new password could not be verified; the protected pending file was retained"
  [[ "$verdict" != INACTIVE ]] || fail "the demo account is deactivated (is_active = 0); the new password is stored but cannot log in until an administrator reactivates the account"
  [[ "$verdict" == MATCH ]] || fail "the new password did not authenticate ($verdict); the protected pending file was retained"
  promote_pending
  [[ "$(check "$password")" == MATCH ]] || fail "the saved credential could not be verified after promotion"
  echo "Demo student password was rotated and verified."
  location
  exit 0
fi

# A pending file means an earlier run stopped between "password written" and
# "file promoted".  MariaDB decides which of the two passwords is the real one.
if [[ -e "$pending_file" ]]; then
  pending_password=$(read_credential "$pending_file") || fail "the pending credential file is malformed or not private; it was preserved (remove it only after checking $credential_name)"
  verdict=$(check "$pending_password") || fail "cannot verify the pending credential; it was preserved"
  if [[ "$verdict" == MATCH || "$verdict" == INACTIVE ]]; then
    promote_pending
    echo "Completed an interrupted demo-credential update (the database already held the new password)."
  elif [[ "$verdict" == MISSING ]]; then
    create_account "$pending_password" "the pending file"
    promote_pending
    echo "Completed an interrupted demo-student bootstrap."
  elif [[ -e "$credential_file" ]] && final_password=$(read_credential "$credential_file") && [[ "$(check "$final_password")" == MATCH ]]; then
    rm -f -- "$pending_file"
    echo "Discarded an interrupted demo-credential update that never reached the database."
  else
    echo "Demo student setup: an interrupted credential update cannot be reconciled automatically." >&2
    echo "  Nothing was changed; $credential_name and its .pending file were preserved." >&2
    recovery >&2
    exit 1
  fi
  state=$(db_state) || fail "cannot re-check the demo account"
  read -r role active <<< "$state"
fi

if [[ -e "$credential_file" ]]; then
  password=$(read_credential "$credential_file") || fail "$credential_name is malformed, a link, or not private to this user; it was preserved and nothing was changed"
  verdict=$(check "$password") || fail "cannot verify $credential_name against MariaDB"
  case "$verdict" in
    MATCH)
      echo "Demo student credential is valid; no rotation performed."
      location; exit 0 ;;
    MISSING)
      create_account "$password" "$credential_name"
      echo "Demo student was created in this database with the saved local credential."
      location; exit 0 ;;
    INACTIVE)
      echo "NOTICE: the demo student account is deactivated in this database (is_active = 0)."
      echo "  Nothing was changed; the password in $credential_name is correct but cannot log in."
      exit 0 ;;
    *)
      echo "NOTICE: $credential_name does not match the demo student stored in this database"
      echo "  (the password was changed in the web app, or the file belongs to another database)."
      echo "  Nothing was changed: neither the file nor the stored password."
      recovery; exit 0 ;;
  esac
fi

if [[ "$role" != MISSING ]]; then
  echo "NOTICE: this database already has the demo student $DEMO_EMAIL,"
  echo "  but its credential file $credential_name is not on this machine."
  echo "  The stored password was NOT changed and no file was written."
  recovery
  exit 0
fi

password=$(new_password)
write_protected "$pending_file" "$password"
create_account "$password" "the protected pending file"
promote_pending
[[ "$(check "$password")" == MATCH ]] || fail "the saved demo credential could not be verified"
echo "Demo student was created and verified (role: student)."
location
