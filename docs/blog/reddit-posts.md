# Reddit posts — copy-paste ready

> Best time: weekday mornings US time. One post per subreddit, don't spam the
> same text everywhere — tweak the title to match each community.

---

## r/selfhosted (largest relevant audience)

**Title:** restage: reinstall any VPS in one command — no control panel, no rescue ISO

**Body:**

I got tired of provider control panels that only offer their own images, so I
built an open-source tool that reinstalls a Linux server over the network with
a single command:

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --yes
```

How it works:
1. Host downloads a minimal kernel + initrd, patches it with the installer +
   your SSH key and network config, installs a one-shot boot entry, reboots.
2. After reboot the installer finds the disk by partition-table UUID (never
   device name — survives kernel renaming) and installs from official cloud
   images.

It also does `dd` of raw/compressed/qcow2 images, Windows from an official
ISO, and non-destructive rescue environments (`alpine`, `netboot`).

Safety is the selling point: nothing touches disk until an explicit action
plan is confirmed, `--dry-run` changes nothing, and there's a `reset` command
to cancel before reboot.

MIT licensed, bats-tested in CI, modular lib/flows/runtime layout.

Try it safely: `restage linux debian 12 --ssh-key ... --dry-run` prints the
plan and does nothing.

Docs: https://codebyjawad.github.io/restage/
Repo: https://github.com/codebyjawad/restage

**WARNING:** the `linux`, `dd`, and `windows` commands erase the entire
primary disk. Use `--dry-run` first.

---

## r/VPS

**Title:** One-command VPS reinstall to any distro (Debian/Ubuntu/Alpine/AlmaLinux/Rocky/openEuler/Windows)

**Body:**

Most providers' reinstall buttons are limited to their own images, and rescue
ISO + manual grub surgery is painful. I built `restage` — a CLI that reinstalls
a VPS over the network from official images:

- `restage linux debian 12 --ssh-key ... --yes`
- `restage linux ubuntu 24.04 --password 'ChangeMe123!' --yes`
- `restage dd --img https://example.com/image.qcow2 --yes`
- `restage windows --image-name "Windows 11 Pro" --yes`
- `restage alpine` / `restage netboot` — non-destructive rescue boot

Design notes that matter if you manage servers:
- Disk found by **partition-table UUID**, so device renaming between boots
  doesn't break the install.
- Static or DHCP networking captured into the installer (no DHCP dependency).
- Explicit action plan + `--dry-run`; nothing written until you confirm.
- Modular codebase, bats tests in CI, MIT licensed.

Repo: https://github.com/codebyjawad/restage
Docs: https://codebyjawad.github.io/restage/

Try it on a box you don't care about: `restage linux debian 12 --ssh-key ... --dry-run` (changes nothing).

**WARNING:** `linux`/`dd`/`windows` erase the whole primary disk.

---

## r/linux

**Title:** I wrote a from-scratch, tested replacement for the messy VPS reinstall scripts

**Body:**

There's a well-known family of single-file VPS reinstall scripts that have
grown organically for years — no tests, `eval` on user strings, Chinese-only
docs. I wrote a from-scratch, MIT-licensed reimplementation focused on safety
and auditability:

- Modular `lib/` + `flows/` + `runtime/` instead of a 5k-line monolith.
- bats unit + integration tests, run by CI on every push.
- Strict, centralized input validation **before** anything is planned.
- POSIX-quoted generated config — no `eval` of user-controlled strings.
- Two-stage install: host patches a kernel + initrd and sets a one-shot boot
  entry; installer finds the disk by PTUUID and installs from official images.

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --dry-run   # plan only
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --yes       # reinstall
restage alpine                                                       # rescue
```

Repo: https://github.com/codebyjawad/restage
Docs: https://codebyjawad.github.io/restage/

**WARNING:** reinstalling erases the whole disk. Use `--dry-run` first.

---

## r/sysadmin (short version — this crowd hates fluff)

**Title:** Tool: one-command network reinstall for VPS/bare-metal, tests + CI included

**Body:**

`restage` — reinstall Linux/Windows over the network from official images,
selecting the target disk by PTUUID so it survives device renaming. Key
decisions: explicit action plan + `--dry-run`, centralized input validation,
no `eval`, bats suite in CI, MIT.

```bash
restage linux debian 12 --ssh-key "ssh-ed25519 AAAA..." --yes
```

https://github.com/codebyjawad/restage
Docs: https://codebyjawad.github.io/restage/

Wipes the target disk — plan first (`--dry-run`).
