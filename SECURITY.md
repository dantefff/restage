# Security Policy

`restage` performs destructive disk operations. This policy explains what we
support and how to report problems safely.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email the maintainers (see the GitHub repo for the current address) with:

- the affected version (`restage version`),
- a description of the vulnerability and its impact,
- a minimal reproduction, if possible.

You will receive an acknowledgment within 3 business days and a target
timeline for a fix. We prefer coordinated disclosure: please give us a
reasonable window before publishing.

## Scope

In scope: the code in this repository — host scripts (`restage.sh`,
`lib/`, `flows/`, `scripts/`), the runtime injected into the initrd
(`runtime/`), the test suite, and the release pipeline
(`.github/workflows/`).

Out of scope: the operating systems, cloud images, and ISOs that `restage`
installs, and upstream projects it invokes (`curl`, `grub`, busybox tools,
...). Report issues in those to their respective projects.

## Security considerations in this project

These properties are deliberately designed in and must be preserved by any
change:

- **No `eval` of user-controlled data.** Generated config is POSIX-quoted
  and loaded with `.` (source).
- **Disk safety.** The target disk is resolved by partition-table UUID;
  flows refuse to continue when it cannot be resolved. Device names are
  never trusted across reboots.
- **Plan gate.** Destructive actions happen only after an explicit plan is
  shown and confirmed (`--dry-run` / `--yes`).
- **Least privilege at runtime.** The initrd runtime runs as PID 1 with
  only the credentials and network config you authorized.
- **Credential hygiene.** Passwords and SSH keys are stored only in the
  state the operator controls (`/var/restage`, chmod 600) and are
  single-quoted on disk.

## Supported versions

| Version | Supported |
| --- | --- |
| `0.1.x` (current, unreleased) | yes |

Pre-1.0, only the latest release line receives security fixes; fixes are
released as the next `0.x` patch.

## Disclosure

We will credit reporters (unless they ask to remain anonymous) in the
changelog for the fixing release.
