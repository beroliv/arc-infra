#!/usr/bin/env bash
set -Eeuo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SOURCE_DIR/lib/common.sh"
# shellcheck source=lib/preflight.sh
source "$SOURCE_DIR/lib/preflight.sh"
# shellcheck source=lib/docker.sh
source "$SOURCE_DIR/lib/docker.sh"
# shellcheck source=lib/restore.sh
source "$SOURCE_DIR/lib/restore.sh"
# shellcheck source=lib/adguard.sh
source "$SOURCE_DIR/lib/adguard.sh"
# shellcheck source=lib/wg-easy.sh
source "$SOURCE_DIR/lib/wg-easy.sh"
# shellcheck source=lib/firewall.sh
source "$SOURCE_DIR/lib/firewall.sh"
# shellcheck source=lib/validate.sh
source "$SOURCE_DIR/lib/validate.sh"

main() {
  require_root
  install_error_trap
  preflight
  detect_install_mode

  if (( FIRST_INSTALL )); then
    mount_recovery
  fi

  install_docker
  configure_sysctl
  disable_legacy_wireguard_service
  prepare_service_directories
  write_compose_files
  restore_production_data
  install_firewall
  start_services
  validate_installation
  persist_installer_snapshot
  mark_installed

  unmount_recovery
  trap - EXIT
  success "Arc infrastructure installation complete."
}

main "$@"
