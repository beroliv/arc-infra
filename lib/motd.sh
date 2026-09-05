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
}

validate_motd() {
  local source="$SOURCE_DIR/10-infra-status"
  local target="/etc/update-motd.d/10-infra-status"
  [[ -x "$target" ]] || die "Arc MOTD is missing or not executable"
  [[ "$(stat -c '%U:%G' "$target")" == "root:root" ]] || die "Arc MOTD is not owned by root"
  cmp --silent -- "$source" "$target" || die "installed Arc MOTD differs from repository version"
  "$target" >/dev/null 2>&1 || die "Arc MOTD does not execute successfully"
}
