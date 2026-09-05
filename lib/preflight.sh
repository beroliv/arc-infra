#!/usr/bin/env bash

preflight() {
  status "Running preflight checks..."
  [[ -r /etc/os-release ]] || die "/etc/os-release is unavailable"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "Debian is required (found ${ID:-unknown})"
  [[ "${VERSION_ID:-}" == "13" ]] || die "Debian 13 is required (found ${VERSION_ID:-unknown})"
  [[ "$(dpkg --print-architecture)" == "arm64" ]] || die "arm64 is required"
  ip link show "$ARC_LAN_INTERFACE" >/dev/null 2>&1 || die "LAN interface $ARC_LAN_INTERFACE does not exist"

  local required
  for required in \
    bootstrap.sh install.sh 10-infra-status README.md SPECIFICATION.md \
    lib/common.sh lib/preflight.sh lib/docker.sh lib/upgrades.sh lib/motd.sh lib/restore.sh \
    lib/adguard.sh lib/wg-easy.sh lib/firewall.sh lib/validate.sh; do
    require_file "$SOURCE_DIR/$required"
  done

  protect_active_ssh_session
  success "Preflight checks passed."
}

protect_active_ssh_session() {
  [[ -z "${SSH_CONNECTION:-}" ]] && return 0
  local source_ip="${SSH_CONNECTION%% *}"
  case "$source_ip" in
    192.168.0.*|10.8.0.*) return 0 ;;
    *) die "active SSH client $source_ip is outside the firewall's allowed LAN/VPN ranges; refusing to risk lockout" ;;
  esac
}

disable_legacy_wireguard_service() {
  if systemctl list-unit-files 'wg-quick@wg0.service' --no-legend 2>/dev/null | grep -q 'wg-quick@wg0.service'; then
    status "Disabling legacy wg-quick@wg0.service..."
    systemctl disable 'wg-quick@wg0.service' >/dev/null 2>&1 || true
    if systemctl is-active --quiet 'wg-quick@wg0.service'; then
      if [[ "$(docker inspect -f '{{.State.Running}}' wg-easy 2>/dev/null || true)" == "true" ]]; then
        warn "wg-quick and wg-easy both appear active; leaving wg0 untouched during this run"
      else
        status "Stopping the active legacy wg-quick unit before wg-easy takes ownership..."
        systemctl stop 'wg-quick@wg0.service'
      fi
    fi
    systemctl mask 'wg-quick@wg0.service' >/dev/null
  fi
}

configure_sysctl() {
  status "Configuring persistent forwarding..."
  install -d -m 0755 /etc/sysctl.d
  local temp
  temp="$(mktemp)"
  cat >"$temp" <<'EOF'
# Managed by arc-infra. IPv6 remains enabled for restored wg-easy configurations.
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
  install_file_if_changed "$temp" /etc/sysctl.d/90-wireguard.conf 0644
  rm -f -- "$temp"
  sysctl --system >/dev/null
}
