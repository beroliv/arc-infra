#!/usr/bin/env bash

write_adguard_compose() {
  local temp
  temp="$(mktemp)"
  cat >"$temp" <<'EOF'
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/adguard/work:/opt/adguardhome/work
      - /opt/adguard/conf:/opt/adguardhome/conf
EOF
  install_file_if_changed "$temp" "$ADGUARD_DIR/compose.yml" 0644
  rm -f -- "$temp"
}

start_adguard() {
  require_file "$ADGUARD_DIR/conf/AdGuardHome.yaml"
  docker compose -f "$ADGUARD_DIR/compose.yml" config --quiet
  docker compose -f "$ADGUARD_DIR/compose.yml" pull --quiet
  docker compose -f "$ADGUARD_DIR/compose.yml" up -d
}
