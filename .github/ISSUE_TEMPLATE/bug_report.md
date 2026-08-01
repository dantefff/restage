---
name: Bug report
about: Report a problem so it can be fixed
title: ''
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what happened.

**Environment**
- `restage version` output:
- OS / distro of the host machine:
- Architecture (`uname -m`):
- Bootloader (grub/extlinux/EFI) and version:
- How you ran it (from the repo tree, installed launcher):

**Reproduction**
- Exact command(s) run:
- `--dry-run` plan output (paste):
- Debug log:

```bash
restage <command> --dry-run --log-level debug --log-file /var/log/restage.log
# then paste /var/log/restage.log
```

**Expected behavior**
What you expected to happen.

**Actual behavior**
What actually happened, including error messages and the log viewer
output if the installer ran.

**Additional context**
Anything else relevant (disk layout from `lsblk`, whether this is a VPS,
provider, etc.).

> Note: for security vulnerabilities, do **not** use this form — see
> [SECURITY.md](../../SECURITY.md).
