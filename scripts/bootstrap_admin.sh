#!/usr/bin/env bash
# Reconcile the local administrator credential with MariaDB without rotating
# credentials during ordinary startup. Passwords are never passed in argv/logs.
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=${1:-start}
if [[ "$mode" == --reset ]]; then mode=rotate; fi
if [[ "$mode" != start && "$mode" != rotate ]]; then
  echo "Usage: scripts/bootstrap_admin.sh [--reset]" >&2; exit 2
fi

credential_file=${FRANTASTIC_ADMIN_CREDENTIAL_FILE:-.admin-credentials}
pending_file="${credential_file}.pending"
[[ "$credential_file" = /* ]] || credential_file="$PWD/$credential_file"
[[ "$pending_file" = /* ]] || pending_file="$PWD/$pending_file"

fail() { echo "Administrator setup: $*" >&2; exit 1; }
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
  [[ ${#lines[@]} -eq 2 && "${lines[0]}" == admin@frantastic.local && "${lines[1]}" =~ ^[A-Za-z0-9_-]{40,}$ ]] || return 1
  printf '%s\n%s' "${lines[0]}" "${lines[1]}"
}
write_protected() {
  local path=$1 password=$2 temp
  mkdir -p "$(dirname "$path")"
  [[ ! -L "$path" ]] || fail "refusing to replace a symbolic link: $path"
  temp=$(mktemp "${path}.tmp.XXXXXXXX") || fail "cannot create a protected temporary credential file"
  chmod 600 "$temp" || { rm -f -- "$temp"; fail "cannot protect temporary credential file"; }
  if ! printf 'admin@frantastic.local\n%s\n' "$password" > "$temp"; then
    rm -f -- "$temp"; fail "cannot write temporary credential file"
  fi
  chmod 600 "$temp" && mv -fT -- "$temp" "$path" || { rm -f -- "$temp"; fail "cannot atomically save credential file"; }
  [[ $(stat -c '%a' "$path") == 600 && ! -L "$path" ]] || fail "credential file permissions could not be verified"
}

state() { docker compose exec -T -e MYSQL_PWD mariadb bash /usr/local/share/campus/scripts/provision_local_admin_db.sh state; }
db_action() {
  local action=$1 password=$2 hash pattern='^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$'
  hash=$(FRANTASTIC_ADMIN_PASSWORD="$password" docker compose exec -T -e FRANTASTIC_ADMIN_PASSWORD web python /app/bootstrap_admin.py --hash-environment)
  [[ "$hash" =~ $pattern ]] || fail "password hash generation failed"
  FRANTASTIC_ADMIN_HASH=$hash docker compose exec -T -e MYSQL_PWD -e FRANTASTIC_ADMIN_HASH mariadb bash /usr/local/share/campus/scripts/provision_local_admin_db.sh "$action"
}
matches_db() {
  local password=$1 result
  result=$(FRANTASTIC_ADMIN_PASSWORD="$password" docker compose exec -T -e FRANTASTIC_ADMIN_PASSWORD web python /app/bootstrap_admin.py --check-environment)
  [[ "$result" == MATCH ]]
}
promote_pending() {
  local parsed password
  parsed=$(read_credential "$pending_file") || fail "pending credential file is malformed; preserve it and use the documented recovery procedure"
  password=${parsed#*$'\n'}
  write_protected "$credential_file" "$password"
  rm -f -- "$pending_file"
}
new_password() {
  docker compose exec -T web python /app/bootstrap_admin.py --password-only
}

# The compose root password is loaded by Make before calling us. Protect files
# before any Docker operation that could create administrator state.
if [[ -n "${MYSQL_PWD:-}" ]]; then :; fi

if [[ "$mode" == rotate ]]; then
  local_state=$(state) || fail "cannot inspect administrator state"
  read -r _ admins canonical <<< "$local_state"
  [[ "$canonical" == admin ]] || { [[ "$admins" == 0 ]] || fail "the canonical local administrator is absent while other administrators exist; use an authorised DBA recovery procedure"; }
  password=$(new_password)
  write_protected "$pending_file" "$password"
  action=rotate; [[ "$canonical" == admin ]] || action=bootstrap-force
  db_action "$action" "$password" || fail "database credential update failed; the protected pending file was retained"
  matches_db "$password" || fail "database update could not be verified; the protected pending file was retained"
  promote_pending
  matches_db "$password" || fail "saved credential verification failed after promotion"
  echo "Local administrator credential was rotated and verified."
  exit 0
fi

local_state=$(state) || fail "cannot inspect administrator state; database may not be ready"
read -r pending admins canonical <<< "$local_state"
[[ -n "$pending" && -n "$admins" && -n "$canonical" ]] || fail "database returned an invalid administrator state"

# A pending file is written before changing MariaDB. Resolve interrupted work
# only when it authenticates or can safely complete the one-time bootstrap.
if [[ -e "$pending_file" ]]; then
  parsed=$(read_credential "$pending_file") || fail "pending credential file is malformed; preserve it and use the documented recovery procedure"
  pending_password=${parsed#*$'\n'}
  if matches_db "$pending_password"; then
    promote_pending
  elif [[ "$admins" == 0 && "$canonical" == MISSING && "$pending" == 1 ]]; then
    db_action bootstrap "$pending_password" || fail "pending bootstrap failed; protected pending file was retained"
    matches_db "$pending_password" || fail "pending bootstrap did not authenticate; protected pending file was retained"
    promote_pending
  elif [[ -e "$credential_file" ]] && parsed_final=$(read_credential "$credential_file") && matches_db "${parsed_final#*$'\n'}"; then
    rm -f -- "$pending_file"
  else
    fail "an interrupted credential update cannot be reconciled automatically; preserve both files and use the documented DBA recovery procedure"
  fi
  local_state=$(state) || fail "cannot recheck administrator state"
  read -r pending admins canonical <<< "$local_state"
fi

if [[ -e "$credential_file" ]]; then
  parsed=$(read_credential "$credential_file") || fail "credential file is malformed or insecure; use the explicit reset-admin command only after confirming the database state"
  password=${parsed#*$'\n'}
  if matches_db "$password"; then
    chmod 600 "$credential_file" || fail "cannot enforce credential file mode 0600"
    echo "Local administrator credential is valid; no rotation performed."
    exit 0
  fi
  if [[ "$admins" == 0 && "$canonical" == MISSING && "$pending" == 1 ]]; then
    db_action bootstrap "$password" || fail "fresh-database bootstrap failed; existing local credential was preserved"
    matches_db "$password" || fail "fresh-database bootstrap did not authenticate; existing local credential was preserved"
    chmod 600 "$credential_file"; echo "Fresh database was reconciled with the saved local credential."; exit 0
  fi
  fail "saved credential does not match the existing administrator; no password or account was changed"
fi

if [[ "$admins" != 0 || "$canonical" != MISSING || "$pending" != 1 ]]; then
  fail "no local credential exists for an existing or closed administrator state; no account was created (use an authorised DBA recovery procedure)"
fi

password=$(new_password)
write_protected "$pending_file" "$password"
db_action bootstrap "$password" || fail "administrator provisioning failed; protected pending credential was retained"
matches_db "$password" || fail "new administrator authentication failed; protected pending credential was retained"
promote_pending
matches_db "$password" || fail "saved administrator credential could not be verified"
echo "First local administrator was provisioned and verified. Credential saved in .admin-credentials (not displayed)."
