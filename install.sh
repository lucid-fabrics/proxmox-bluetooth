#!/usr/bin/env bash
# proxmox-bluetooth - Bluetooth in your Proxmox VMs, finally.
# One script for both sides. It detects where it is running:
#   on the Proxmox host -> shares the Bluetooth chip
#   inside a VM         -> connects to the shared chip
#
# Usage:
#   ./install.sh                    # auto mode (host = share, VM = connect)
#   ./install.sh --adapter 1        # host: share a specific chip (multiple chips)
#   ./install.sh <host-ip>          # inside a VM: connect to this host
#   ./install.sh --check            # is my Bluetooth chip healthy? (lists all chips)
#   ./install.sh --uninstall        # undo everything, restore normal Bluetooth

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main"
PORT=9700
BIN=/usr/local/bin/btproxy
ADAPTER=""

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

# Prints "idx mac bus" for every adapter found, one per line. Returns 1 if none.
list_adapters() {
    local found=1
    for d in /sys/class/bluetooth/hci*; do
        [ -e "$d" ] || continue
        found=0
        local name=${d##*/} mac bus
        mac=$(cat "$d/address" 2>/dev/null || true)
        [ -z "$mac" ] && mac=$(hciconfig "$name" 2>/dev/null | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1 || true)
        [ -z "$mac" ] && mac="address unavailable (adapter busy)"
        case "$(readlink -f "$d")" in
            *usb*) bus="USB" ;;
            *uart*|*serial*) bus="onboard" ;;
            *) bus="other" ;;
        esac
        echo "${name#hci} $mac $bus"
    done
    return $found
}

print_adapter_table() {
    say "Bluetooth adapters on this machine:"
    list_adapters | while read -r idx mac bus; do
        printf '    [%s] hci%s - %s (%s)\n' "$idx" "$idx" "$mac" "$bus"
    done
}

check() {
    if ! list_adapters >/dev/null; then
        warn "No Bluetooth adapter found on this machine."
        echo "   If you just installed a card: check dmesg | grep -i bluetooth"
        echo "   If it is an Intel card acting dead: power the machine fully OFF"
        echo "   at the power supply switch for 15 seconds. Yes, really. See README."
        exit 1
    fi
    print_adapter_table
    local bad=0
    while read -r idx mac bus; do
        # A real MAC means the chip completed its firmware handshake - it is fine,
        # even if old failure lines are still sitting in the dmesg ring buffer.
        case "$mac" in
            "00:00:00:00:00:00"|"address unavailable"*)
                if dmesg | grep -qE "hci$idx: (command .* tx timeout|.*failed \(-110\))"; then
                    warn "hci$idx is NOT responding (stuck in bootloader)."
                    echo "   Fix: shut down, flip the power supply switch OFF for 15 seconds, boot."
                    echo "   A reboot or the front power button is NOT enough. See README."
                    bad=1
                else
                    warn "hci$idx exists but its address is unreadable - probably already claimed"
                    echo "   (e.g. this bridge is already running). Not necessarily a problem."
                fi ;;
        esac
    done < <(list_adapters)
    [ "$bad" = 0 ] && say "All adapters healthy. You are good to go."
    local count; count=$(list_adapters | wc -l)
    if [ "$count" -gt 1 ]; then
        echo
        say "More than one adapter found - when sharing, pick one:"
        echo "    ./install.sh --adapter <number>"
    fi
    [ "$bad" = 0 ]
}

server() {
    get_binary
    list_adapters >/dev/null || die "No Bluetooth adapter found on this machine."
    local count; count=$(list_adapters | wc -l)
    if [ -z "$ADAPTER" ]; then
        if [ "$count" -gt 1 ]; then
            print_adapter_table
            die "Multiple adapters found. Re-run with: $0 --adapter <number>"
        fi
        ADAPTER=$(list_adapters | awk '{print $1}')
    else
        list_adapters | awk '{print $1}' | grep -qx "$ADAPTER" || die "No adapter hci$ADAPTER on this machine."
    fi
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1); exit}')
    [ -n "$ip" ] || die "Could not detect this machine's IP."
    cat > /etc/systemd/system/btproxy-server.service <<EOF
[Unit]
Description=Share this machine's Bluetooth chip (hci$ADAPTER) with VMs (proxmox-bluetooth)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=-/bin/systemctl stop bluetooth
ExecStartPre=-/usr/bin/hciconfig hci$ADAPTER down
ExecStart=$BIN -i $ADAPTER -l$ip -p $PORT
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
    say "Bluetooth (hci$ADAPTER) is now shared on $ip:$PORT."
    echo
    echo "  Now run this INSIDE your VM:"
    echo
    echo "    curl -fsSL $REPO_RAW/install.sh | sudo bash -s -- $ip"
    echo
    support_note
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
    support_note
}

support_note() {
    cat << 'EOF'

        ( (
         ) )
      .........
      |       |]
      \       /
       `-----'

  If this saved you a headache, a coffee keeps it maintained:
    https://github.com/sponsors/lucid-fabrics
    https://ko-fi.com/lucidfabrics
    https://buymeacoffee.com/lucidfabrics
EOF
}

uninstall() {
    systemctl disable --now btproxy-server 2>/dev/null || true
    systemctl disable --now btproxy-client 2>/dev/null || true
    rm -f /etc/systemd/system/btproxy-server.service /etc/systemd/system/btproxy-client.service
    rm -f /etc/systemd/system/bluetooth.service.d/proxmox-bluetooth.conf
    rm -f "$BIN"
    systemctl daemon-reload
    systemctl enable --now bluetooth 2>/dev/null || true
    say "Removed. Normal Bluetooth restored on this machine."
}

# --- argument parsing ---
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --adapter) ADAPTER="${2:-}"; [ -n "$ADAPTER" ] || die "--adapter needs a number (run --check to list adapters)"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]:-}"

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
