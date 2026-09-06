#!/usr/bin/env bash

install_motd() {
  local source="$SOURCE_DIR/10-infra-status"
  local target="/etc/update-motd.d/10-infra-status"
  require_file "$source"
  status "Installing infrastructure login status..."
  install -d -o root -g root -m 0755 /etc/update-motd.d
  if [[ ! -e "$target" ]] || ! cmp --silent -- "$source" "$target"; then
    install -o root -g root -m 0755 -- "$source" "$target"
  else
    chown root:root "$target"
    chmod 0755 "$target"
  fi

  install_motd_sudoers
  install_motd_command
  ensure_usr_local_bin_in_login_path
  suppress_static_motd
  disable_raspberry_pi_wifi_warning
}

install_motd_command() {
  local candidate target="/usr/local/bin/motd"
  candidate="$(mktemp)"
  cat >"$candidate" <<'EOF'
#!/usr/bin/env bash
exec sudo -n /etc/update-motd.d/10-infra-status
EOF
  install -d -o root -g root -m 0755 /usr/local/bin
  if [[ ! -e "$target" ]] || ! cmp --silent -- "$candidate" "$target"; then
    install -o root -g root -m 0755 -- "$candidate" "$target"
  else
    chown root:root "$target"
    chmod 0755 "$target"
  fi
  rm -f -- "$candidate"
}

install_motd_sudoers() {
  local admin_user candidate target="/etc/sudoers.d/arc-motd"
  command -v sudo >/dev/null 2>&1 || die "sudo is required for the manual motd command"
  command -v visudo >/dev/null 2>&1 || die "visudo is required to validate the MOTD permission"
  admin_user="$(find_admin_user)"
  [[ "$admin_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] \
    || die "could not identify a safe admin username for the MOTD permission"

  candidate="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: /etc/update-motd.d/10-infra-status\n' \
    "$admin_user" >"$candidate"
  chmod 0440 "$candidate"
  if ! visudo -cf "$candidate" >/dev/null; then
    rm -f -- "$candidate"
    die "generated MOTD sudoers rule is invalid"
  fi

  install -d -o root -g root -m 0755 /etc/sudoers.d
  install -o root -g root -m 0440 -- "$candidate" "$target"
  rm -f -- "$candidate"
  visudo -cf "$target" >/dev/null || die "installed MOTD sudoers rule is invalid"
}

find_admin_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] \
    && getent passwd "$SUDO_USER" >/dev/null 2>&1; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  getent passwd \
    | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ && !found {print $1; found=1}'
}

get_login_path() {
  local admin_user="$1"
  (runuser -l "$admin_user" -c 'printf "\nARC_LOGIN_PATH=%s\n" "$PATH"' 2>/dev/null || true) \
    | sed -n 's/^ARC_LOGIN_PATH=//p' \
    | tail -n1
}

ensure_usr_local_bin_in_login_path() {
  local admin_user login_path candidate profile_file="/etc/profile.d/arc-local-bin.sh"
  admin_user="$(find_admin_user)"
  [[ -n "$admin_user" ]] || die "could not identify a normal admin user for login PATH validation"
  login_path="$(get_login_path "$admin_user")"

  if [[ ":$login_path:" == *:/usr/local/bin:* && ! -e "$profile_file" ]]; then
    return 0
  fi

  [[ -e "$profile_file" ]] \
    || status "Adding /usr/local/bin to the system-wide login PATH..."
  candidate="$(mktemp)"
  cat >"$candidate" <<'EOF'
# Managed by arc-infra. Keep locally managed system commands in login shells.
case ":${PATH:-}:" in
  *:/usr/local/bin:*) ;;
  *) PATH="/usr/local/bin${PATH:+:$PATH}" ;;
esac
export PATH
EOF
  install -o root -g root -m 0644 -- "$candidate" "$profile_file"
  rm -f -- "$candidate"

  login_path="$(get_login_path "$admin_user")"
  [[ ":$login_path:" == *:/usr/local/bin:* ]] \
    || die "system-wide PATH configuration did not add /usr/local/bin for $admin_user"
}

suppress_static_motd() {
  local empty_file
  empty_file="$(mktemp)"
  install -o root -g root -m 0644 -- "$empty_file" /etc/motd
  rm -f -- "$empty_file"
}

disable_raspberry_pi_wifi_warning() {
  local source="/etc/profile.d/wifi-check.sh"
  local disabled="/etc/profile.d/wifi-check.sh.disabled-by-arc-infra"

  [[ -e "$source" ]] || return 0
  if [[ -e "$disabled" ]] && ! cmp --silent -- "$source" "$disabled"; then
    disabled="${disabled}.$(date +%Y%m%d%H%M%S)"
  fi
  mv -- "$source" "$disabled"
}

validate_motd() {
  local source="$SOURCE_DIR/10-infra-status"
  local target="/etc/update-motd.d/10-infra-status"
  local command_target="/usr/local/bin/motd"
  local sudoers_target="/etc/sudoers.d/arc-motd"
  local admin_user login_path manual_output plain_output expected_sudoers
  [[ -x "$target" ]] || die "infrastructure MOTD is missing or not executable"
  [[ "$(stat -c '%U:%G:%a' "$target")" == "root:root:755" ]] \
    || die "infrastructure MOTD ownership or permissions are incorrect"
  cmp --silent -- "$source" "$target" || die "installed MOTD differs from repository version"
  "$target" >/dev/null 2>&1 || die "infrastructure MOTD does not execute successfully"
  [[ -x "$command_target" ]] || die "system-wide motd command is missing or not executable"
  [[ "$(stat -c '%U:%G:%a' "$command_target")" == "root:root:755" ]] \
    || die "system-wide motd command ownership or permissions are incorrect"
  printf '%s\n' '#!/usr/bin/env bash' 'exec sudo -n /etc/update-motd.d/10-infra-status' \
    | cmp --silent -- - "$command_target" \
    || die "system-wide motd command does not invoke the infrastructure MOTD"
  admin_user="$(find_admin_user)"
  [[ -n "$admin_user" ]] || die "could not identify a normal admin user for login PATH validation"
  expected_sudoers="$admin_user ALL=(root) NOPASSWD: /etc/update-motd.d/10-infra-status"
  [[ "$(stat -c '%U:%G:%a' "$sudoers_target")" == "root:root:440" ]] \
    || die "MOTD sudoers ownership or permissions are incorrect"
  grep -Fqx -- "$expected_sudoers" "$sudoers_target" \
    || die "MOTD sudoers permission is not narrowly scoped to the admin user"
  visudo -cf "$sudoers_target" >/dev/null || die "MOTD sudoers permission is invalid"
  runuser -u "$admin_user" -- sudo -n "$target" >/dev/null 2>&1 \
    || die "admin cannot execute the infrastructure MOTD through non-interactive sudo"
  if ! manual_output="$(runuser -u "$admin_user" -- "$command_target" 2>/dev/null)"; then
    die "manual motd command failed for $admin_user"
  fi
  plain_output="$(sed $'s/\033\\[[0-9;]*m//g' <<<"$manual_output")"
  grep -Fqx '  Interface:  wg0 up' <<<"$plain_output" \
    && grep -Fqx "  Address:    $WG_ADDRESS" <<<"$plain_output" \
    && grep -Fqx "  Port:       $WG_PORT" <<<"$plain_output" \
    && grep -Fqx "  Peers:      $EXPECTED_WG_PEERS/$EXPECTED_WG_PEERS" <<<"$plain_output" \
    || die "manual motd command did not report the expected WireGuard state"
  login_path="$(get_login_path "$admin_user")"
  [[ ":$login_path:" == *:/usr/local/bin:* ]] \
    || die "/usr/local/bin is missing from the normal admin login PATH"
  [[ ! -s /etc/motd ]] || die "/etc/motd still contains a static login banner"
  [[ "$(stat -c '%U:%G:%a' /etc/motd)" == "root:root:644" ]] \
    || die "/etc/motd ownership or permissions are incorrect"
  [[ ! -e /etc/profile.d/wifi-check.sh ]] \
    || die "Raspberry Pi rfkill login warning is still enabled"
  grep -Eq '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so' /etc/pam.d/sshd \
    || die "SSH PAM dynamic MOTD support is not enabled"
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | grep -Fqx 'printlastlog yes' \
      || die "OpenSSH Last login display is disabled"
  fi
}
