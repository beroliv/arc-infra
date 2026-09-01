#!/usr/bin/env bash

install_firewall() {
  status "Installing host nftables firewall..."
  local candidate backup=""
  candidate="$(mktemp)"
  cat >"$candidate" <<EOF
#!/usr/sbin/nft -f
# Managed by arc-infra. Docker-managed tables are intentionally untouched.

table inet arc_filter
delete table inet arc_filter
table inet arc_filter {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "lo" accept
    meta l4proto ipv6-icmp accept
    ip protocol icmp accept
    iifname "${ARC_LAN_INTERFACE}" ip saddr ${ARC_LAN_CIDR} tcp dport 22 accept
    iifname "wg0" tcp dport 22 accept
    iifname "${ARC_LAN_INTERFACE}" ip saddr ${ARC_LAN_CIDR} udp dport 53 accept
    iifname "${ARC_LAN_INTERFACE}" ip saddr ${ARC_LAN_CIDR} tcp dport 53 accept
    iifname "wg0" udp dport 53 accept
    iifname "wg0" tcp dport 53 accept
    iifname "${ARC_LAN_INTERFACE}" udp dport ${WG_PORT} accept
    ip saddr ${NOVA_IP} tcp dport ${WG_UI_PORT} accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "wg0" ip saddr ${WG_CIDR} ip daddr ${NOVA_IP} tcp dport 443 accept
    iifname "wg0" ip saddr ${WG_CIDR} ip daddr 10.0.0.0/8 drop
    iifname "wg0" ip saddr ${WG_CIDR} ip daddr 100.64.0.0/10 drop
    iifname "wg0" ip saddr ${WG_CIDR} ip daddr 169.254.0.0/16 drop
    iifname "wg0" ip saddr ${WG_CIDR} ip daddr 172.16.0.0/12 drop
    iifname "wg0" ip saddr ${WG_CIDR} ip daddr 192.168.0.0/16 drop
    iifname "wg0" ip saddr ${WG_CIDR} oifname "${ARC_LAN_INTERFACE}" accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}

table ip arc_nat
delete table ip arc_nat
table ip arc_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${WG_CIDR} oifname "${ARC_LAN_INTERFACE}" masquerade
  }
}
EOF

  nft -c -f "$candidate" || die "generated nftables configuration failed syntax validation"
  if [[ -e /etc/nftables.conf ]]; then
    backup="/etc/nftables.conf.arc-infra-backup.$(date +%Y%m%d%H%M%S)"
    cp -a -- /etc/nftables.conf "$backup"
  fi
  install -m 0644 "$candidate" /etc/nftables.conf
  rm -f -- "$candidate"

  if ! nft -f /etc/nftables.conf; then
    [[ -n "$backup" ]] && cp -a -- "$backup" /etc/nftables.conf
    die "could not activate nftables configuration"
  fi
  systemctl enable nftables >/dev/null
  # Do not restart an already-active unit: Debian's stop action can flush the
  # complete ruleset, including tables owned by Docker. The rules above are live.
  systemctl is-active --quiet nftables || systemctl start nftables
}
