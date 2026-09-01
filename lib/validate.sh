#!/usr/bin/env bash

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local count
  for (( count=1; count<=attempts; count++ )); do
    "$@" && return 0
    sleep "$delay"
  done
  return 1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

http_ready() {
  curl --silent --show-error --output /dev/null --max-time 3 "http://127.0.0.1:${WG_UI_PORT}/"
}

dns_ready() {
  dig +time=2 +tries=1 @127.0.0.1 example.com A | grep -q '^;; ANSWER SECTION:'
}

validate_installation() {
  status "Waiting for services and running read-only validation..."
  retry 30 2 container_running adguard || die "AdGuard container is not running"
  retry 30 2 container_running wg-easy || die "wg-easy container is not running"
  retry 30 2 ip link show wg0 >/dev/null 2>&1 || die "wg0 was not created"

  systemctl is-active --quiet docker || die "Docker is not active"
  systemctl is-enabled --quiet docker || die "Docker is not enabled"
  systemctl is-active --quiet nftables || die "nftables is not active"
  systemctl is-enabled --quiet nftables || die "nftables is not enabled"
  ip -4 -o address show dev wg0 | grep -Fq "inet $WG_ADDRESS" || die "wg0 does not have $WG_ADDRESS"

  local listen_port peer_count
  listen_port="$(wg show wg0 listen-port)"
  [[ "$listen_port" == "$WG_PORT" ]] || die "wg0 listens on unexpected UDP port $listen_port"
  peer_count="$(wg show wg0 peers | awk 'NF { count++ } END { print count+0 }')"
  (( peer_count > 0 )) || die "wg0 has no peers"
  [[ "$peer_count" == "$EXPECTED_WG_PEERS" ]] || die "wg0 has $peer_count peers; expected $EXPECTED_WG_PEERS"

  ss -H -ltn "sport = :$WG_UI_PORT" | grep -q . || die "TCP $WG_UI_PORT is not listening"
  ss -H -lun "sport = :$WG_PORT" | grep -q . || die "UDP $WG_PORT is not listening"
  ss -H -ltn "sport = :53" | grep -q . || die "TCP 53 is not listening"
  ss -H -lun "sport = :53" | grep -q . || die "UDP 53 is not listening"
  ! ss -H -lntu | awk '{print $5}' | grep -Eq '(^|[.:])5335$' || die "a service is unexpectedly listening on port 5335"
  retry 30 2 http_ready || die "wg-easy UI did not return an HTTP response"
  retry 30 2 dns_ready || die "DNS query against Arc failed"
  ! systemctl is-enabled --quiet 'wg-quick@wg0.service' 2>/dev/null || die "wg-quick@wg0.service is still enabled"
  require_file "$WG_EASY_DIR/data/wg-easy.db"

  success "Docker, nftables, AdGuard, wg-easy, WireGuard ($peer_count peers), HTTP and DNS validated."
}
