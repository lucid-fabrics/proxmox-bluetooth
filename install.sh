#!/usr/bin/env bash
# proxmox-bluetooth - Bluetooth in your Proxmox VMs, finally.
# One script for both sides. It detects where it is running:
#   on the Proxmox host -> shares the Bluetooth chip
#   inside a VM         -> connects to the shared chip
#
# Usage:
#   ./install.sh                 # auto mode (host = share, VM = connect)
#   ./install.sh <host-ip>       # inside a VM: connect to this host
#   ./install.sh --check         # is my Bluetooth chip healthy?
#   ./install.sh --uninstall     # undo everything, restore normal Bluetooth

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/wmehanna/proxmox-bluetooth/main"
PORT=9700
BIN=/usr/local/bin/btproxy

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

get_binary() {
    [ -x "$BIN" ] && return 0
    local here; here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -f "$here/bin/btproxy-x86_64" ]; then
        install -m755 "$here/bin/btproxy-x86_64" "$BIN"
    else
        say "Downloading btproxy..."
        curl -fsSL "$REPO_RAW/bin/btproxy-x86_64" -o "$BIN" || die "Download failed. No internet?"
        chmod 755 "$BIN"
    fi
}

check() {
    local hci
    hci=$(ls /sys/class/bluetooth 2>/dev/null | head -1) || true
    if [ -z "${hci:-}" ]; then
        warn "No Bluetooth adapter found on this machine."
        echo "   If you just installed a card: check dmesg | grep -i bluetooth"
        echo "   If it is an Intel card acting dead: power the machine fully OFF"
        echo "   at the power supply switch for 15 seconds. Yes, really. See README."
        exit 1
    fi
    if dmesg | grep -qE "hci0.*(command .* tx timeout|failed \(-110\))"; then
        warn "Adapter '$hci' found but it is NOT responding (stuck in bootloader)."
        echo "   Fix: shut down, flip the power supply switch OFF for 15 seconds, boot."
        echo "   A reboot or the front power button is NOT enough. See README."
        exit 1
    fi
    say "Adapter '$hci' found and healthy. You are good to go."
}

server() {
    get_binary
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1); exit}')
    [ -n "$ip" ] || die "Could not detect this machine's IP."
    cat > /etc/systemd/system/btproxy-server.service <<EOF
[Unit]
Description=Share this machine's Bluetooth chip with VMs (proxmox-bluetooth)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=-/bin/systemctl stop bluetooth
ExecStartPre=-/usr/bin/hciconfig hci0 down
ExecStart=$BIN -i 0 -l$ip -p $PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl disable --now bluetooth >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable --now btproxy-server
    sleep 1
    systemctl is-active --quiet btproxy-server || die "Server failed to start. Run: journalctl -u btproxy-server"
    say "Bluetooth is now shared on $ip:$PORT."
    echo
    echo "  Now run this INSIDE your VM:"
    echo
    echo "    curl -fsSL $REPO_RAW/install.sh | sudo bash -s -- $ip"
    echo
}

client() {
    local host_ip="$1"
    get_binary
    modprobe hci_vhci 2>/dev/null || true
    cat > /etc/systemd/system/btproxy-client.service <<EOF
[Unit]
Description=Use the Bluetooth chip shared by $host_ip (proxmox-bluetooth)
After=network-online.target
Wants=network-online.target
Before=bluetooth.service

[Service]
ExecStart=$BIN -c $host_ip -p $PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/system/bluetooth.service.d
    printf '[Unit]\nAfter=btproxy-client.service\n' > /etc/systemd/system/bluetooth.service.d/proxmox-bluetooth.conf
    systemctl daemon-reload
    systemctl enable --now btproxy-client
    sleep 2
    systemctl restart bluetooth 2>/dev/null || warn "bluetooth.service not found; is bluez installed?"
    sleep 2
    if bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
        say "Done. This VM now has working Bluetooth. Go pair your controller."
    elif bluetoothctl list 2>/dev/null | grep -q Controller; then
        bluetoothctl power on >/dev/null 2>&1 || true
        say "Done. Adapter is up. Go pair your controller."
    else
        warn "Connected, but no adapter appeared yet. Check: journalctl -u btproxy-client"
    fi
}

uninstall() {
    systemctl disable --now btproxy-server 2>/dev/null || true
    systemctl disable --now btproxy-client 2>/dev/null || true
    rm -f /etc/systemd/system/btproxy-server.service /etc/systemd/system/btproxy-client.service
    rm -f /etc/systemd/system/bluetooth.service.d/proxmox-bluetooth.conf
    systemctl daemon-reload
    systemctl enable --now bluetooth 2>/dev/null || true
    say "Removed. Normal Bluetooth restored on this machine."
}

case "${1:-}" in
    --check)     check ;;
    --uninstall) uninstall ;;
    "")
        if [ "$(systemd-detect-virt 2>/dev/null || echo none)" = "none" ]; then
            check; server
        else
            die "This looks like a VM. Run the command printed by the host install, or: $0 <host-ip>"
        fi ;;
    *)
        [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Not an IP address: $1"
        client "$1" ;;
esac
