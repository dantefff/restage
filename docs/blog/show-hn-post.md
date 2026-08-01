# Show HN submission

## Title (pick one)

1. Show HN: restage — reinstall any VPS in one command, no control panel
2. Show HN: A from-scratch, tested replacement for the infamous VPS reinstall scripts
3. Show HN: restage — one-click OS reinstall & rescue toolkit for VPS/bare-metal

## First comment (post as the author, right after submitting)

Author here.

A few years back I kept hitting the same wall: I wanted to wipe and reinstall a
VPS with a distro the provider didn't offer, and the usual answer was either a
5k-line shell monolith I couldn't audit, or fighting a rescue ISO by hand.

restage is a from-scratch, MIT-licensed reimplementation:

- **Two-stage design.** The host downloads a minimal kernel + initrd, patches
  it with the installer runtime + your SSH key and network config, installs a
  one-shot boot entry, and reboots. After reboot the installer finds the disk
  by **partition-table UUID** — never by device name — so it survives kernel
  device renaming between boots.
- **Paranoid safety.** Nothing touches disk until an explicit action plan is
  shown and confirmed. `--dry-run` prints the plan and changes nothing. There
  is a `reset` command to cancel before reboot.
- **Built like a real project.** Modular `lib/` + `flows/` + `runtime/`, bats
  unit + integration tests in CI, strict centralized input validation, no
  `eval` of user strings.
- **Distro catalog is data, not code.** Adding a distro is a config change.

What it does today:
- `restage linux debian 12 --ssh-key ... --yes` → Debian/Ubuntu/Alpine/AlmaLinux/Rocky/openEuler from official cloud images
- `restage dd --img URL` → write any raw/compressed/qcow2 image
- `restage windows --image-name "Windows 11 Pro" --yes` → Windows from an official ISO
- `restage alpine` / `restage netboot` → non-destructive rescue environments

The safest way to try it: `--dry-run` prints the full action plan and touches
nothing.

Docs: https://codebyjawad.github.io/restage/
Repo: https://github.com/codebyjawad/restage

Happy to answer questions about the boot technique, initrd patching, or the
safety model.

## Known context for expected questions

- Inspired by (shares no code with) `bin456789/reinstall`, which is GPL-3.0;
  restage is MIT and from scratch. Mentioning this diff preempts the "isn't
  this just a fork?" question.
- The `linux` / `dd` / `windows` commands erase the whole primary disk — be
  explicit about the WARNING in the post body.
