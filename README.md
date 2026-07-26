# Bluetooth in your Proxmox Linux VMs. Finally.

[![Ko-fi](https://img.shields.io/badge/Ko--fi-donate-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/lucidfabrics)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-donate-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/lucidfabrics)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-%E2%9D%A4-EA4AAA?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/lucid-fabrics)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Binary builds clean from BlueZ source](https://github.com/lucid-fabrics/proxmox-bluetooth/actions/workflows/verify-binary.yml/badge.svg)](https://github.com/lucid-fabrics/proxmox-bluetooth/actions/workflows/verify-binary.yml)

> **TL;DR:** USB-passing a Bluetooth adapter into a VM makes the chip drop its firmware,
> and the guest can only recover if it has the right driver and firmware blobs. Full
> distros often manage it; Home Assistant OS, ChimeraOS, Bazzite and other trimmed or
> immutable guests frequently don't, and Intel onboard combo chips (BE200, AX210, AX211)
> are the worst offenders. This tool skips the handoff entirely: the adapter stays on the
> host and is shared to the VM over the network - two commands, survives reboots.
> **Try plain USB passthrough first**, it's simpler and works for plenty of setups.

Pair your Xbox / PlayStation controller, headphones, or sensors **inside** your gaming VM
(ChimeraOS, Bazzite, Home Assistant, plain Linux) - even with Bluetooth chips that
"can't be passed through".

<p align="center">
  <img src="docs/img/controller-connected.jpg" alt="Xbox controller finally connected in Steam" width="600">
</p>

## Sound familiar?

- You built a gaming VM on Proxmox. Everything works... except Bluetooth.
- Your controller just blinks, blinks, blinks, and gives up.
- You bought an Intel BE200 / AX210 card because a forum said so. Still nothing.
- You tried `qm set ... -usb`, saw the device in the VM, and it still refused to work.
- Every thread ends with someone saying *"just use a USB cable"*.

**It's not your fault, and your hardware is not broken.**

Nearly all Bluetooth adapters clear their firmware when they're re-enumerated on USB, so
after a passthrough the guest has to load it again from scratch. That works when the guest
has the matching driver and firmware blobs, which is why a full Debian or Arch VM often
passes through fine. It falls apart when the guest doesn't: Home Assistant OS and gaming
distros ship trimmed kernels and incomplete `linux-firmware`, and Intel's CNVi combo chips
(BE200, AX2xx) are especially unforgiving, they land in a bootloader state the guest can't
talk it out of.

So this isn't "passthrough never works". It's "passthrough depends on your guest getting
the firmware handshake right, and some guests can't". This tool removes that dependency by
never handing the chip over at all.

## First: try the simple thing

Plain USB passthrough works for plenty of setups - a normal dongle into a normal
Linux distro (Debian, Ubuntu) often just works:

```bash
qm set <vmid> -usb0 host=<vendor:product>
```

If that gives you working Bluetooth in your VM, stop reading - you don't need this
project. Worth trying a **cheap USB dongle** too: a plain dongle passed into a full distro
is the simplest setup there is, and if your guest has the firmware for it, it just works.

### If passthrough didn't work, check this before giving up

The adapter drops its firmware when it's re-enumerated on USB, so the *guest* has to load
it again. Most passthrough failures are simply a guest missing that firmware, and that is
fixable without any of this. Inside the VM:

```bash
dmesg | grep -i -A2 bluetooth | grep -i "firmware\|failed"
```

If you see `Direct firmware load for ... failed`, the guest is just missing the blob.
Install it and reboot the VM:

```bash
# Debian (needs the non-free-firmware component enabled)
sudo apt install firmware-iwlwifi        # Intel chips; firmware-realtek, firmware-atheros etc. for others

# Ubuntu
sudo apt install linux-firmware          # note: this package does not exist on Debian

# Fedora / ChimeraOS / Bazzite
sudo rpm-ostree install linux-firmware   # usually already present
```

That alone fixes a lot of cases, and if it fixes yours, **use plain passthrough and skip
this project.**

This tool is for when that isn't available or doesn't help: **Intel onboard combo chips**
(BE200/AX2xx) that land in a bootloader state the guest can't talk them out of, **gaming
distros** (ChimeraOS/Bazzite trimmed kernels + quirky chip firmware), Home Assistant OS
and other appliance images where you can't install firmware packages at all, trimmed cloud
kernels, and dongles that wedge after a few VM restarts.

## The fix: don't hand over the chip. Share it.

The chip stays on your Proxmox host, where it works. A tiny bridge streams it into the VM
over the local network. Your VM sees a completely normal Bluetooth adapter. Latency is
lower than the controller's own radio delay - you will never feel it.

**Built on BlueZ.** The bridge itself is `btproxy`, an existing tool from the official
[BlueZ](http://www.bluez.org/) project (GPL-2.0-or-later), not reimplemented here. This
project is the install/systemd tooling around it. See
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the full attribution and license text.

CI rebuilds it from upstream source on every commit and fails if a single byte differs.
Full provenance, and a one-command check you can run yourself, in
[About that bundled binary](#about-that-bundled-binary) below.

### Two commands. That's all.

<p align="center">
  <img src="docs/img/demo.gif" alt="Real install: host shares the chip, VM gets working Bluetooth" width="700">
</p>

On the **Proxmox host**:

```bash
curl -fsSL https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main/install.sh | sudo bash
```

You'll see something like this:

```
==> Bluetooth adapters on this machine:
    [0] hci0 - 70:08:10:A4:F1:45 (USB)
==> All adapters healthy. You are good to go.
==> Downloading btproxy...
==> Checksum verified against the hash pinned in this script.
==> Bluetooth (hci0) is now shared on 192.168.1.3:9700.

  Now run this INSIDE your VM:

    curl -fsSL https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main/install.sh | sudo bash -s -- 192.168.1.3

!! Port 9700 is open to your whole LAN and has no password.
   Whichever machine connects first gets the Bluetooth chip.
   Once you know your VM's IP, restrict it:
       curl -fsSL .../install.sh | sudo bash -s -- --allow <vm-ip>
```

That last warning is not boilerplate, it is the honest default: read
[Is this secure?](#is-this-secure) before leaving it that way. (The `Downloading` and
`Checksum` lines appear when the script runs on its own; from a git clone it uses the local
`bin/` copy instead.)

**What to do:** copy that last line exactly (your IP will be different) and run it inside the VM.

Inside the VM, you'll see:

```
==> Done. This VM now has working Bluetooth. Go pair your controller.
```

**What to do:** open Bluetooth settings in the VM and pair like normal. That's it.

Both sides auto-start at boot and auto-reconnect. Set it up once, forget it exists.

### Three ways to install

Pick whichever suits you, all three are fully supported and land on the same result.
The one-liner above is the quickest. The other two:

**Read it first, then run it:**

```bash
curl -fsSL -O https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main/install.sh
less install.sh          # readable bash, nothing minified or obfuscated
sudo bash install.sh
```

Run on its own like that, the script fetches `bin/btproxy-x86_64` from this repo and
verifies it against the SHA-256 pinned in the script itself, refusing to install anything
that doesn't match. To have everything present before you start, clone the repo, the
script then uses the local `bin/` copy:

```bash
git clone https://github.com/lucid-fabrics/proxmox-bluetooth
cd proxmox-bluetooth && sudo ./install.sh
```

**Or skip this project's script entirely:** [MANUAL_INSTALL.md](MANUAL_INSTALL.md) walks
through building `btproxy` from official BlueZ source and writing the systemd units by
hand. Follow all of it (including the small restart wrapper, which stops the bridge from
wedging after a VM reboot) and you get the same result, `install.sh` just automates it.

### About that bundled binary

Full provenance, in four points.

**It isn't ours.** `bin/btproxy-x86_64` is an unmodified build of `btproxy` from
[BlueZ](http://www.bluez.org/) itself. This project wrote the install tooling around it,
not the bridge. Full attribution, all three upstream licenses (GPL-2.0-or-later,
LGPL-2.1-or-later, BSD-2-Clause) and a written source offer are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

**Why not just `apt install` it?** Because on the distros involved here, `btproxy` isn't
packaged. `bluez` obviously is, but that package doesn't include this particular tool:

| Distro | Ships `btproxy`? | |
|---|---|---|
| Debian / Ubuntu | **no** | `dpkg -L bluez bluez-test-tools \| grep -c btproxy` → `0` |
| Fedora (and Fedora Atomic: ChimeraOS, Bazzite) | **no** | `dnf repoquery -l bluez \| grep btproxy` → nothing |
| Arch | **yes** | it's in `bluez-utils` |

Proxmox is Debian, and the guests this exists for are Debian/Ubuntu or Fedora Atomic, so
in practice building from source is the only route. On Arch, genuinely just install
`bluez-utils` and use the systemd units from [MANUAL_INSTALL.md](MANUAL_INSTALL.md), you
don't need anything from this repo but the config.

**Where it runs.** It is **x86_64 only** (there is no ARM build; on arm64 you must build
your own, see [MANUAL_INSTALL.md](MANUAL_INSTALL.md)). It's compiled on Debian 12 on
purpose, so it needs nothing newer than **`GLIBC_2.34`** and links only against glibc:

| Target | glibc | |
|---|---|---|
| Proxmox 8 host (Debian 12) | 2.36 | starts cleanly |
| Proxmox 9 host (Debian 13) | 2.41 | **full bridge tested end to end on real hardware** |
| Debian 12+ / Ubuntu 22.04+ guests | 2.35+ | starts cleanly |
| Fedora / ChimeraOS / Bazzite guests | 2.38+ | starts cleanly |

Anything with glibc 2.34 or newer will run it. "Starts cleanly" means exactly that,
verified in containers for those rows; only the Proxmox 9 row has had the whole bridge
exercised against a real adapter. CI fails if a change ever raises the requirement past
glibc 2.36, since that would silently break Proxmox 8.

**Verify it yourself, in about a minute.** The expected hash is pinned inside
`install.sh`, so it is part of the script you already read, not fetched from the same
place as the binary:

```bash
grep BTPROXY_SHA256 install.sh          # expected hash
sha256sum bin/btproxy-x86_64            # what you actually have
```

`install.sh` refuses to install anything that doesn't match, and deletes it.

**It reproduces byte-for-byte.** Building BlueZ 5.66 on Debian 12 yields exactly the
committed binary, same SHA-256, and CI checks that on every commit: it rebuilds from the
kernel.org tarball and fails if the result differs from what's in `bin/`. So the badge
isn't "some binary compiles", it's "the file you're about to run is that source, compiled".
Confirm it yourself in one command:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w debian:bookworm bash -c \
  'bash build.sh && cmp bin/btproxy-x86_64 build/btproxy-x86_64 && echo IDENTICAL'
```

(`--platform linux/amd64` matters on an ARM host, without it Docker pulls the arm64 image
and you'd compare an aarch64 build against an x86_64 one.)

(Reproducibility is pinned to that container image; a different distro or compiler version
can produce different bytes from the same source, which is why both the shipped build and
CI use Debian 12.) Or build your own and run that instead,
[MANUAL_INSTALL.md](MANUAL_INSTALL.md) walks through it.

## Does my chip work?

If your Proxmox host can see it, your VM can have it. Run this on the host:

```bash
curl -fsSL https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main/install.sh | sudo bash -s -- --check
```

If it's healthy, you'll see:

```
==> Bluetooth adapters on this machine:
    [0] hci0 - 70:08:10:A4:F1:45 (USB)
==> All adapters healthy. You are good to go.
```

**What to do:** nothing - run the install command above.

If your chip is the stuck-Intel-chip case, you'll see:

```
!! hci0 is NOT responding (stuck in bootloader).
   Fix: shut down, flip the power supply switch OFF for 15 seconds, boot.
   A reboot or the front power button is NOT enough. See README.
```

**What to do:** exactly what it says. This looks extreme but it's the one thing that
actually works - see the FAQ below for why.

Confirmed by real people (add yours with a PR):

| Hardware | Status |
|---|---|
| Intel BE200 | ✅ Tested - this repo exists because of it |
| Intel AX200 / AX210 / AX211 | ✅ Same family, same behavior |
| MediaTek MT7921 / MT7922 | ✅ Standard Linux support |
| Generic CSR / Realtek USB dongles | ✅ Anything your host's Linux drives |
| UGREEN "BT 6.0" dongles (Barrot chip) | ❌ Broken firmware on Linux, bridge or not. Avoid. |

## All the commands

Run these on whichever machine they apply to. Under `curl | bash` append them after
`-s --`, e.g. `curl -fsSL <url>/install.sh | sudo bash -s -- --status`.

| Command | Where | What it does |
|---|---|---|
| `install.sh` | host | Share this machine's Bluetooth |
| `install.sh <host-ip>` | VM | Connect to a shared adapter |
| `install.sh --check` | host | List adapters and flag a stuck chip |
| `install.sh --status` | either | **Start here when something's wrong.** Shows both sides |
| `install.sh --adapter N` | host | Pick a chip when there's more than one |
| `install.sh --allow <ip/cidr>` | host | Restrict port 9700 to one address |
| `install.sh --allow-any` | host | Remove that restriction |
| `install.sh --pause` | host | Take Bluetooth back temporarily (until reboot) |
| `install.sh --resume` | host | Hand it back to the VM |
| `install.sh --uninstall` | either | Remove everything, restore normal Bluetooth |

### When it doesn't work

Run `--status` first, it tells you which side is broken. Then:

| Symptom | Look at |
|---|---|
| No adapter appears in the VM | `journalctl -u btproxy-client -n 30` in the VM |
| Host says it's sharing, VM never connects | Wrong IP, or a `--allow` rule blocking the VM's real source address. Check with `ip route get <host-ip>` **inside the VM** |
| Adapter appears, won't pair | `bluetoothctl show` in the VM; if `Powered: no`, run `bluetoothctl power on` |
| Worked, then stopped after a VM reboot | `systemctl restart btproxy-server` on the host |
| `--check` says the chip is stuck | Full power-off at the PSU switch for 15s, see the FAQ below |

Still stuck? Open an issue with the output of `--status` from both machines.

## FAQ, in human words

### Will my controller lag?
No. The bridge adds well under a millisecond on the same machine. Bluetooth itself is slower.

### Does it work for headphones, keyboards, Home Assistant sensors?
Yes - the bridge is protocol-transparent (it forwards raw Bluetooth traffic, it doesn't
understand or filter it). Anything that works on a normal Linux Bluetooth adapter works:
controllers, audio, HID, BLE sensors for Home Assistant.

### Can I pair several devices at once?
Yes. It behaves exactly like a normal adapter in the VM - two controllers plus headphones
is fine. The one-at-a-time limit is about VMs (one VM owns the chip), not devices.

### Do I need to buy anything?
No. The card you already have works. Even the old one you replaced probably worked.

### My whole VM "died" - black screen, no network (ChimeraOS / Bazzite).
It didn't die - it went to sleep. Gaming distros auto-suspend after idle like a
Steam Deck, and a VM with GPU passthrough never wakes from that. Turn suspend off
for good inside the VM:
`sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`

### My controller pairs but nothing responds in Steam (ChimeraOS / Bazzite).
Known quirk in their input layer, not in Bluetooth: run
`sudo systemctl restart inputplumber`, then turn the controller off and on. Fixed.

### My Intel card looks completely dead. No adapter, scary log lines.
It is stuck in its blank boot state. Shut the machine down and flip the **power supply
switch off for 15 seconds**, then boot. A reboot is not enough. The front power button is
not enough. This one trick cost us a full day - you're welcome.

### I have more than one Bluetooth chip on the host.
`--check` lists every adapter it finds (`hci0`, `hci1`, ...) with its MAC address so you
can tell them apart, and if it finds more than one it won't guess - it'll ask you to pick.
Share a specific one with `./install.sh --adapter 1`. Bridging two chips into two different
VMs *at the same time* isn't supported yet (one install per host today) - open an issue if
you need it, it's a small change.

### My VM died / I rebuilt it / I want Bluetooth in a different VM.
Just run the client one-liner in the new VM - the host serves whichever VM connects
(one at a time). Nothing to clean up after a dead VM. If the old VM is still running,
stop its client first (`--uninstall` there). Only footnote: pairings live inside the
guest, so pair your devices once in the new VM.

### Does it survive ChimeraOS / Bazzite OS updates?
Yes. Those distros replace the system image on update but keep `/etc` and `/var` - which
is exactly where this installs. Your bridge and pairings come back on their own.

### Does the host lose its own Bluetooth?
Yes, while sharing. A server in a closet rarely misses it. Need it back for a moment?
`--pause` returns the chip to the host, `--resume` hands it back to the VM (which
reconnects by itself). Note `--pause` is not permanent: it stops the service but leaves it
enabled, so a host reboot starts sharing again. `--uninstall` removes everything for good.

### Is this secure?
Be aware of the trade-off. `btproxy` speaks plain, unauthenticated TCP on port 9700, so by
default **whichever machine on your LAN connects first gets the Bluetooth chip** - and raw
HCI access means that machine can drive the radio, not just read from it.

Lock it to your VM:

```bash
./install.sh --allow 192.168.1.50      # a single VM
./install.sh --allow 192.168.1.0/24    # or a trusted subnet
```

That installs an nftables rule (in its own `proxmox-bluetooth` table, so it won't disturb
`pve-firewall`) that accepts port 9700 from that address and drops it from everything else.
It's tied to the service and loads on boot; if the rule ever fails to load the service
refuses to start rather than come up unprotected. `--uninstall` removes it, and the setting
is remembered, so a later plain re-install won't quietly reopen the port (use
`--allow-any` if you actually want it open again).

Use your VM's **actual source IP**. A machine with several interfaces may reach the host
from an address you didn't expect, check with `ip route get <host-ip>` inside the VM.

There is no encryption either, so treat this as a trusted-LAN tool: fine between a host and
its own VM, not something to route across networks you don't control.

### Poor range? Devices only pair up close?
That's antennas, not the bridge. M.2 cards need their two little antenna cables connected;
a bare card inside a metal case has almost no reach. USB dongles: a front port or a short
extension beats the back-panel ports next to all your other cables.

### What about Windows VMs?
The bridge is for Linux guests (it relies on Linux's Bluetooth stack). Windows VMs
usually don't have this problem: passing a USB dongle straight through with
`qm set <vmid> -usb0 host=<id>` just works there. This tool exists because Linux
guests choke where Windows shrugs.

### What about LXC containers?
Containers share the host's kernel, so they don't need this bridge - you can hand the
host's Bluetooth to an LXC directly (bind the device / cgroup allow). This tool is for
real VMs, where the guest runs its own kernel.

### Is this Proxmox only?
No - any Linux host with KVM VMs (or even two separate machines). Proxmox is just where
it hurts the most.

<details>
<summary><b>For the curious: what's actually happening</b></summary>

Intel CNVi Bluetooth (BE200/AX2xx) requires the host's `btusb`/`btintel` driver to load
its firmware at boot. Any passthrough handoff (USB redirect, vfio, driver unbind) resets
the chip to its ROM bootloader, and the guest can never complete the firmware handshake.

The bridge is `btproxy` from the official BlueZ source tree (never shipped in distro
packages). On the host it opens the adapter in HCI user-channel mode and serves raw HCI
over TCP. In the guest it creates a virtual controller via `hci_vhci` and pipes the
stream into it. BlueZ in the guest neither knows nor cares.

Systemd units: `btproxy-server.service` (host, replaces `bluetooth.service`) and
`btproxy-client.service` (guest, ordered before `bluetooth.service` via drop-in).

The bundled binary is built from bluez 5.66 `tools/btproxy` with plain `-O2` (replacing
autoconf's default `-g -O2`, so no debug info survives the `strip`). It links only against
glibc. See [`build.sh`](build.sh), and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
for the three upstream licenses that binary carries.

</details>

## Support this project

This fix cost a full day of head-scratching, three "dead" reboots, and one very real walk
to the power supply switch - so nobody else has to lose that day. Tools like this stay free
and maintained for exactly one reason: people who were helped choose to help the next person
in line. If that's you right now, thank you. It genuinely keeps this alive.

<p align="left">
  <a href="https://ko-fi.com/lucidfabrics"><img src="https://img.shields.io/badge/-Ko--fi-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Support on Ko-fi"></a>
  <a href="https://buymeacoffee.com/lucidfabrics"><img src="https://img.shields.io/badge/-Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black" alt="Buy Me a Coffee"></a>
  <a href="https://github.com/sponsors/lucid-fabrics"><img src="https://img.shields.io/badge/-GitHub%20Sponsors-EA4AAA?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="GitHub Sponsors"></a>
</p>

## Uninstall

Same script, `--uninstall`, on whichever machine you want to restore.

## License

This repository's own code (install.sh, build.sh, docs) is MIT, see [LICENSE](LICENSE).
The bundled `bin/btproxy-x86_64` binary is unmodified third-party BlueZ code under
GPL-2.0-or-later (with LGPL-2.1 and BSD-2-Clause parts), see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). `install.sh` writes that notice and the
GPL source offer to `/usr/local/share/doc/proxmox-bluetooth/` alongside the binary.

An independent community project, not affiliated with or endorsed by Proxmox Server
Solutions GmbH or the BlueZ project. "Proxmox" is a registered trademark of Proxmox Server
Solutions GmbH; other names belong to their respective owners.
