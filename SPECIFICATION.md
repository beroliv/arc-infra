# Arc appliance specification

## Scope

Arc is a Raspberry Pi / arm64 appliance running Debian 13. It provides AdGuard Home
DNS and an existing wg-easy v15 WireGuard deployment. Docker provides lifecycle and
process isolation; the host owns packet filtering, forwarding and NAT through
nftables. Debian security and stable updates are installed unattended without an
automatic reboot.

This repository does not configure the host's static address. The host must already
have the intended address and interface before installation.

## Fixed network identity

| Property | Value |
| --- | --- |
| Arc LAN address | `192.168.0.193` |
| LAN | `192.168.0.0/24` |
| LAN interface | `eth0` |
| Nova reverse proxy | `192.168.0.195` |
| WireGuard network | `10.8.0.0/24` |
| WireGuard server address | `10.8.0.1/24` |
| WireGuard UDP port | `51825` |
| wg-easy UI | TCP `51821` |
| WireGuard server MTU | `1420` in restored state |
| Existing client MTU | `1200` in existing client state |

Nova proxies `https://wg-easy2.lan` to `http://192.168.0.193:51821`. Caddy remains on
Nova and is out of scope.

## Non-negotiable invariants

1. The production `wg-easy.db` is restored and validated before the first wg-easy
   container start. An absent or empty database aborts installation.
2. Existing WireGuard server and client identities are preserved unchanged. The
   installer never generates clients, keys, preshared keys or a new server identity.
3. `wg0.conf` is not authoritative restore state. wg-easy v15 generates it from its
   database.
4. Both services use Docker host networking and persistent bind mounts under `/opt`.
5. Host nftables exclusively owns WireGuard filtering and NAT. The deployment does
   not depend on legacy `ip_tables` PostUp/PostDown rules.
6. PiVPN, Unbound, Caddy and `wg-quick@wg0.service` are not installed or used.
7. Nothing listens on Unbound port 5335.
8. The recovery filesystem is located by filesystem UUID or `INFRA-RECOVERY` label,
   never by `/dev/sdX`, and is mounted read-only.
9. Sensitive database contents, private keys, preshared keys and client configs are
   never printed by installation or validation.
10. Existing production data is never silently overwritten.
11. Login status is local-only and never emits WireGuard key material or makes network
    calls.

## Recovery contract

The ext4 recovery filesystem contains:

```text
/backup/adguard/AdGuardHome.yaml
/backup/wg-easy2/wg-easy.db
```

On the first installation both must exist and have non-zero size. The destinations
are `/opt/adguard/conf/AdGuardHome.yaml` and
`/opt/wg-easy/data/wg-easy.db`. A partial first installation may be resumed only when
an existing destination is identical to its recovery source. Once the installation
marker exists, recovery media is not consulted and both local files are preserved.

## Container contract

AdGuard Home uses `adguard/adguardhome:latest`, host networking, and these mounts:

- `/opt/adguard/work:/opt/adguardhome/work`
- `/opt/adguard/conf:/opt/adguardhome/conf`

wg-easy uses `ghcr.io/wg-easy/wg-easy:15`, host networking, and:

- `INSECURE=true`
- `PORT=51821`
- `TRUSTED_PROXIES=192.168.0.195` by default
- capabilities `NET_ADMIN` and `SYS_MODULE`
- `/dev/net/tun`
- `/opt/wg-easy/data:/etc/wireguard`
- `/lib/modules:/lib/modules:ro`

No Compose `ports:` entries are allowed with host networking.

## Host firewall contract

The managed `inet arc_filter` table has default-drop input and forward chains.
Input accepts established/related traffic, loopback, IPv4 and IPv6 ICMP, LAN/VPN SSH,
LAN/VPN DNS, WireGuard UDP 51825 on `eth0`, and the wg-easy UI on TCP 51821 from
`192.168.0.0/24` for direct maintenance and recovery. It contains no TCP/UDP 51820
rule, no 51825-to-51820 redirect, and no TCP/UDP 5335 rule.

Forwarding accepts established/related flows, then applies this ordered VPN policy:

1. Accept `10.8.0.0/24` to `192.168.0.195:443/tcp`.
2. Drop VPN traffic to `10.0.0.0/8`, `100.64.0.0/10`, `169.254.0.0/16`,
   `172.16.0.0/12`, and `192.168.0.0/16`.
3. Accept remaining VPN traffic leaving through `eth0`.

The `ip arc_nat` table masquerades `10.8.0.0/24` through `eth0`. The configuration is
syntax-checked before installation and does not flush or mutate Docker-managed tables.
The installer refuses to activate the policy from an SSH source outside the intended
LAN or VPN ranges.

Host nftables is authoritative. wg-easy does not own Arc filtering or NAT and does not
depend on legacy iptables PostUp/PostDown rules. The ordered exception permits VPN
clients to reach Nova HTTPS at `192.168.0.195:443`; the following drops prevent other
private/local access, while the final accept and NAT rule retain normal Internet
access.

## Unattended upgrades

The installer installs `unattended-upgrades` and `apt-listchanges`. The managed
`/etc/apt/apt.conf.d/20auto-upgrades` enables daily package-list refresh and unattended
installation. `/etc/apt/apt.conf.d/52arc-unattended-upgrades` limits the managed
origins to the current Debian stable and security suites and explicitly sets
`Unattended-Upgrade::Automatic-Reboot "false";`. Reconciliation replaces these managed
files instead of appending duplicate entries.

## Infrastructure MOTD

The repository file `10-infra-status` is installed as the root-owned executable
`/etc/update-motd.d/10-infra-status`. It is reconciled on every first installation and
rerun without changing unrelated Debian MOTD entries. An interactive login displays:

- the current hostname, owner and repository management notice;
- uptime, load and `/run/reboot-required` state;
- root filesystem utilization, RAM and Raspberry Pi temperature when available;
- systemd state for Docker, nftables and unattended-upgrades;
- actual state/status for exactly the `adguard` and `wg-easy` containers; and
- `wg0` interface state, address, listen port and peer count against expected values.

Disk status is yellow from 80% and red from 90%. Temperature is yellow from 60°C and
red from 75°C. Temperature detection prefers `vcgencmd` and falls back to Linux's
thermal sysfs. Missing optional commands, services or interfaces produce a concise
unavailable/not-installed state and never fail login. The script has no network checks
and only invokes WireGuard subcommands that return the listen port or peer identifiers
for counting; it never prints their output or any key.

## Persistent kernel configuration

`/etc/sysctl.d/90-wireguard.conf` enables:

```text
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
```

IPv6 remains enabled so the restored wg-easy configuration can retain a generated
IPv6 interface address if it expects one.

## Successful-install criteria

Installation succeeds only when Docker and nftables are active and enabled, unattended
upgrades and package refresh are enabled without automatic reboot, the installed MOTD
matches the repository version, is executable, root-owned and exits successfully, the
effective firewall contains the required ordered input/forward/NAT policy, both containers run,
`wg0` has `10.8.0.1/24`, WireGuard listens on UDP 51825, exactly nine peers exist by
default, TCP 51821 and TCP/UDP 53 listen, wg-easy returns a local HTTP response, a local
DNS query succeeds, port 5335 is unused, the legacy wg-quick unit is not enabled, and
the restored database remains non-empty.
