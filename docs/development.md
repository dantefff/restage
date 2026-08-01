# Development

Everything needed to build, test, and ship `restage`.

## Prerequisites

- Bash 5+ (runtime scripts are POSIX `sh`)
- `shellcheck` for linting
- `bats-core` (v1.11.x) for tests
- `cpio`, `xz-utils` for initrd round-trip tests

## Commands

```bash
make lint      # syntax checks + shellcheck (bash, POSIX sh, tests, scripts)
make test      # run the bats unit + integration suite
make check     # lint + test
make install   # install bin/restage launcher to /usr/local/bin
```

`make check` is what CI runs; it must pass before a PR is merged.

## Layout recap

- `lib/` — host-stage library modules (sourced, `rs_`-namespaced).
- `flows/` — one file per command, built on `lib/`.
- `runtime/` — code injected into the initrd; **POSIX `sh` only**, no bash.
- `data/distros.conf` — the distro catalog.
- `tests/` — bats tests; `tests/run.sh` runs everything.

Conventions:

- Every module sources `lib/common.sh` and uses `rs_` prefixes.
- The host side is bash; the runtime is POSIX sh. Lint enforces this
  (`sh -n` + shellcheck with `-s sh` on `runtime/`).
- No `eval`. Generated shell files use POSIX single-quoting
  (`rs_sh_quote`) so they can be sourced safely.
- Logging goes through `rs_log_*`; operator-facing messages through
  `rs_msg`; nothing is written with bare `echo` except in the runtime.

## Testing

Unit tests (`tests/unit/*.bats`) exercise library functions in an isolated
temp work/state directory. Hardware-dependent code (disk, bootloader) is
tested through its pure helpers and validation paths; integration tests
(`tests/integration/cli.bats`) drive the real CLI in `--dry-run` mode, which
must never touch the disk or bootloader.

Run one file:

```bash
bats tests/unit/oslib.bats
```

## Adding a distribution

A new distro is mostly a **data change** in `data/distros.conf`:

1. Add a block with `versions`, `default`, `min_ram`, `min_disk`.
2. Set `installer`:
   - `cloud` — point `cloud` at the official cloud-image URL template and
     set `archmap` (and `codenames` if the URL uses codenames).
   - `manual` — provide real `kernel`/`initrd` netboot URLs.
3. Verify with a dry run:

   ```bash
   restage linux <distro> --dry-run
   ```

   which prints the resolved URLs, and check them with
   `curl -I`.

If the distro has no usable cloud image or netboot assets, it can still be
recognized with `installer=manual` and documented as "manual" — but it
won't be listed as a fully supported install target until the URLs are
real. Add a unit test for the resolution in `tests/unit/oslib.bats`.

**URL drift:** upstream image patterns change. If a catalog URL breaks,
open an issue with the correct pattern rather than silently changing the
data.

## Release process

`make release` drives `scripts/release.sh`:

1. `scripts/release.sh` reads `VERSION`, accepts a bump of `major`,
   `minor`, or `patch` (default `patch`).
2. It writes the updated version back to `VERSION`, tags the commit, and
   generates `CHANGELOG.md` entries from `git log` since the last tag
   (conventional-commit style).
3. Push the tag to publish the release.

Manual steps:

```bash
scripts/release.sh minor          # bumps 0.1.0 -> 0.2.0
git push && git push --tags
```

Semver policy: `0.x` is pre-1.0; any user-visible behavior change bumps
`minor`, fixes bump `patch`. Breaking changes in `0.x` also bump `minor`
and are called out in the changelog.

## CI

`.github/workflows/ci.yml`:

- **lint job** — installs shellcheck, runs `./scripts/lint.sh`.
- **test job** (needs lint) — installs bats + `cpio`/`xz-utils`, runs
  `./tests/run.sh`.

## Releasing a new version of the docs

When behavior changes, update:

- `lib/help.sh` (the built-in help),
- `README.md` (feature/usage deltas),
- `docs/architecture.md`, `docs/configuration.md`,
  `docs/troubleshooting.md`.

Keep help text and the README's option table in sync.
