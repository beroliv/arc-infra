# Arc infrastructure appliance

Production installer for the Arc Raspberry Pi appliance: AdGuard Home, wg-easy v15,
Docker Engine, unattended Debian upgrades and an nftables firewall on Debian 13 arm64.

## Install

Prepare an ext4 filesystem labelled `INFRA-RECOVERY`. It must contain these two
non-empty production artifacts:

```text
backup/adguard/AdGuardHome.yaml
backup/wg-easy2/wg-easy.db
```

The WireGuard database contains private identities. Store and transport the recovery
filesystem accordingly; the installer never displays its contents.

On a fresh Debian 13 arm64 host connected as `192.168.0.193` on `eth0`, attach the
recovery filesystem and run:

```bash
curl -fsSL https://raw.githubusercontent.com/beroliv/arc-infra/main/bootstrap.sh | sudo bash
```

The bootstrap is deliberately small: it downloads the current `main` archive to a
temporary directory, checks that `install.sh` exists, and hands control to it. The
installer rejects non-Debian-13 and non-arm64 systems. If the recovery label is not
available, its UUID can be supplied explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/beroliv/arc-infra/main/bootstrap.sh \
  | sudo RECOVERY_UUID=00000000-0000-0000-0000-000000000000 bash
```

Environment passed through `sudo` depends on the local sudo policy. An alternative is
to become root first and then export `RECOVERY_UUID` before running the command.

## First-install sequence

The ordering is a safety invariant, not merely an implementation detail:

1. Verify Debian 13, arm64, `eth0`, repository files, and the active SSH source.
2. Locate the ext4 recovery filesystem by UUID (when supplied) or label and mount it
   read-only at `/mnt/infra-recovery`.
3. Validate both recovery artifacts before making service changes.
4. Install Docker Engine and Compose from Docker's official Debian repository.
5. Configure daily package-list refresh and unattended Debian stable/security updates
   without automatic reboots.
6. Persist forwarding sysctls and disable/mask legacy `wg-quick@wg0.service`.
7. Create the `/opt` directories and both production Compose definitions.
8. Restore AdGuard configuration and the sensitive wg-easy database into their final
   bind mounts.
9. Validate the restored files again.
10. Syntax-check and load the host nftables policy.
11. Start AdGuard and only then start wg-easy from its restored database.
12. Validate upgrades, firewall rules, containers, sockets, DNS, HTTP, `wg0`, port and
    all nine peers.
13. Save the installer snapshot, write `/opt/arc-infra/.installed`, and cleanly
    unmount a recovery filesystem mounted by the installer.

wg-easy is never started before `/opt/wg-easy/data/wg-easy.db` is non-empty. It is
therefore never given an opportunity to generate a replacement server identity on a
first install.

## Architecture

Both containers use host networking. There are no Docker `ports:` mappings.

| Component | Persistent state | Host endpoints |
| --- | --- | --- |
| AdGuard Home | `/opt/adguard/work`, `/opt/adguard/conf` | TCP/UDP 53 |
| wg-easy 15 | `/opt/wg-easy/data` mounted at `/etc/wireguard` | UDP 51825, TCP 51821 |
| nftables | `/etc/nftables.conf` | Host input, forwarding and NAT |
| sysctl | `/etc/sysctl.d/90-wireguard.conf` | IPv4 forwarding and source mark |

The authoritative host nftables firewall permits DNS from the LAN and VPN, SSH from
the LAN and VPN, and WireGuard on `eth0`. The wg-easy UI on TCP 51821 is directly
reachable from `192.168.0.0/24` for maintenance and recovery; Nova still terminates
`https://wg-easy2.lan`. VPN clients may reach Nova (`192.168.0.195`) on TCP 443 and the
public Internet, but other private, carrier-grade NAT and link-local IPv4 ranges are
blocked. The host masquerades `10.8.0.0/24` through `eth0`. There are no 51820 redirect
rules and no 5335 rules.

Arc does not install Caddy, PiVPN, Unbound, or `wg-quick@wg0.service`. wg-easy creates
`wg0` from its v15 database; host nftables owns VPN filtering and NAT. IPv6 is not
blindly disabled, so restored wg-easy state may continue to use it.

Arc installs Debian stable and security updates automatically through
`unattended-upgrades`. Package lists and unattended upgrades run daily. Automatic
reboots are explicitly disabled, so kernel or other reboot-requiring updates remain
pending until an administrator deliberately reboots Arc.

See [SPECIFICATION.md](SPECIFICATION.md) for the fixed addresses and security
invariants.

## Reruns and upgrades

Run the same one-line command again. When `/opt/arc-infra/.installed` exists, the
installer requires the existing AdGuard YAML and wg-easy database and preserves both.
It does not require or copy from the recovery filesystem, regenerate identities, or
delete service state. It reconciles packages, Compose definitions, sysctl, firewall,
containers and validations.

If a first run stopped after restoring a file but before writing the marker, the next
run accepts that target only when it is byte-for-byte identical to the recovery copy.
A different existing file causes a hard stop rather than an overwrite.

`TRUSTED_PROXIES` defaults to `192.168.0.195`; set it in the root environment to
override it. `EXPECTED_WG_PEERS` defaults to `9` and may be changed deliberately for
a later production topology.

## Disaster recovery

1. Install a fresh Debian 13 arm64 image and configure Arc's fixed LAN address and
   interface outside this repository.
2. Attach the protected `INFRA-RECOVERY` filesystem.
3. Confirm the two required backup paths and that they are non-empty. Do not inspect
   or publish the database contents.
4. Run the one-line installer.
5. Keep the recovery filesystem disconnected after the successful unmount.
6. From the LAN, verify DNS. Through Nova, verify `https://wg-easy2.lan`. Test one
   existing client without recreating or downloading its configuration.

The installer does not restore `wg0.conf`; wg-easy v15 regenerates it from the restored
database.

## Failure and recovery

Errors include the failing line and leave no success marker. A recovery filesystem
mounted by the installer is unmounted on normal exit and on handled errors. If the
host loses power, verify its mount state with `findmnt /mnt/infra-recovery` before
removing it.

Useful read-only diagnostics:

```bash
sudo systemctl status docker nftables
sudo docker compose -f /opt/adguard/compose.yml ps
sudo docker compose -f /opt/wg-easy/compose.yml ps
sudo wg show wg0
sudo nft list table inet arc_filter
sudo nft list table ip arc_nat
```

`wg show` reveals public keys and runtime metadata. Never paste its output into a
public issue. Do not print or copy `/opt/wg-easy/data/wg-easy.db`.

The installer makes a timestamped backup of a pre-existing `/etc/nftables.conf` before
replacing it. It intentionally does not flush the full nftables ruleset and does not
edit Docker-managed tables.

## Repository layout

```text
bootstrap.sh
install.sh
lib/
  adguard.sh
  common.sh
  docker.sh
  firewall.sh
  preflight.sh
  restore.sh
  upgrades.sh
  validate.sh
  wg-easy.sh
README.md
SPECIFICATION.md
```

## Development checks

```bash
bash -n bootstrap.sh install.sh lib/*.sh
shellcheck bootstrap.sh install.sh lib/*.sh
git diff --check
```
