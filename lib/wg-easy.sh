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
  if reconcile_wg_easy_container && wait_for_wg_easy_stable 30; then
    success "wg-easy reached stable WireGuard readiness."
    return 0
  fi

  warn "wg-easy did not reach the expected WireGuard state; showing safe diagnostics."
  print_wg_easy_diagnostics
  status "Recreating wg-easy once for recovery..."
  if reconcile_wg_easy_container && wait_for_wg_easy_stable 30; then
    success "wg-easy reached stable WireGuard readiness after recovery."
    return 0
  fi

  print_wg_easy_diagnostics
  die "wg-easy remained unhealthy after one controlled recovery attempt"
}

reconcile_wg_easy_container() {
  require_file "$WG_EASY_DIR/data/wg-easy.db"
  docker compose -f "$WG_EASY_DIR/compose.yml" up -d --force-recreate
}

wg_easy_runtime_ready() {
  local listen_port peer_count
  [[ "$(docker inspect -f '{{.State.Running}}' wg-easy 2>/dev/null || true)" == "true" ]] \
    || return 1
  ip link show wg0 >/dev/null 2>&1 || return 1
  ip -4 -o address show dev wg0 2>/dev/null \
    | awk -v expected="$WG_ADDRESS" '$4 == expected {found=1} END {exit !found}' \
    || return 1
  listen_port="$(wg show wg0 listen-port 2>/dev/null || true)"
  [[ "$listen_port" == "$WG_PORT" ]] || return 1
  peer_count="$( (wg show wg0 peers 2>/dev/null || true) | awk 'NF {count++} END {print count+0}')"
  [[ "$peer_count" == "$EXPECTED_WG_PEERS" ]]
}

wait_for_wg_easy_stable() {
  local max_checks="${1:-30}" consecutive=0 check
  for (( check=1; check<=max_checks; check++ )); do
    if wg_easy_runtime_ready; then
      consecutive=$((consecutive + 1))
      (( consecutive >= 3 )) && return 0
    else
      consecutive=0
    fi
    if (( check < max_checks )); then
      sleep 2
    fi
  done
  return 1
}

print_wg_easy_diagnostics() {
  local container_state="unavailable" interface_state="down"
  local address="unavailable" listen_port="unavailable" peer_count="0"
  container_state="$(docker inspect wg-easy --format '{{.State.Status}}' 2>/dev/null || echo unavailable)"
  if ip link show wg0 >/dev/null 2>&1; then
    interface_state="up"
    address="$(ip -4 -o address show dev wg0 2>/dev/null | awk 'NR==1 {print $4}' || true)"
    address="${address:-unavailable}"
    listen_port="$(wg show wg0 listen-port 2>/dev/null || true)"
    listen_port="${listen_port:-unavailable}"
    peer_count="$( (wg show wg0 peers 2>/dev/null || true) | awk 'NF {count++} END {print count+0}')"
  fi
  warn "wg-easy container=$container_state; wg0=$interface_state; address=$address; port=$listen_port; peers=$peer_count/$EXPECTED_WG_PEERS"
}

start_services() {
  status "Starting AdGuard Home from restored configuration..."
  start_adguard
  status "Starting wg-easy from restored production database..."
  start_wg_easy
}
