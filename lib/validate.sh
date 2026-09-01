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

validate_unattended_upgrades() {
  dpkg-query -W -f='${Status}\n' unattended-upgrades 2>/dev/null \
    | grep -Fxq 'install ok installed' || die "unattended-upgrades package is not installed"
  dpkg-query -W -f='${Status}\n' apt-listchanges 2>/dev/null \
    | grep -Fxq 'install ok installed' || die "apt-listchanges package is not installed"

  local apt_configuration
  apt_configuration="$(apt-config dump)"
  grep -Fqx 'APT::Periodic::Update-Package-Lists "1";' <<<"$apt_configuration" \
    || die "automatic package-list refresh is not enabled"
  grep -Fqx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$apt_configuration" \
    || die "unattended upgrades are not enabled"
  grep -Fqx 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$apt_configuration" \
    || die "automatic reboot is not disabled"
}

validate_firewall() {
  local filter_rules nat_rules managed_rules exception_line internet_line range block_line
  filter_rules="$(nft list table inet arc_filter)"
  nat_rules="$(nft list table ip arc_nat)"
  managed_rules="${filter_rules}"$'\n'"${nat_rules}"

  grep -Eq 'ip saddr 192\.168\.0\.0/24 tcp dport 22 accept' <<<"$filter_rules" \
    || die "firewall lacks LAN SSH access"
  grep -Eq 'ip saddr 192\.168\.0\.0/24 tcp dport 53 accept' <<<"$filter_rules" \
    || die "firewall lacks LAN TCP DNS access"
  grep -Eq 'iifname "wg0" tcp dport 53 accept' <<<"$filter_rules" \
    || die "firewall lacks wg0 TCP DNS access"
  grep -Eq 'ip saddr 192\.168\.0\.0/24 udp dport 53 accept' <<<"$filter_rules" \
    || die "firewall lacks LAN UDP DNS access"
  grep -Eq 'iifname "wg0" udp dport 53 accept' <<<"$filter_rules" \
    || die "firewall lacks wg0 UDP DNS access"
  grep -Eq 'iifname "eth0" udp dport 51825 accept' <<<"$filter_rules" \
    || die "firewall lacks WireGuard UDP 51825 input"
  grep -Eq 'ip saddr 192\.168\.0\.0/24 tcp dport 51821 accept' <<<"$filter_rules" \
    || die "firewall lacks LAN wg-easy UI access"
  ! grep -Eq '(dport (5335|51820)|redirect.*51820)' <<<"$managed_rules" \
    || die "firewall contains an obsolete 5335 or 51820 rule"

  exception_line="$(grep -nE 'iifname "wg0" ip saddr 10\.8\.0\.0/24 ip daddr 192\.168\.0\.195 tcp dport 443 accept' <<<"$filter_rules" | head -n1 | cut -d: -f1)"
  internet_line="$(grep -nE 'iifname "wg0" ip saddr 10\.8\.0\.0/24 oifname "eth0" accept' <<<"$filter_rules" | head -n1 | cut -d: -f1)"
  [[ -n "$exception_line" && -n "$internet_line" ]] \
    || die "firewall lacks the VPN exception or Internet forwarding rule"
  for range in 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16; do
    block_line="$(grep -nF "ip daddr $range drop" <<<"$filter_rules" | head -n1 | cut -d: -f1)"
    [[ -n "$block_line" ]] || die "firewall lacks VPN destination block for $range"
    (( exception_line < block_line && block_line < internet_line )) \
      || die "VPN firewall rule for $range is in an unsafe order"
  done
  grep -Eq 'ip saddr 10\.8\.0\.0/24 oifname "eth0" masquerade' <<<"$nat_rules" \
    || die "firewall lacks WireGuard NAT masquerading"
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
  validate_unattended_upgrades
  validate_firewall
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

  success "Docker, unattended upgrades, nftables policy, AdGuard, wg-easy, WireGuard ($peer_count peers), HTTP and DNS validated."
}
