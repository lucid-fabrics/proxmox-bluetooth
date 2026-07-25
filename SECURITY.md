# Security

## Reporting

Found a vulnerability? Open a private report via GitHub's
**Security > Report a vulnerability**, or email the maintainer. Please don't
open a public issue for exploitable problems.

## What to know about this tool's model

- The bridge exposes raw HCI on one LAN TCP port (default 9700, bound to the
  host's IP) with **no authentication** - any machine that can reach the port
  can claim the adapter. Firewall it to your VM's IP if your LAN isn't trusted.
- The installer downloads a prebuilt binary over HTTPS and verifies it against
  a SHA-256 checksum; both live in this repository, and CI enforces that the
  checksum always matches the committed binary.
