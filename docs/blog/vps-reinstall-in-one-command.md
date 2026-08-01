# Reinstall your VPS in one command — no control panel, no rescue ISO

> A practical tutorial. `restage` is an open-source toolkit that reinstalls a
> Linux server over the network with a single command, boots a rescue
> environment, or writes a disk image — without a control panel, without a
> rescue ISO, and without manual bootloader surgery.

---

## The problem

You rent a VPS. Three months later you want a clean Debian instead of the
Ubuntu image the provider shipped — or you just want to start over. Most
providers give you a clunky control-panel "reinstall" button that works only
for their own images. Some don't give you one at all.

So what do people actually do?

- Keep a server running for years with cruft you're afraid to touch.
- Boot a rescue ISO in the provider's panel, then fight with `dd`, `mount`,
  `chroot`, and grub by hand.
- Use a control panel you don't want, just to get the reinstall feature.

There had to be a better way.

## The idea

What if reinstalling looked like this?

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --yes
```

One command. It downloads a minimal kernel + initrd, patches the initrd with
an installer runtime plus your credentials and network config, installs a
one-shot boot entry, and reboots. When the machine comes back, the installer
finds the target disk by its **partition-table UUID** (never by device name),
writes the OS from official cloud images, fixes the bootloader, and reboots
into your brand-new system.

Because the disk is selected by PTUUID, the tool survives kernel device
renaming between boots. And nothing touches the disk until the action plan
has been shown and confirmed.

That's exactly what [restage](https://github.com/codebyjawad/restage) does —
an MIT-licensed, POSIX/bash toolkit with tests, CI, and docs.

## What you can do with it

| Command | What it does |
| --- | --- |
| `restage linux <distro> <version>` | Reinstall to Debian, Ubuntu, Alpine, AlmaLinux, Rocky, or openEuler from official cloud images |
| `restage dd --img <url>` | Write any raw or compressed disk image (gzip / xz / zstd / qcow2) |
| `restage windows --image-name NAME` | Reinstall to Windows from an official ISO |
| `restage alpine` | Boot the Alpine Live rescue environment (non-destructive) |
| `restage netboot` | Boot the netboot.xyz menu (non-destructive) |
| `restage reset` | Cancel a pending reinstall before reboot |

Non-destructive commands (`alpine`, `netboot`) are handy when a server won't
boot and you need a rescue environment right now.

## Safety first

**Warning:** `linux`, `dd`, and `windows` erase the entire primary disk.

That's why the toolkit is paranoid by design:

- Every run produces an explicit **action plan** you approve before anything
  happens.
- `--dry-run` prints the plan and changes nothing:

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --dry-run
```

- Input is validated centrally, before any plan is built.
- Networking (static or DHCP) is captured into the installer, so the rescue
  environment doesn't depend on a DHCP server.
- There's a `reset` command to cancel a pending reinstall while the host is
  still up.

## Installing

Requirements: Linux, running as root, with `bash`, `curl` (or `wget`),
`gzip`, `xz`, `cpio`, `zcat`, and a supported bootloader (grub, extlinux, or
EFI).

```bash
git clone https://github.com/codebyjawad/restage.git
cd restage

./restage.sh version      # run directly from the tree
make install              # or install to /usr/local/bin/restage
```

## Your first reinstall

Always plan first:

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --dry-run
```

Inspect the plan: target disk, OS to install, boot entry, SSH settings. If it
looks right, run the same command with `--yes`:

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --yes
```

It fetches the kernel + initrd, patches the installer runtime, sets a
one-shot boot entry, and reboots. When the machine returns, it's running
Debian 12 with your SSH key — password login disabled.

Other examples:

```bash
restage linux ubuntu 24.04 --password 'ChangeMe123!' --yes
restage dd --img https://example.com/image.qcow2 --yes
restage windows --image-name "Windows 11 Pro" --yes
restage alpine                      # rescue environment, no disk writes
```

## Why a new project?

Most VPS reinstall tools are a single long shell script that grew organically
over years: no tests, no CI, opaque errors, `eval` of user-controlled
strings, and documentation in one language only. `restage` is a
from-scratch, production-minded reimplementation:

- Modular `lib/` + `flows/` + `runtime/` instead of a monolith.
- bats unit + integration tests, run by CI on every push.
- Strict, centralized input validation and an explicit action plan.
- POSIX-quoted generated config instead of `eval` on user strings.
- A catalog-driven distro list — adding a distro is a data change.

It was inspired by (but shares no code with) the well-known
`bin456789/reinstall` project.

## Where to get it

- GitHub: https://github.com/codebyjawad/restage
- Docs: https://codebyjawad.github.io/restage/
- License: MIT

If you manage VPSes, try `--dry-run` on one of them. It prints the whole
plan and changes nothing — the safest possible way to see what a one-command
reinstall looks like.
