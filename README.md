# restage

One-click OS reinstallation & rescue toolkit for VPS and bare-metal servers.

`restage` lets you reinstall a Linux server over the network with a single
command, boot a rescue environment, or write a disk image — without a
control panel, without a rescue ISO, and without manual bootloader surgery.

> **WARNING:** `linux`, `dd` and `windows` erase the **entire primary disk**.
> Always run with `--dry-run` first and keep a rescue plan. `alpine` and
> `netboot` are non-destructive.

[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash/posix-4EAA25.svg)](#)
[![GitHub stars](https://img.shields.io/github/stars/codebyjawad/restage?style=social&label=Stars)](https://github.com/codebyjawad/restage/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/codebyjawad/restage?style=social&label=Forks)](https://github.com/codebyjawad/restage/network/members)
[![GitHub release](https://img.shields.io/github/v/release/codebyjawad/restage?color=blue)](https://github.com/codebyjawad/restage/releases)
[![CI](https://github.com/codebyjawad/restage/actions/workflows/ci.yml/badge.svg)](https://github.com/codebyjawad/restage/actions)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Docs](https://img.shields.io/badge/docs-online-2ea44f.svg)](https://codebyjawad.github.io/restage/)

---

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=codebyjawad/restage&type=Date)](https://star-history.com/#codebyjawad/restage&Date)

## Why restage?

Most VPS reinstall tools are a single long shell script that has grown
organically over years: no tests, no CI, opaque error messages, `eval` of
user-controlled strings, and Chinese-only documentation. `restage` is a
from-scratch, production-minded reimplementation with the same two-stage
idea but a very different codebase:

| | legacy reinstall script | restage |
|---|---|---|
| Structure | one 5k-line monolith | modular `lib/` + `flows/` + `runtime/` |
| Tests | none | bats unit + integration suite |
| CI | none | lint + test on every push/PR |
| Input validation | late, ad hoc | strict, centralized, pre-plan |
| Safety | implicit | explicit action plan + dry-run gate |
| Dynamic code | `eval` on user strings | POSIX-quoted generated config |
| Docs | Chinese-only | English, full reference |

The original project was used as a source of *ideas* (the boot-an-initrd
technique); no code was copied.

## How it works

Reinstalling works in two stages:

1. **Host stage (no reboot yet).** `restage` downloads a minimal kernel +
   initrd (pinned Alpine Linux netboot assets), patches the initrd with the
   installer runtime plus your credentials and network config, installs a
   **one-shot boot entry**, and saves state under `/var/restage`.
2. **Installer stage (after reboot).** The machine boots into the patched
   initrd. The runtime brings up networking, finds the target disk by its
   **partition-table UUID** (never by device name), writes the target
   image/OS, fixes up the bootloader, and reboots into your new system.

Because the disk is selected by PTUUID, the tool survives kernel device
renaming between boots. Nothing touches the disk until the plan has been
shown and confirmed.

## Features

- **`linux`** — reinstall to Debian, Ubuntu, Alpine, AlmaLinux, Rocky, or
  openEuler from official cloud images; version/codename aware URLs.
- **`dd`** — write a raw or compressed disk image (URL, supports
  gzip/xz/zstd/qcow2).
- **`windows`** — reinstall to Windows from an official ISO.
- **`alpine`** — boot the Alpine Live rescue environment (non-destructive).
- **`netboot`** — boot the netboot.xyz menu (non-destructive).
- **`reset`** — cancel a pending reinstall before the machine reboots.
- Explicit **action plan** with `--dry-run`, interactive confirmation, and
  `--yes` for unattended runs.
- Strict, centralized **input validation** before anything is planned.
- **Static or DHCP** networking captured into the installer (no DHCP server
  required in the rescue environment).
- `--hold` debug modes (boot only, or install then stay).
- Optional **frpc** injection for out-of-band access during install.
- Catalog-driven distro list in `data/distros.conf` — adding a distro is a
  data change, not a code change.

## Installation

### From source (recommended)

```bash
git clone https://github.com/codebyjawad/restage.git
cd restage

# run directly from the tree
./restage.sh version

# or install the launcher on PATH
make install          # installs to /usr/local/bin/restage
```

Dependencies on the host: `bash`, `curl` (or `wget`), `gzip`, `xz`,
`cpio`, `zcat`, and a supported bootloader (grub, extlinux, or EFI). The
installed system needs nothing from us — it comes from official images.

### Requirements

- Linux, running as **root**.
- A VPS or bare-metal box you control.
- Internet access from the host.

## Quick start

```bash
# Always plan first — this changes nothing:
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --dry-run

# Then reinstall, unattended:
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --yes
```

Other examples:

```bash
restage linux ubuntu 24.04 --password 'ChangeMe123!' --yes
restage dd --img https://example.com/image.qcow2 --yes
restage windows --image-name "Windows 11 Pro" --yes
restage alpine                     # rescue environment, no disk writes
restage netboot                    # netboot.xyz menu
restage reset                      # cancel a pending reinstall
```

## Usage

```
restage <command> [options]

Commands:
  linux <distro> [version]   Reinstall to a Linux distribution
  dd --img <url>             Write a raw/compressed disk image
  windows --image-name NAME  Reinstall to Windows (official ISO)
  alpine                     Boot into the Alpine Live rescue environment
  netboot                    Boot into the netboot.xyz menu
  reset                      Cancel a pending reinstall (pre-reboot only)
  version | help             Version and help output
```

Shared options (see `restage help` for the full list):

| Option | Meaning |
| --- | --- |
| `--username USER` | Login user for the installed system |
| `--password PASS` | Password (min 8 chars; random if omitted) |
| `--ssh-key KEY` | SSH public key; password login then disabled |
| `--ssh-port PORT` | SSH port on the installed system (default 22) |
| `--web-port PORT` | Port for the installer's log viewer (default 80) |
| `--hold N` | `1` boot only (debug), `2` install then stay |
| `--frpc-config PATH\|URL` | Inject a frpc config for out-of-band access |
| `--net-dhcp auto\|yes\|no` | Force DHCP/static networking in the installer |
| `--bootloader auto\|grub\|extlinux\|efi` | Override bootloader detection |
| `--dry-run` | Print the action plan and exit, changing nothing |
| `--yes` | Skip all interactive confirmations |
| `--force` | Ignore hardware requirement checks |
| `--config FILE` | Use an alternative config file |
| `--log-level LEVEL` | `debug` \| `info` \| `warn` \| `error` \| `silent` |
| `--log-file FILE` | Also append logs to `FILE` |

## Configuration

`restage` reads an optional INI-flavoured config file (default
`/etc/restage.conf`, then `./restage.conf`). CLI flags always win over the
config file.

```ini
# /etc/restage.conf
ssh_port = 2222
web_port = 8080
log_level = info
assume_yes = 0
net_dhcp = auto
```

See [docs/configuration.md](docs/configuration.md) for every key, the
equivalent environment variables, and examples.

## Documentation

- [docs/architecture.md](docs/architecture.md) — design, two-stage flow,
  directory layout, safety model.
- [docs/configuration.md](docs/configuration.md) — config file, environment
  variables, distro catalog.
- [docs/troubleshooting.md](docs/troubleshooting.md) — common failure modes
  and how to recover.
- [docs/development.md](docs/development.md) — running tests/lint, adding a
  distro, release process.

## Project status

This is the **0.1.0** framework release: the full CLI, planning, dry-run,
initrd patching, boot-entry scheduling, state/reset, and catalog-driven
distro resolution work end-to-end (verified by the test suite). Netboot
asset URLs for some distros and Windows ISOs are catalog/curated rather
than auto-discovered. See the [CHANGELOG](CHANGELOG.md) and
[docs/development.md](docs/development.md) for what's next.

## Contributing

Bug reports, fixes, and distro catalog additions are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) first, and run `make check` before
opening a PR.

## Security

See [SECURITY.md](SECURITY.md) for the supported-versions policy and how to
report a vulnerability. Do **not** open a public issue for security bugs.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 codebyjawad.

`restage` was inspired by (but shares no code with) the `bin456789/reinstall`
project, which is licensed under GPL-3.0.
