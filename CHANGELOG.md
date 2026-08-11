# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Fully unattended Windows installs: the `windows` flow now partitions the
  disk (EFI+MSR / MBR), downloads the official ISO inside the installer,
  copies it to an installer partition, renders `autounattend.xml`, and
  installs a one-shot boot entry that runs Windows Setup end to end
  (`runtime/windows.sh`, `runtime/windows-unattend.xml`).
- Windows post-install tweaks on first boot via `SetupComplete.cmd`:
  scheduled credentials, RDP (on `--rdp-port`), ping (`--allow-ping`),
  static IP/DNS on the MAC-matched interface.
- Driver injection for Windows: `--add-driver <inf|dir>` (staged into the
  initrd and mounted into WinPE), plus automatic virtio driver bundling on
  KVM hosts.
- `runtime/common.sh` `fetch`/`fetch_stdout` helpers using busybox `wget`
  with a `curl` fallback (the netboot initrd ships no `curl`), and
  `--yes`/`RESTAGE_ASSUME_YES` makes the installer's confirmation prompts
  non-interactive.
- Project funding via GitHub Sponsors (`.github/FUNDING.yml`).
- Social preview image for link unfurling.
- Initial release of the `restage` reinstall & rescue toolkit.
- Commands: `linux`, `dd`, `windows`, `alpine`, `netboot`, `reset`,
  `version`, `help`.
- Explicit action plan with `--dry-run` and interactive confirmation
  (`--yes` for unattended runs).
- Strict, centralized input validation (`lib/validate.sh`).
- Two-stage install: patched-initrd boot with a POSIX `sh` runtime
  (`runtime/trans.sh`).
- Disk safety: target resolved by partition-table UUID, never a device name.
- Catalog-driven distro resolution (`data/distros.conf`):
  alpine, debian, ubuntu, almalinux, rocky, openeuler
  (arch and gentoo as documented manual extension points).
- DHCP or captured-static networking inside the installer
  (`--net-dhcp auto|yes|no`).
- `--hold 1|2` debug modes, `--frpc-config` out-of-band access injection.
- `restage reset` cancels a pending reinstall before reboot.
- Test suite: 73 bats unit + integration tests; lint + test CI on push/PR.
- Release tooling: `scripts/release.sh`, `Makefile`, semver + changelog.

### Inspiration

The two-stage boot-a-patched-initrd technique mirrors the approach of the
`bin456789/reinstall` project; no code from it is used. This project is
MIT-licensed.
