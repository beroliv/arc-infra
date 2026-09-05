#!/usr/bin/env bash

install_motd() {
  local source="$SOURCE_DIR/10-infra-status"
  local target="/etc/update-motd.d/10-infra-status"
  require_file "$source"
  status "Installing Arc infrastructure login status..."
  install -d -o root -g root -m 0755 /etc/update-motd.d
  if [[ ! -e "$target" ]] || ! cmp --silent -- "$source" "$target"; then
    install -o root -g root -m 0755 -- "$source" "$target"
  else
    chown root:root "$target"
    chmod 0755 "$target"
  fi

  suppress_static_motd
  disable_raspberry_pi_wifi_warning
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
  [[ -x "$target" ]] || die "Arc MOTD is missing or not executable"
  [[ "$(stat -c '%U:%G' "$target")" == "root:root" ]] || die "Arc MOTD is not owned by root"
  cmp --silent -- "$source" "$target" || die "installed Arc MOTD differs from repository version"
  "$target" >/dev/null 2>&1 || die "Arc MOTD does not execute successfully"
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
