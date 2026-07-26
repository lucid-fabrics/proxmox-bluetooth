# Manual install: build it yourself

`install.sh` is a convenience wrapper. Everything below is exactly what it does under the
hood, spelled out so you can run it by hand: compile `btproxy` from official BlueZ source
and write the systemd units yourself. No `curl | bash`, no prebuilt binary.

Follow the steps in order and you get a working bridge. Step 5 (locking the port down) adds
two lines to the host unit from step 3, everything else is written once.

**A note on `/usr/local/bin`:** the commands below install there, which is read-only on
ChimeraOS and Bazzite. On those guests use a writable path instead (`install.sh` uses
`/var/lib/proxmox-bluetooth`) and adjust the `ExecStart` lines to match. They also can't
build from source (see below), so on those two the prebuilt binary really is the practical
option.

One fact worth stating up front: **on Debian, Ubuntu and Fedora, `btproxy` is not
packaged.** Debian/Ubuntu's `bluez-test-tools` ships `btvirt`, `l2cap-tester` and a dozen
other BlueZ test tools, but not `btproxy`, and Fedora's `bluez` doesn't either (both
verified by inspecting package contents). Since Proxmox is Debian and the guests this
targets are Debian/Ubuntu or Fedora Atomic, building from source is the only route there.

**On Arch it is packaged:** `pacman -S bluez-utils` gives you `/usr/bin/btproxy`. If both
your machines are Arch, skip step 1 entirely and go straight to the systemd units below.

---

## 1. Build btproxy

Run this on the Proxmox host **and** inside the VM. Same steps, same binary.

```bash
sudo apt-get install -y build-essential libglib2.0-dev libdbus-1-dev libudev-dev \
    libical-dev libreadline-dev libsbc-dev libspeexdsp-dev libbluetooth-dev libjson-c-dev \
    libasound2-dev libell-dev wget

wget https://www.kernel.org/pub/linux/bluetooth/bluez-5.66.tar.xz
tar xf bluez-5.66.tar.xz && cd bluez-5.66

CFLAGS="-O2" ./configure --disable-manpages --with-udevdir=/lib/udev \
    --with-systemdsystemunitdir=no --with-systemduserunitdir=no
make tools/btproxy
strip tools/btproxy
sudo install -m755 tools/btproxy /usr/local/bin/btproxy
```

Proxmox is Debian-based, so this works as-is on the host, and unmodified in a
Debian/Ubuntu guest. **ChimeraOS and Bazzite guests are the exception:** they are Fedora
Atomic (`rpm-ostree`, immutable `/usr`, no `apt`), with no `build-essential` and nowhere
writable to build without layering a toolchain onto an atomic OS. That is the practical
reason this project ships a prebuilt binary for the VM side, on those two guests, building
from source isn't really an option.

## 2. Install the restart wrapper (both machines)

Do this before writing the units below, they will point at this wrapper.

`btproxy` leaks its HCI session when the peer disappears abruptly, which is exactly what a
VM reboot looks like. Every later connection then fails with `Device or resource busy`, and
`Restart=always` does not save you because the process never exits. This wrapper watches
its output and kills it by PID so systemd can restart it with a clean session:

```bash
sudo tee /usr/local/bin/btproxy-run << 'EOF'
#!/bin/bash
set -u
d=$(mktemp -d) || exit 1
f="$d/out"
mkfifo "$f" || { rm -rf "$d"; exit 1; }
trap 'rm -rf "$d"' EXIT
/usr/local/bin/btproxy "$@" > "$f" 2>&1 &
bt=$!
while IFS= read -r line; do
    echo "$line"
    case "$line" in
        *"Remote hangup"*|*"Error from host"*|*"resource busy"*|*"No controller available"*)
            kill "$bt" 2>/dev/null
            break ;;
    esac
done < "$f"
wait "$bt" 2>/dev/null
exit 1
EOF
sudo chmod 755 /usr/local/bin/btproxy-run
```

## 3. On the Proxmox host: share the adapter

Find your adapter index and this machine's IP:

```bash
ls /sys/class/bluetooth/            # e.g. hci0 -> adapter index is 0
ip route get 1.1.1.1                # note the "src" address
```

Create the unit. Replace `YOUR_HOST_IP`, and if your adapter isn't `hci0`, change the index
in **both** the `hciconfig hci0 down` line and the `-i 0` argument:

```bash
sudo tee /etc/systemd/system/btproxy-server.service << 'EOF'
[Unit]
Description=Share this machine's Bluetooth chip with VMs
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=-/bin/systemctl stop bluetooth
ExecStartPre=-/usr/bin/hciconfig hci0 down
ExecStart=/usr/local/bin/btproxy-run -i 0 -lYOUR_HOST_IP -p 9700
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl disable --now bluetooth
sudo systemctl daemon-reload
sudo systemctl enable --now btproxy-server
```

Both `ExecStartPre` lines are prefixed with `-` deliberately: a stock Proxmox host has no
bluez installed, so `bluetooth.service` and `hciconfig` may not exist, and neither is
required for the bridge to work.

## 4. Inside the VM: connect to it

Build btproxy and the wrapper (steps 1 and 2) in the VM too, then, replacing `HOST_IP`:

```bash
sudo modprobe hci_vhci

sudo tee /etc/systemd/system/btproxy-client.service << 'EOF'
[Unit]
Description=Use the Bluetooth chip shared by the host
After=network-online.target
Wants=network-online.target
Before=bluetooth.service

[Service]
ExecStart=/usr/local/bin/btproxy-run -c HOST_IP -p 9700
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /etc/systemd/system/bluetooth.service.d
printf '[Unit]\nAfter=btproxy-client.service\n' | sudo tee /etc/systemd/system/bluetooth.service.d/proxmox-bluetooth.conf

sudo systemctl daemon-reload
sudo systemctl enable --now btproxy-client
sudo systemctl restart bluetooth
```

A new adapter should now appear in the VM. Pair devices as usual with `bluetoothctl` or
your desktop's Bluetooth settings.

## 5. Restrict who can take the adapter

`btproxy` has no authentication: the first machine to connect on port 9700 gets the chip,
with raw HCI access to the radio. Limit it to your VM (replace `VM_IP`):

```bash
sudo mkdir -p /etc/proxmox-bluetooth
sudo tee /etc/proxmox-bluetooth/firewall.nft << 'EOF'
table inet proxmox-bluetooth
delete table inet proxmox-bluetooth
table inet proxmox-bluetooth {
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport 9700 ip saddr VM_IP accept
    tcp dport 9700 drop
  }
}
EOF
sudo nft -f /etc/proxmox-bluetooth/firewall.nft
```

The `table` / `delete table` / `table {...}` sequence makes reloading idempotent. Its own
table keeps it clear of `pve-firewall`.

Then add these two lines to the `[Service]` section of the **host** unit so the rule
reloads on boot and is removed on stop:

```ini
ExecStartPre=/usr/sbin/nft -f /etc/proxmox-bluetooth/firewall.nft
ExecStopPost=-/usr/sbin/nft delete table inet proxmox-bluetooth
```

Note there is no `-` on that `ExecStartPre`: if the rule cannot load, you want the service
to fail rather than come up with the port open to the LAN. Run
`sudo systemctl daemon-reload && sudo systemctl restart btproxy-server` to apply.

Use the VM's **actual source IP**, a machine with several interfaces may reach the host
from an address you didn't expect. Check inside the VM with `ip route get <host-ip>`.

## Keep the license notice with the binary

`btproxy` is GPL-2.0-or-later and also carries LGPL-2.1 and BSD-2-Clause code, so if you
redistribute your build, those terms have to travel with it. `install.sh` writes that
notice automatically; doing it by hand:

```bash
sudo mkdir -p /usr/local/share/doc/proxmox-bluetooth
sudo curl -fsSL -o /usr/local/share/doc/proxmox-bluetooth/THIRD_PARTY_LICENSES \
  https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main/THIRD_PARTY_LICENSES.md
```

Purely for your own machine this is optional, it matters when you pass the binary on.

## Uninstall

```bash
sudo rm -rf /usr/local/share/doc/proxmox-bluetooth
sudo systemctl disable --now btproxy-server btproxy-client 2>/dev/null
sudo rm -f /etc/systemd/system/btproxy-{server,client}.service
sudo rm -f /etc/systemd/system/bluetooth.service.d/proxmox-bluetooth.conf
sudo rm -f /usr/local/bin/btproxy /usr/local/bin/btproxy-run
sudo nft delete table inet proxmox-bluetooth 2>/dev/null
sudo rm -rf /etc/proxmox-bluetooth
sudo systemctl daemon-reload
sudo systemctl enable --now bluetooth 2>/dev/null   # if you use bluez on the host
```

## What `install.sh` adds on top of this

Nothing you cannot do above. It auto-detects the adapter and host IP, refuses to guess when
there are several adapters, writes the same wrapper and units, manages the firewall rule
and remembers it across re-installs, and adds `--check` / `--status` / `--pause` /
`--resume` / `--uninstall`. It also falls back to `/var/lib` on distros where
`/usr/local` is read-only (ChimeraOS, Bazzite). Follow every step here and you get the
same result.
