# Contributing

Thanks for helping make `restage` better. This is a small, safety-critical
tool — the guidelines below keep it reviewable and reliable.

## Code of conduct

All contributors agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Be
kind, be specific, assume good faith.

## Before you start

- Open an **issue** first for anything non-trivial (new distro, new flow,
  changed CLI behavior) so we agree on direction before you write code.
- For bugs, include: `restage version`, the debug log
  (`--log-level debug --log-file /var/log/restage.log`), the dry-run plan,
  and hardware info (`uname -m`, `lsblk`).
- **Security vulnerabilities: do not open a public issue.** See
  [SECURITY.md](SECURITY.md).

## Getting started

```bash
git clone https://github.com/codebyjawad/restage.git
cd restage
make check        # lint + test; must pass before submitting
```

## What we look for

The codebase has explicit conventions (see
[docs/development.md](docs/development.md)); the essentials:

- **Host side is Bash**, the **runtime is POSIX sh**. Lint enforces this.
- Everything is `rs_`-namespaced; modules do no work at load time.
- **No `eval`.** Generated config is POSIX-quoted and sourced.
- Input validation happens in `lib/validate.sh`, before any planning.
- Destructive flows record an explicit action plan and pass the plan gate.
- Every change ships with tests: `make test` must stay green, and new
  behavior should add coverage in `tests/`.
- No debug `echo`s, no commented-out code, no unrelated changes in a PR.

## Adding a distribution

Prefer a data-only change in `data/distros.conf` — see
[docs/development.md](docs/development.md) → "Adding a distribution".
Verify resolved URLs with `restage linux <distro> --dry-run` and
`curl -I`. Add a resolution test to `tests/unit/oslib.bats`.

If upstream image URLs drift, open an issue with the corrected pattern
instead of guessing.

## Pull request checklist

- [ ] `make check` passes locally
- [ ] New/edited behavior covered by tests
- [ ] Help text (`lib/help.sh`), README, and docs updated if CLI changed
- [ ] Conventional commit message (`feat:`, `fix:`, `chore:`, `docs:`, ...)
- [ ] PR description summarizes the change and the tests run

## Commit messages

Use conventional commits — `scripts/release.sh` derives the changelog from
them:

```
feat(flows): add --iso option to the windows flow
fix(oslib): guard empty cloud template expansion
docs: document --net-dhcp static capture
```

## Reviewing

Small PRs, fast reviews. If a PR is larger than a few hundred lines,
consider splitting it. Maintainers may request changes to keep the diff
surgical.

## Releasing

Maintainers cut releases with `scripts/release.sh` (semver bump + tag +
changelog). See [docs/development.md](docs/development.md) → "Release
process".
