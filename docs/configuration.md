# Configuration

`restage` takes its settings from three sources, in increasing priority:

1. **Defaults** baked into the code (`lib/config.sh`).
2. **Config file** — optional, INI-flavoured.
3. **CLI flags** — always win over the config file.

Environment variables (the `RS_*` family) are honoured as well; they are the
natural choice for scripting and for the test suite.

## Config file

Default locations, in priority order:

- `/etc/restage.conf`
- `./restage.conf` (relative to the repo root when run from the tree)

Override with `--config FILE` or `RS_CONFIG_PATH="a:b:c"` (colon-separated;
first file wins, later files do not override earlier keys).

Syntax:

```ini
# comment
key = value

username = deploy
ssh_port = 2222
```

Keys are lowercase `snake_case`. Values may be double-quoted. Lines without
`key = value` are ignored with a warning. Unknown keys are ignored with a
warning (never fatal), so a config file can stay compatible across
versions.

### Keys

| Config key | Sets | Default | Meaning |
| --- | --- | --- | --- |
| `log_level` | `RS_LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` \| `silent` |
| `log_file` | `RS_LOG_FILE` | *(empty)* | also append logs to this file |
| `assume_yes` | `RS_ASSUME_YES` | `0` | skip confirmations (`--yes`) |
| `dry_run` | `RS_DRY_RUN` | `0` | plan only, change nothing (`--dry-run`) |
| `ssh_port` | `RS_SSH_PORT` | `22` | SSH port on the installed system |
| `web_port` | `RS_WEB_PORT` | `80` | installer log-viewer port |
| `username` | `RS_USERNAME` | `root` | login user for the installed system |
| `password` | `RS_PASSWORD` | *(empty)* | generated randomly if empty |
| `ssh_key` | `RS_SSH_KEY` | *(empty)* | authorized SSH public key |
| `hold` | `RS_HOLD` | `0` | `1` boot only, `2` install then stay |
| `state_dir` | `RS_STATE_DIR` | `/var/restage` | where pending-reinstall state lives |
| `work_dir` | `RS_WORK_DIR` | `/restage` | scratch dir for staged assets |
| `force` | `RS_FORCE` | `0` | ignore hardware requirement checks |
| `net_dhcp` | `RS_NET_DHCP` | `auto` | `auto` \| `yes` \| `no` |

### Example

```ini
# /etc/restage.conf
log_level      = info
log_file       = /var/log/restage.log
username       = deploy
ssh_port       = 2222
web_port       = 8080
net_dhcp       = auto
hold           = 0
force          = 0
```

## Environment variables

Every setting above has an `RS_*` equivalent and can be exported:

```bash
export RS_USERNAME=deploy
export RS_SSH_PORT=2222
export RS_NET_DHCP=auto
restage linux debian 12
```

Additional low-level variables:

| Variable | Meaning |
| --- | --- |
| `RS_DISK_DEV` | Pre-set target disk device (overrides PTUUID detection) |
| `RS_DISK_PTUUID` | Pre-set target partition-table UUID (overrides detection) |
| `RS_BOOTLOADER_OVERRIDE` | Force `grub` \| `extlinux` \| `efi` |
| `RS_GRUB_CFG`, `RS_GRUB_ENTRY_FILE` | grub paths (testing/custom layouts) |
| `RS_EXTLINUX_CFG` | extlinux.conf path |
| `RS_EFI_MOUNT` | EFI system partition mount |
| `RS_NET_IFACE` | Network interface captured into the installer |
| `RS_CURL_RETRIES` | Download retry count (default 5) |
| `RS_FORCE` | Bypass hardware checks (same as `--force`) |
| `NO_COLOR` | Disable colored log output when set |

> `RS_DISK_DEV`/`RS_DISK_PTUUID` are the *deliberate override* used by the
> test suite and by operators who know exactly which disk they mean. When
> unset, `restage` resolves the disk from the root filesystem's partition
> table and refuses to continue if it cannot.

## Distro catalog

The known distributions and their asset URLs live in
`data/distros.conf`, not in code:

```
alpine  debian  ubuntu  almalinux  rocky  openeuler
arch (manual)  gentoo (manual)
```

Fields per distro:

| Field | Purpose |
| --- | --- |
| `versions` | space-separated supported versions |
| `default` | version used when none is given |
| `min_ram` / `min_disk` | hardware requirements (checked pre-plan) |
| `installer` | `cloud` \| `alpine_live` \| `manual` \| `netboot` |
| `cloud` | cloud-image URL template |
| `codenames` | `version=codename` pairs when URLs use codenames |
| `archmap` | distro arch alias (`x86_64=amd64 ...`) |
| `kernel` / `initrd` | netboot assets for `manual`/`netboot` installers |
| `kernel_args` | extra kernel cmdline |

URL templates support `{ver}`, `{arch}`, `{carch}` and `{codename}`.

The **cloud** installers always boot the *pinned Alpine netboot kernel*
(see `RS_ALPINE_BOOT_VERSION` in `lib/oslib.sh`), not the target distro's —
the cloud image is written from inside Alpine. `arch` and `gentoo` are
recognized but currently use the `manual` installer: their URLs are
placeholders and must be completed (see
[docs/development.md](docs/development.md) → "Adding a distribution").
