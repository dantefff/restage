# Troubleshooting

## Always start here

1. **Run a dry run first** — it prints the exact action plan and changes
   nothing:

   ```bash
   restage linux debian 12 --dry-run
   ```

2. **Run with debug logging and a log file**:

   ```bash
   restage linux debian 12 --dry-run --log-level debug --log-file /var/log/restage.log
   ```

3. **Know how to cancel.** Until the machine reboots, a pending reinstall is
   fully undoable:

   ```bash
   restage reset
   ```

   `reset` removes the one-shot boot entry, the staged files under
   `/boot/restage`, and the state under `/var/restage`.

## I can't reach the network from the rescue environment

The installer normally uses **DHCP**. If your provider does not run DHCP you
can capture the live static configuration at scheduling time:

```bash
restage linux debian 12 --net-dhcp no
```

`--net-dhcp no` records the current IPv4/IPv6 addresses, gateway and
interface and replays them inside the initrd. With `--net-dhcp auto` (the
default) the installer tries DHCP and falls back to the captured static
config if DHCP fails.

## Bootloader not detected

`restage` detects grub → extlinux → EFI in that order. On unusual layouts,
force a loader:

```bash
restage linux debian 12 --bootloader grub
```

If grub is present but `grub.cfg` isn't in the standard location, point it
at the right file:

```bash
export RS_GRUB_CFG=/boot/grub2/grub.cfg
```

`alpine` and `netboot` rescue flows print a clear error if no supported
bootloader is found instead of guessing.

## A reinstall is already pending

Scheduling a second reinstall while one is pending is refused unless you
explicitly replace it:

```bash
restage linux ubuntu 24.04 --force
```

`--force` cancels the previous pending reinstall (same as `restage reset`)
before scheduling the new one.

## Hardware requirement check fails

The catalog records `min_ram`/`min_disk` per distro. On machines that
really can install anyway (or for debug VMs):

```bash
restage linux almalinux 9 --force
```

## Download failures

Downloads retry up to `RS_CURL_RETRIES` (default 5). Persistent failures are
usually one of:

- **Wrong arch** — cloud-image URLs differ per architecture; confirm
  `uname -m`.
- **Version no longer published** — check the distro's official URL pattern
  (see the catalog in `data/distros.conf`). Report drift via an issue.
- **Network/firewall** — the host must reach the distro's CDN.

## The machine boots but the installer doesn't run

Common causes:

- The bootloader wrote the one-shot entry but the boot menu isn't showing
  it. On grub, `grub-reboot` should auto-select the `restage` entry; if it
  didn't, select **restage** manually in the boot menu.
- The PTUUID changed between boots (disk re-created). Check the log viewer
  on the `--web-port`; the runtime reports "target disk not found" and
  drops to a shell. Boot back into the host OS, confirm the disk, and
  rerun with `RS_DISK_DEV`/`RS_DISK_PTUUID` set explicitly.

## Windows install issues

The `windows` flow runs a real unattended install. It partitions the disk
(GPT: EFI + MSR + Windows + installer; MBR: two NTFS partitions), downloads
the official ISO inside the Alpine installer, copies its contents onto the
installer partition, renders an `autounattend.xml` that drives Windows
Setup end to end, and installs a one-shot boot entry that starts Setup.
Windows boots automatically afterwards.

- A known edition can be looked up with `--image-name` alone
  (e.g. `--image-name "Windows 11 Pro"`). This is a lookup hint, so
  sometimes the direct link must be supplied explicitly with `--iso`.
- The installer needs ~2 GB of free RAM beyond the netboot kernel and a
  couple of GB of temporary disk for the ISO staging partition.
- Storage drivers for non-virtio hardware can be injected with
  `--add-driver path/to/*.inf`; on KVM the installer bundles virtio drivers
  automatically.
- Post-install tweaks are applied on first boot: the scheduled credentials
  are enabled, RDP is turned on (on `--rdp-port`, default 3389), ping is
  allowed with `--allow-ping`, and the host's static IP is applied to the
  matching interface when you schedule with `--net-dhcp no`.

### Unattended install hangs or boots to a black screen

- The ISO download runs inside the installer; the `--web-port` log viewer
  streams `restage.log`, which shows which phase is stuck.
- If Setup complains it cannot find a disk, add the storage driver with
  `--add-driver` (see above) rather than relying on the stock image.
- If only the original firmware boot entry is overwritten, use
  `efibootmgr -n` on the host to force the next boot from the removable
  `\EFI\Microsoft\Boot\bootmgfw.efi` fallback.

## I want to debug the installer

Two hold modes keep the machine from cycling:

```bash
restage linux debian 12 --hold 1     # boot the installer, don't install
restage linux debian 12 --hold 2     # install, then stay instead of rebooting
```

With `--hold 2` you can inspect the installed root before the first reboot.

## Reporting an issue

Include:

- `restage version` output,
- the full log: `--log-level debug --log-file /var/log/restage.log`,
- the dry-run plan output,
- hardware: `uname -m`, disk layout (`lsblk`), bootloader version.

For security issues, see [SECURITY.md](SECURITY.md) — do not open a public
issue.
