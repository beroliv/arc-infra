#!/usr/bin/env bash

mount_recovery() {
  status "Locating recovery filesystem..."
  install -d -m 0755 "$RECOVERY_MOUNT"
  if mountpoint -q "$RECOVERY_MOUNT"; then
    status "Using recovery filesystem already mounted at $RECOVERY_MOUNT."
  else
    local device=""
    if [[ -n "$RECOVERY_UUID" ]]; then
      device="$(findfs "UUID=$RECOVERY_UUID" 2>/dev/null || true)"
    fi
    if [[ -z "$device" ]]; then
      device="$(findfs "LABEL=$RECOVERY_LABEL" 2>/dev/null || true)"
    fi
    [[ -n "$device" ]] || die "recovery filesystem LABEL=$RECOVERY_LABEL was not found"
    [[ "$(blkid -s TYPE -o value "$device")" == "ext4" ]] || die "recovery filesystem must be ext4"
    mount -o ro,nosuid,nodev,noexec -- "$device" "$RECOVERY_MOUNT"
    RECOVERY_MOUNTED_BY_INSTALLER=1
  fi

  require_file "$RECOVERY_MOUNT/backup/adguard/AdGuardHome.yaml"
  require_file "$RECOVERY_MOUNT/backup/wg-easy2/wg-easy.db"
  success "Recovery artifacts validated."
}

unmount_recovery() {
  if (( RECOVERY_MOUNTED_BY_INSTALLER )) && mountpoint -q "$RECOVERY_MOUNT"; then
    status "Unmounting recovery filesystem..."
    umount -- "$RECOVERY_MOUNT"
    RECOVERY_MOUNTED_BY_INSTALLER=0
  fi
}

restore_one() {
  local source="$1" target="$2" mode="$3" description="$4"
  require_file "$source"
  if [[ -e "$target" ]]; then
    require_file "$target"
    if cmp --silent -- "$source" "$target"; then
      status "$description was already restored; preserving it."
      return 0
    fi
    die "$target already exists and differs from recovery; refusing to overwrite production data"
  fi
  install -m "$mode" -- "$source" "$target"
  require_file "$target"
}

restore_production_data() {
  local adguard_target="$ADGUARD_DIR/conf/AdGuardHome.yaml"
  local wg_target="$WG_EASY_DIR/data/wg-easy.db"

  if (( FIRST_INSTALL )); then
    status "Restoring production configuration before any container start..."
    restore_one "$RECOVERY_MOUNT/backup/adguard/AdGuardHome.yaml" "$adguard_target" 0600 "AdGuard configuration"
    restore_one "$RECOVERY_MOUNT/backup/wg-easy2/wg-easy.db" "$wg_target" 0600 "wg-easy database"
  else
    require_file "$adguard_target"
    require_file "$wg_target"
    status "Existing AdGuard configuration and wg-easy database validated and preserved."
  fi
  require_file "$wg_target"
}
