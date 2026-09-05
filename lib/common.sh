#!/usr/bin/env bash

readonly ARC_STATE_DIR="/opt/arc-infra"
readonly INSTALL_MARKER="$ARC_STATE_DIR/.installed"
readonly ADGUARD_DIR="/opt/adguard"
readonly WG_EASY_DIR="/opt/wg-easy"
readonly RECOVERY_MOUNT="/mnt/infra-recovery"
readonly RECOVERY_LABEL="${RECOVERY_LABEL:-INFRA-RECOVERY}"
readonly RECOVERY_UUID="${RECOVERY_UUID:-}"
readonly EXPECTED_WG_PEERS="${EXPECTED_WG_PEERS:-9}"
readonly ARC_LAN_IP="192.168.0.193"
readonly ARC_LAN_CIDR="192.168.0.0/24"
readonly ARC_LAN_INTERFACE="eth0"
readonly NOVA_IP="192.168.0.195"
readonly WG_CIDR="10.8.0.0/24"
readonly WG_ADDRESS="10.8.0.1/24"
readonly WG_PORT="51825"
readonly WG_UI_PORT="51821"

FIRST_INSTALL=0
RECOVERY_MOUNTED_BY_INSTALLER=0

status() { printf '[arc] %s\n' "$*"; }
success() { printf '[arc] OK: %s\n' "$*"; }
warn() { printf '[arc] WARNING: %s\n' "$*" >&2; }
die() { printf '[arc] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  (( EUID == 0 )) || die "installer must run as root"
}

install_error_trap() {
  trap 'rc=$?; printf "[arc] ERROR: installation failed at line %s (exit %s).\n" "$LINENO" "$rc" >&2; unmount_recovery || true; exit "$rc"' ERR
  trap 'unmount_recovery || true' EXIT
}

require_file() {
  [[ -s "$1" ]] || die "required file is missing or empty: $1"
}

install_file_if_changed() {
  local source="$1" target="$2" mode="$3"
  if [[ -e "$target" ]] && cmp --silent -- "$source" "$target"; then
    return 0
  fi
  install -D -m "$mode" -- "$source" "$target"
}

detect_install_mode() {
  mkdir -p -- "$ARC_STATE_DIR"
  if [[ -f "$INSTALL_MARKER" ]]; then
    FIRST_INSTALL=0
    status "Existing installation detected; production data will be preserved."
  else
    FIRST_INSTALL=1
    status "First installation detected; recovery restore is mandatory."
  fi
}

prepare_service_directories() {
  install -d -m 0750 "$ADGUARD_DIR/work" "$ADGUARD_DIR/conf" "$WG_EASY_DIR/data"
}

persist_installer_snapshot() {
  local target="$ARC_STATE_DIR/source"
  install -d -m 0755 "$target" "$target/lib"
  install -m 0755 "$SOURCE_DIR/bootstrap.sh" "$SOURCE_DIR/install.sh" "$target/"
  install -m 0755 "$SOURCE_DIR/10-infra-status" "$target/"
  install -m 0644 "$SOURCE_DIR"/lib/*.sh "$target/lib/"
  install -m 0644 "$SOURCE_DIR/README.md" "$SOURCE_DIR/SPECIFICATION.md" "$target/"
}

mark_installed() {
  printf 'installed_at=%s\n' "$(date --iso-8601=seconds)" >"$INSTALL_MARKER"
  chmod 0600 "$INSTALL_MARKER"
}
