# Contributing

## The most valuable contribution: "it works on my chip"

Tested this on hardware not in the README table? Open a PR editing the
**Confirmed by real people** table (or just open an issue with the details):

- Chip / dongle model (from `--check` output)
- Host (Proxmox version) and guest OS
- Anything weird you hit

## Bug reports

Use the issue template - the `--check` output and service logs it asks for
answer most questions on the first pass.

## Code changes

- Branch from `main`, open a PR (direct pushes are blocked)
- CI runs `tests/run-tests.sh` - run it locally first: `sudo bash tests/run-tests.sh`
- Conventional commit titles (`fix:`, `feat:`, `docs:`) - they drive automatic releases
- Keep it in plain bash, no new dependencies. The whole point of this tool is that
  it needs nothing.

## Rebuilding the bundled binary

`build.sh` reproduces `bin/btproxy-x86_64` from BlueZ source on any Debian/Ubuntu
box, and `bin/btproxy-x86_64.sha256` must match (CI enforces it).
