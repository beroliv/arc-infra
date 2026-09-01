#!/usr/bin/env bash

configure_unattended_upgrades() {
  status "Configuring unattended Debian security upgrades..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    unattended-upgrades apt-listchanges >/dev/null

  local periodic_candidate policy_candidate
  periodic_candidate="$(mktemp)"
  policy_candidate="$(mktemp)"

  cat >"$periodic_candidate" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  cat >"$policy_candidate" <<'EOF'
// Managed by arc-infra. Install Debian stable and security updates unattended.
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename},label=Debian";
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// Arc is never rebooted automatically.
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  install_file_if_changed "$periodic_candidate" /etc/apt/apt.conf.d/20auto-upgrades 0644
  install_file_if_changed "$policy_candidate" /etc/apt/apt.conf.d/52arc-unattended-upgrades 0644
  rm -f -- "$periodic_candidate" "$policy_candidate"
}
