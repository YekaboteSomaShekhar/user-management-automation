#!/bin/bash

set -o pipefail

# Configuration
CRED_DIR="/var/secure"
CRED_FILE="$CRED_DIR/user_passwords.txt"
LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/user_management.log"
PASSWORD_LENGTH=12

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root or via sudo." >&2
  exit 1
fi

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log_info() {
  echo "$(timestamp) [INFO] $*" | tee -a "$LOG_FILE"
}
log_error() {
  echo "$(timestamp) [ERROR] $*" | tee -a "$LOG_FILE" >&2
}
log_warn() {
  echo "$(timestamp) [WARN] $*" | tee -a "$LOG_FILE"
}

mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
touch "$CRED_FILE"
chmod 600 "$CRED_FILE"
chown root:root "$CRED_FILE"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
chown root:root "$LOG_FILE"

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    pw=$(openssl rand -base64 48 | tr -d '/+' | tr -dc 'A-Za-z0-9@%_+=' | head -c "$PASSWORD_LENGTH")
  else
    pw=$(tr -dc 'A-Za-z0-9@%_+=' </dev/urandom | head -c "$PASSWORD_LENGTH")
  fi

  if [[ ${#pw} -lt $PASSWORD_LENGTH ]]; then
    pw=$(printf '%s%s' "$pw" "$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c $((PASSWORD_LENGTH - ${#pw})))")
  fi
  echo "$pw"
}

append_credential() {
  local user="$1"
  local pass="$2"

  if command -v flock >/dev/null 2>&1; then
    (
      flock -n 9 || { log_error "Could not acquire lock to write credentials"; return 1; }
      echo "${user}:${pass}" >>"$CRED_FILE"
    ) 9>"$CRED_FILE"
  else
    echo "${user}:${pass}" >>"$CRED_FILE"
  fi
}

trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo -n "$var"
}

ensure_group() {
  local grp="$1"
  if getent group "$grp" >/dev/null 2>&1; then
    return 0
  fi
  if groupadd "$grp"; then
    log_info "Created group '$grp'."
    return 0
  else
    log_error "Failed to create group '$grp'."
    return 1
  fi
}

process_line() {
  local line="$1"
  line="${line%%#*}"
  line="$(trim "$line")"
  [[ -z "$line" ]] && return 0

  if ! grep -q ';' <<<"$line"; then
    log_warn "Skipping malformed line (no ';'): '$line'"
    return 0
  fi

  local username="${line%%;*}"
  local groups_part="${line#*;}"
  username="$(trim "$username")"
  groups_part="$(trim "$groups_part")"

  if [[ -z "$username" ]]; then
    log_warn "Skipping empty username in line: '$line'"
    return 0
  fi

  IFS=',' read -r -a extra_groups <<<"$groups_part"
  local cleaned_groups=()
  for g in "${extra_groups[@]}"; do
    g="$(trim "$g")"
    [[ -n "$g" ]] && cleaned_groups+=("$g")
  done

  if ! ensure_group "$username"; then
    log_error "Could not ensure primary group '$username' for user '$username'. Skipping user."
    return 1
  fi

  if id "$username" >/dev/null 2>&1; then
    log_info "User '$username' already exists. Will ensure groups, home, and update password."
    user_exists=true
  else
    user_exists=false
  fi

  for grp in "${cleaned_groups[@]}"; do
    if ! ensure_group "$grp"; then
      log_error "Failed to ensure extra group '$grp' for user '$username'. Continuing."
    fi
  done

  if [[ "$user_exists" = false ]]; then
    if useradd -m -g "$username" -s /bin/bash "$username"; then
      log_info "Created user '$username' with primary group '$username'."
    else
      log_error "Failed to create user '$username'. Skipping."
      return 1
    fi
  else
    usermod -g "$username" "$username" >/dev/null 2>&1 || log_warn "Could not set primary group '$username' for existing user '$username'."
  fi

  if [[ ${#cleaned_groups[@]} -gt 0 ]]; then
    local gcsv
    IFS=','; gcsv="${cleaned_groups[*]}"; unset IFS
    if usermod -aG "$gcsv" "$username"; then
      log_info "Added user '$username' to supplementary group(s): $gcsv"
    else
      log_warn "Failed to add user '$username' to groups: $gcsv"
    fi
  fi

  user_home="$(getent passwd "$username" | cut -d: -f6)"
  if [[ -z "$user_home" ]]; then
    log_warn "Could not get home directory for '$username'."
  else
    if [[ ! -d "$user_home" ]]; then
      mkdir -p "$user_home" && log_info "Created home directory '$user_home' for '$username'." || log_warn "Failed to create home '$user_home' for '$username'."
    fi
    chown -R "$username":"$username" "$user_home" || log_warn "Failed to set ownership on $user_home"
    chmod 700 "$user_home" || log_warn "Failed to set permissions on $user_home"
  fi

  password="$(generate_password)"
  if echo "${username}:${password}" | chpasswd; then
    log_info "Set password for user '$username'."
  else
    log_error "Failed to set password for user '$username'. Continuing (credentials not saved)."
    return 1
  fi

  if append_credential "$username" "$password"; then
    log_info "Saved credentials for '$username' to $CRED_FILE."
  else
    log_error "Failed to save credentials for '$username' to $CRED_FILE."
  fi

  echo "User '$username' processed. Credentials stored in $CRED_FILE (root-only)."
}

if [[ $# -ne 1 ]]; then
  echo "Usage: sudo $0 users_list.txt"
  exit 2
fi

INPUT_FILE="$1"
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: Input file '$INPUT_FILE' not found." >&2
  exit 3
fi

while IFS= read -r rawline || [[ -n "$rawline" ]]; do
  trimmed="$(trim "$rawline")"
  if [[ -z "$trimmed" ]] || [[ "${trimmed:0:1}" == "#" ]]; then
    log_info "Skipped line (comment/blank)."
    continue
  fi
  process_line "$rawline"
done <"$INPUT_FILE"

log_info "Processing complete."
exit 0