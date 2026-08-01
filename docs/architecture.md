# Architecture

`restage` is a modular Bash codebase built around a single idea: schedule a
one-shot boot into a *patched initrd*, let that initrd do the dangerous
work after reboot, and make every step reviewable before it happens.

## Two-stage design

```
+-----------------------+         reboot          +-------------------------+
|  HOST STAGE (bash)    | ----------------------> | INSTALLER STAGE (initrd) |
|                       |                         |                         |
|  plan + dry-run gate  |                         | bring up networking     |
|  fetch kernel+initrd  |                         | find disk by PTUUID     |
|  patch initrd (stage) |                         | write image / install OS|
|  one-shot boot entry  |                         | fix up bootloader       |
|  save state           |                         | reboot into new system  |
+-----------------------+                         +-------------------------+
```

### Host stage (`restage.sh` → `lib/` + `flows/`)

1. **Parse** — `lib/args.sh` prescans `--config/--log-level/--dry-run/--yes`
   so they take effect early, then parses shared options and passes
   flow-specific options through in `RS_ARGS_LEFT`.
2. **Validate** — `lib/validate.sh` rejects bad usernames, short passwords,
   malformed URLs, out-of-range ports, and so on *before* anything is
   planned.
3. **Resolve** — `lib/oslib.sh` resolves a distro against the catalog in
   `data/distros.conf`: versions, codenames, arch aliases, cloud image URL,
   and (for cloud flows) the *pinned Alpine boot assets*.
4. **Plan** — the flow records steps with `rs_plan_step`; `rs_plan_gate`
   prints the plan, exits 0 under `--dry-run`, otherwise asks for
   confirmation (skipped by `--yes`).
5. **Schedule** — `flows/common.sh` stages the runtime payload
   (`runtime/*` + a rendered network script + a POSIX-quoted `restage.conf`),
   downloads the installer kernel/initrd, patches the initrd, writes the
   one-shot boot entry, and persists state under `/var/restage`.
6. **Reboot** — the operator confirms (unless `--hold`); `restage reset`
   can cancel any of the above before the reboot happens.

### Installer stage (`runtime/`)

After reboot the machine is running a bare Alpine netboot kernel with our
patched initrd. `runtime/trans.sh` is PID 1 and:

- sources `restage.conf` (POSIX-safe: values are single-quoted, so no
  `eval`),
- runs `initrd-network.sh` to bring up networking (DHCP or the captured
  static config),
- locates the target disk by its partition-table UUID (`RESTAGE_DISK_PTUUID`),
- writes the payload (cloud image, `dd` image, or Windows ISO) to the disk,
- fixes up the bootloader and `/etc/fstab` in the new root,
- reboots (or stays, with `--hold 2`).

## Directory layout

```
restage/
├── restage.sh              # CLI entrypoint (command dispatch)
├── bin/restage             # launcher for PATH installs
├── lib/                    # host-stage library modules
│   ├── common.sh           # logging, errors, confirm, dry-run helpers
│   ├── args.sh             # CLI parsing (prescan + common + passthrough)
│   ├── config.sh           # config-file loading, defaults
│   ├── validate.sh         # strict input validation
│   ├── plan.sh             # action plan + dry-run gate
│   ├── state.sh            # /var/restage state + tracked files
│   ├── disk.sh             # PTUUID resolution, parent-disk helpers
│   ├── net.sh              # DHCP/static capture, script rendering
│   ├── boot.sh             # grub/extlinux/efi one-shot entries
│   ├── install.sh          # fetch, initrd unpack/pack/patch
│   ├── oslib.sh            # distro catalog resolution
│   └── help.sh             # `restage help` text
├── flows/                  # one file per command
│   ├── common.sh           # preflight, staging, scheduling tail
│   ├── linux.sh  dd.sh  windows.sh  alpine.sh  netboot.sh  reset.sh
├── runtime/                # code injected into the initrd (POSIX sh)
│   ├── common.sh           # initrd helpers
│   ├── initrd-network.sh   # network bring-up
│   └── trans.sh            # PID 1 installer
├── data/distros.conf       # distro catalog (data, not code)
├── tests/                  # bats unit + integration tests
├── scripts/                # lint.sh, test.sh, release.sh
├── Makefile                # make lint / test / check / install
└── .github/workflows/ci.yml
```

Every module is namespaced with `rs_` and documents what it does; no module
performs work at load time beyond defining defaults.

## Safety model

The project's primary safety mechanism is the **plan gate** (`lib/plan.sh`):

- every destructive flow *records* its steps first,
- `--dry-run` prints them and exits 0 **without executing anything**,
- otherwise the plan is printed and execution waits for confirmation,
- `--yes` only skips the prompt, it never skips the plan.

Disk selection is the other pillar:

- the target is resolved by **partition-table UUID** (`rs_disk_identify`),
  not `/dev/sdX` — device names can change between boots,
- flows hard-fail if the PTUUID cannot be resolved, unless
  `RS_DISK_DEV`/`RS_DISK_PTUUID` are explicitly pre-set (deliberate
  override or tests),
- all destructive writes happen inside the initrd, which only knows the
  PTUUID you authorized.

Dynamic code is generated safely: the runtime config is written with
POSIX single-quoting (`rs_sh_quote`) and loaded with `.` (source), never
`eval`.

## Runtime requirements

The host needs `bash`, `curl`/`wget`, `gzip`, `xz`, `cpio`, `zcat`, and a
bootloader. The initrd runtime is **POSIX `sh`** and intentionally depends
only on busybox-typical tools, so it runs in Alpine's minimal environment.
