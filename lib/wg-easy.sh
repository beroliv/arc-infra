#!/usr/bin/env bash

write_wg_easy_compose() {
  local temp
  temp="$(mktemp)"
  cat >"$temp" <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    restart: unless-stopped
    network_mode: host
    environment:
      INSECURE: "true"
      PORT: "${WG_UI_PORT}"
      TRUSTED_PROXIES: "${TRUSTED_PROXIES:-$NOVA_IP}"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /opt/wg-easy/data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
EOF
  install_file_if_changed "$temp" "$WG_EASY_DIR/compose.yml" 0644
  rm -f -- "$temp"
}

write_compose_files() {
  status "Writing production Compose definitions..."
  write_adguard_compose
  write_wg_easy_compose
}

start_wg_easy() {
  require_file "$WG_EASY_DIR/data/wg-easy.db"
  docker compose -f "$WG_EASY_DIR/compose.yml" config --quiet
  docker compose -f "$WG_EASY_DIR/compose.yml" pull --quiet
  docker compose -f "$WG_EASY_DIR/compose.yml" up -d
}

start_services() {
  status "Starting AdGuard Home from restored configuration..."
  start_adguard
  status "Starting wg-easy from restored production database..."
  start_wg_easy
}
