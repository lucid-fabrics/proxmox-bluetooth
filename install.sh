#!/usr/bin/env bash
# proxmox-bluetooth - Bluetooth in your Proxmox VMs, finally.
# One script for both sides. It detects where it is running:
#   on the Proxmox host -> shares the Bluetooth chip
#   inside a VM         -> connects to the shared chip
#
# Usage:
#   ./install.sh                    # auto mode (host = share, VM = connect)
#   ./install.sh --adapter 1        # host: share a specific chip (multiple chips)
#   ./install.sh --allow 192.168.1.50   # host: only this IP/CIDR may take the chip
#   ./install.sh --allow-any        # host: drop a previous --allow restriction
#   ./install.sh <host-ip>          # inside a VM: connect to this host
#   ./install.sh --check            # is my Bluetooth chip healthy? (lists all chips)
#   ./install.sh --status           # is the bridge working? (either side)
#   ./install.sh --pause            # host: take Bluetooth back temporarily
#   ./install.sh --resume           # host: share it with the VM again
#   ./install.sh --uninstall        # undo everything, restore normal Bluetooth

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/lucid-fabrics/proxmox-bluetooth/main"
PORT=9700
ADAPTER=""
ALLOW=""
ALLOW_ANY=0
FW_FILE=/etc/proxmox-bluetooth/firewall.nft
ALLOW_FILE=/etc/proxmox-bluetooth/allow

# SHA-256 of bin/btproxy-x86_64, pinned here on purpose. Downloading the checksum
# next to the binary would prove nothing (whoever could swap one could swap both),
# so the expected hash lives in the script you just read. Verified by the test suite
# against bin/btproxy-x86_64.sha256 so the two cannot drift apart.
BTPROXY_SHA256=4c9176d3550e95be1062055fa50de189ed271042d6511266bcd538be45687b89

# How to re-invoke this script in a form the user can actually paste back. Under
# `curl ... | sudo bash` there is no script on disk and $0 is literally "bash", so
# printing "$0 --resume" would hand the user a command that cannot run.
self() {
    case "$0" in
        bash|sh|-bash|-sh|/bin/bash|/bin/sh|/dev/fd/*|/proc/self/fd/*)
            echo "curl -fsSL $REPO_RAW/install.sh | sudo bash -s --" ;;
        *) echo "$0" ;;
    esac
}

# Accept only a real IPv4 address or CIDR. Checking octet and prefix ranges matters:
# a /0 prefix matches every address no matter what network precedes it (nft rewrites
# 10.0.0.0/0 to 0.0.0.0/0), so pattern-matching a couple of literal strings would let
# "--allow 10.0.0.0/0" through and then report the port as locked down.
validate_allow() {
    local v="$1" ip prefix o
    [[ "$v" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
        || die "--allow needs an IP or CIDR, e.g. --allow 192.168.1.50 or --allow 192.168.1.0/24"
    ip=${v%%/*}
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$o" -le 255 ] || die "--allow: $o is not a valid address octet (0-255)."
    done
    case "$v" in
        */*)
            prefix=${v##*/}
            [ "$prefix" -le 32 ] || die "--allow: /$prefix is not a valid IPv4 prefix (0-32)."
            [ "$prefix" -eq 0 ] && die "--allow $v matches every address, which is no restriction at all.
  If that is really what you want, use --allow-any." ;;
    esac
    [ "$ip" = "0.0.0.0" ] && die "--allow $v matches every address, which is no restriction at all.
  If that is really what you want, use --allow-any."
    return 0
}

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

verify_binary() { # verify_binary <file> <sha256-file>
    local want got
    want=$(cut -d" " -f1 "$2")
    got=$(sha256sum "$1" | cut -d" " -f1)
    [ "$want" = "$got" ] || die "Checksum mismatch for btproxy - corrupted download? Try again."
}

get_binary() {
    if [ ! -x "$BIN" ]; then
        local here; here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
        if [ -f "$here/bin/btproxy-x86_64" ]; then
            # Check against the hash pinned in this script, not against the .sha256 file
            # sitting next to the binary: anyone who could swap one could swap both, and
            # a missing .sha256 must not mean "install it unverified".
            local local_got
            local_got=$(sha256sum "$here/bin/btproxy-x86_64" | cut -d" " -f1)
            [ "$local_got" = "$BTPROXY_SHA256" ] || die "$here/bin/btproxy-x86_64 does not match the hash pinned in this script.
    expected: $BTPROXY_SHA256
    got:      $local_got
  Refusing to install it. Build it yourself instead: see MANUAL_INSTALL.md"
            install -m755 "$here/bin/btproxy-x86_64" "$BIN"
        else
            say "Downloading btproxy..."
            curl -fsSL "$REPO_RAW/bin/btproxy-x86_64" -o "$BIN" || die "Download failed. No internet?"
            local got
            got=$(sha256sum "$BIN" | cut -d" " -f1)
            if [ "$got" != "$BTPROXY_SHA256" ]; then
                rm -f "$BIN"
                die "btproxy failed checksum verification.
    expected: $BTPROXY_SHA256
    got:      $got
  Refusing to install it. Build it yourself instead: see MANUAL_INSTALL.md"
            fi
            say "Checksum verified against the hash pinned in this script."
            chmod 755 "$BIN"
        fi
    fi
    # The binary we just installed is GPL-2.0-or-later (plus LGPL-2.1 and BSD-2-Clause
    # parts). Those terms have to travel with it, not just live in the git repo, so drop
    # the notice and the source offer next to it on disk.
    # Prefer the conventional location, but fall back to sitting beside the binary:
    # /usr/local is read-only on immutable guests (ChimeraOS, Bazzite), and those are
    # exactly the systems that can only use the prebuilt binary, so they must not be
    # the ones that end up with no license text at all.
    # Test writability, not just mkdir: on a read-only filesystem `mkdir -p` still
    # succeeds when the directory already exists, and the write would then fail.
    local docdir=/usr/local/share/doc/proxmox-bluetooth
    if ! mkdir -p "$docdir" 2>/dev/null || ! touch "$docdir/.wtest" 2>/dev/null; then
        docdir="$(dirname "$BIN")"
    fi
    rm -f "$docdir/.wtest" 2>/dev/null || true
    cat > "$docdir/THIRD_PARTY_LICENSES" <<EOF
$BIN is an unmodified build of 'btproxy' from the BlueZ project
(https://www.kernel.org/pub/linux/bluetooth/bluez-5.66.tar.xz), not code written by
the proxmox-bluetooth project.

It is licensed GPL-2.0-or-later, and additionally contains:
  - LGPL-2.1-or-later code (src/shared/util.c, mainloop.c and other libshared sources)
    Copyright (C) Intel Corporation, Marcel Holtmann and BlueZ contributors
  - BSD-2-Clause code (src/shared/ecc.c), Copyright (c) 2013 Kenneth MacKay,
    All rights reserved.

BSD-2-Clause requires that binary redistributions reproduce its copyright notice and
disclaimer; the full text of all three licenses is at:
  https://github.com/lucid-fabrics/proxmox-bluetooth/tree/main/LICENSES

WRITTEN OFFER (GPL-2.0 section 3b): for three years from the date you received this
binary, the author will provide a complete machine-readable copy of the corresponding
source code for no more than the cost of distribution. Request it at
https://github.com/lucid-fabrics/proxmox-bluetooth/issues

The proxmox-bluetooth tooling around it (install.sh and docs) is MIT licensed.
EOF

    # btproxy (a bluez test tool) leaks its session on abnormal peer hangup;
    # the next connection then gets "resource busy" forever. This wrapper exits
    # on those symptoms so systemd (Restart=always) restarts it with a clean
    # session - proven necessary on the first real VM reboot.
    cat > "$BIN-run" << EOF
#!/bin/bash
# Watch btproxy's output and kill it by PID (not by name - the process may not be
# called "btproxy") the moment it reports a dead session, then exit nonzero so
# systemd's Restart=always brings it back with a clean one.
set -u
d=\$(mktemp -d) || exit 1
f="\$d/out"
mkfifo "\$f" || { rm -rf "\$d"; exit 1; }
trap 'rm -rf "\$d"' EXIT
$BIN "\$@" > "\$f" 2>&1 &
bt=\$!
while IFS= read -r line; do
    echo "\$line"
    case "\$line" in
        *"Remote hangup"*|*"Error from host"*|*"resource busy"*|*"No controller available"*)
            kill "\$bt" 2>/dev/null
            break ;;
    esac
done < "\$f"
wait "\$bt" 2>/dev/null
exit 1
EOF
    chmod 755 "$BIN-run"
}

# Prints "idx mac bus" for every adapter found, one per line. Returns 1 if none.
list_adapters() {
    local found=1
    for d in "${PBT_SYS_BT:-/sys/class/bluetooth}"/hci*; do
        [ -e "$d" ] || continue
        found=0
        local name=${d##*/} mac bus
        mac=$(cat "$d/address" 2>/dev/null || true)
        [ -z "$mac" ] && mac=$(hciconfig "$name" 2>/dev/null | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1 || true)
        # Must stay a single whitespace-free token: callers parse this with
        # `read -r idx mac bus`, so a multi-word value would shift the columns.
        [ -z "$mac" ] && mac="-"
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
        [ "$mac" = "-" ] && mac="address not readable yet"
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
            "00:00:00:00:00:00"|"-")
                # An unreadable address on its own is normal: the kernel only
                # publishes it once something brings the adapter up. On a stock
                # Proxmox host (no bluez installed) or while this bridge already
                # holds the chip, that never happens and nothing is wrong. Only
                # the firmware-handshake errors below mean a genuinely dead chip.
                if dmesg | grep -qE "hci$idx: (command .* tx timeout|.*failed \(-110\))"; then
                    warn "hci$idx is NOT responding (stuck in bootloader)."
                    echo "   Fix: shut down, flip the power supply switch OFF for 15 seconds, boot."
                    echo "   A reboot or the front power button is NOT enough. See README."
                    bad=1
                fi ;;
        esac
    done < <(list_adapters)
    [ "$bad" = 0 ] && say "All adapters healthy. You are good to go."
    local count; count=$(list_adapters | wc -l)
    if [ "$count" -gt 1 ]; then
        echo
        say "More than one adapter found - when sharing, pick one:"
        echo "    $(self) --adapter <number>"
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
            die "Multiple adapters found. Re-run with: $(self) --adapter <number>"
        fi
        ADAPTER=$(list_adapters | awk '{print $1}')
    else
        list_adapters | awk '{print $1}' | grep -qxF "$ADAPTER" || die "No adapter hci$ADAPTER on this machine."
    fi
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1); exit}')
    [ -n "$ip" ] || die "Could not detect this machine's IP."

    # btproxy speaks plain TCP with no authentication: whoever connects first
    # gets the adapter. --allow pins that to one address so a stray machine on
    # the LAN cannot claim the chip out from under your VM.
    # A previous --allow is remembered, so re-running the plain installer (say after
    # an update) cannot silently drop the restriction and reopen the port.
    if [ "$ALLOW_ANY" = 1 ]; then
        ALLOW=""
    elif [ -z "$ALLOW" ] && [ -f "$ALLOW_FILE" ]; then
        # Re-validate what came off disk. An empty or truncated file (a crash mid-write)
        # would otherwise leave ALLOW empty, fall through to the else branch below, and
        # silently tear the firewall down - the exact failure this file exists to prevent.
        ALLOW=$(cat "$ALLOW_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')
        [ -n "$ALLOW" ] || die "$ALLOW_FILE exists but is empty, so the previous restriction cannot be restored.
  Refusing to silently reopen port $PORT. Re-apply it with --allow <ip>, or drop it with --allow-any."
        validate_allow "$ALLOW"
        say "Keeping the existing restriction: only $ALLOW may connect (--allow-any to remove)."
    fi

    local fw_pre="" fw_post="" nft_bin=""
    if [ -n "$ALLOW" ]; then
        nft_bin=$(command -v nft) || die "--allow needs nftables. Install it (apt install nftables) or firewall port $PORT yourself."
        mkdir -p "$(dirname "$FW_FILE")"
        # `table` then `delete table` makes reloading idempotent: the first line
        # creates it when absent so the delete cannot fail on a fresh boot.
        cat > "$FW_FILE" <<EOF
table inet proxmox-bluetooth
delete table inet proxmox-bluetooth
table inet proxmox-bluetooth {
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport $PORT ip saddr $ALLOW accept
    tcp dport $PORT drop
  }
}
EOF
        "$nft_bin" -f "$FW_FILE" || die "Could not load the firewall rule from $FW_FILE"
        printf '%s\n' "$ALLOW" > "$ALLOW_FILE"
        # No leading "-": if the rule cannot load, the service must NOT start. Starting
        # anyway would silently expose the adapter to the whole LAN.
        fw_pre="ExecStartPre=$nft_bin -f $FW_FILE"
        fw_post="ExecStopPost=-$nft_bin delete table inet proxmox-bluetooth"
    else
        rm -f "$ALLOW_FILE" "$FW_FILE"
        # Drop any table left over from a previous --allow, otherwise the port would
        # stay restricted until the next reboot with nothing on disk saying so.
        # `|| true` matters: with `set -e`, a failing delete (the normal case, when no
        # table is loaded) would abort the whole install as the last statement here.
        command -v nft >/dev/null && nft delete table inet proxmox-bluetooth 2>/dev/null || true
    fi

    cat > /etc/systemd/system/btproxy-server.service <<EOF
[Unit]
Description=Share this machine's Bluetooth chip (hci$ADAPTER) with VMs (proxmox-bluetooth)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=-/bin/systemctl stop bluetooth
ExecStartPre=-/usr/bin/hciconfig hci$ADAPTER down
$fw_pre
ExecStart=$BIN-run -i $ADAPTER -l$ip -p $PORT
$fw_post
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl disable --now bluetooth >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable btproxy-server >/dev/null 2>&1
    # restart, not `enable --now`: on a re-run the service is already active and
    # `--now` would leave it running with the previous unit file still in effect.
    systemctl restart btproxy-server
    sleep 1
    systemctl is-active --quiet btproxy-server || die "Server failed to start. Run: journalctl -u btproxy-server"
    say "Bluetooth (hci$ADAPTER) is now shared on $ip:$PORT."
    echo
    echo "  Now run this INSIDE your VM:"
    echo
    echo "    curl -fsSL $REPO_RAW/install.sh | sudo bash -s -- $ip"
    echo
    if [ -n "$ALLOW" ]; then
        say "Locked down: only $ALLOW can connect to port $PORT."
    else
        warn "Port $PORT is open to your whole LAN and has no password."
        echo "   Whichever machine connects first gets the Bluetooth chip."
        echo "   Once you know your VM's IP, restrict it:"
        echo "       $(self) --allow <vm-ip>"
    fi
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
ExecStart=$BIN-run -c $host_ip -p $PORT
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
    local bt_show bt_list
    bt_show=$(bluetoothctl show 2>/dev/null || true)
    bt_list=$(bluetoothctl list 2>/dev/null || true)
    if grep -q "Powered: yes" <<< "$bt_show"; then
        say "Done. This VM now has working Bluetooth. Go pair your controller."
    elif grep -q Controller <<< "$bt_list"; then
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

status() {
    local any=0 rc=0
    if [ -f /etc/systemd/system/btproxy-server.service ]; then
        any=1
        say "This machine SHARES its Bluetooth (server side)"
        if systemctl is-active --quiet btproxy-server; then
            echo "    [ok] btproxy-server running"
            local lp
            # `|| true`: with pipefail a non-matching grep would abort status() here,
            # which is the one command users are told to run when things are broken.
            lp=$(ss -tln 2>/dev/null | grep ":$PORT " | awk '{print $4}' | head -1 || true)
            if [ -n "$lp" ]; then echo "    [ok] listening on $lp"; else echo "    [!!] not listening on port $PORT"; rc=1; fi
            local est; est=$(ss -tn 2>/dev/null || true)
            if grep -q ":$PORT " <<< "$est"; then
                echo "    [ok] a VM is connected"
            else
                echo "    [--] no VM connected right now (client off or still retrying)"
            fi
        elif systemctl is-enabled --quiet btproxy-server 2>/dev/null; then
            echo "    [--] paused (resume with: $(self) --resume)"
        else
            echo "    [!!] btproxy-server not running - journalctl -u btproxy-server"; rc=1
        fi
    fi
    if [ -f /etc/systemd/system/btproxy-client.service ]; then
        any=1
        say "This machine USES a shared Bluetooth chip (VM side)"
        if systemctl is-active --quiet btproxy-client; then
            echo "    [ok] btproxy-client running"
        else
            echo "    [!!] btproxy-client not running - journalctl -u btproxy-client"; rc=1
        fi
        local bt_show bt_list
        bt_show=$(bluetoothctl show 2>/dev/null || true)
        bt_list=$(bluetoothctl list 2>/dev/null || true)
        if grep -q "Powered: yes" <<< "$bt_show"; then
            echo "    [ok] adapter present and powered - Bluetooth is usable"
        elif grep -q Controller <<< "$bt_list"; then
            echo "    [!!] adapter present but not powered - try: bluetoothctl power on"; rc=1
        else
            echo "    [!!] no adapter yet - server unreachable or paused (retrying every 3s)"; rc=1
        fi
    fi
    [ "$any" = 1 ] || die "Nothing installed on this machine (run the install first)."
    return $rc
}

pause() {
    [ -f /etc/systemd/system/btproxy-server.service ] || die "Nothing is shared from this machine (no btproxy-server installed)."
    systemctl stop btproxy-server
    systemctl start bluetooth 2>/dev/null || true
    say "Sharing paused. This machine owns its Bluetooth again."
    echo "  The VM will show no adapter until you resume:  $(self) --resume"
    echo "  (A host reboot also resumes sharing automatically.)"
}

resume() {
    [ -f /etc/systemd/system/btproxy-server.service ] || die "Nothing to resume (no btproxy-server installed)."
    systemctl stop bluetooth 2>/dev/null || true
    systemctl start btproxy-server
    sleep 1
    systemctl is-active --quiet btproxy-server || die "Failed to resume. Run: journalctl -u btproxy-server"
    say "Sharing resumed. The VM reconnects by itself within a few seconds."
}

uninstall() {
    systemctl disable --now btproxy-server 2>/dev/null || true
    systemctl disable --now btproxy-client 2>/dev/null || true
    rm -f /etc/systemd/system/btproxy-server.service /etc/systemd/system/btproxy-client.service
    rm -f /etc/systemd/system/bluetooth.service.d/proxmox-bluetooth.conf
    # Only remove /usr/local/bin/btproxy when it is the copy we installed. Someone
    # who followed MANUAL_INSTALL.md put their own hand-built btproxy at that exact
    # path, and uninstalling this tool must not delete their build.
    if [ -f /usr/local/bin/btproxy ] \
       && [ "$(sha256sum /usr/local/bin/btproxy | cut -d' ' -f1)" = "$BTPROXY_SHA256" ]; then
        rm -f /usr/local/bin/btproxy
    elif [ -f /usr/local/bin/btproxy ]; then
        warn "Left /usr/local/bin/btproxy alone - it is not the build this tool installed."
    fi
    rm -f /usr/local/bin/btproxy-run
    rm -rf /usr/local/share/doc/proxmox-bluetooth
    # get_binary() falls back to writing the notice beside the binary when the doc dir
    # is read-only, so clear that copy too rather than leaving it orphaned.
    rm -f /usr/local/bin/THIRD_PARTY_LICENSES
    rm -rf /var/lib/proxmox-bluetooth
    nft delete table inet proxmox-bluetooth 2>/dev/null || true
    rm -rf /etc/proxmox-bluetooth
    rmdir /etc/systemd/system/bluetooth.service.d 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now bluetooth 2>/dev/null || true
    say "Removed. Normal Bluetooth restored on this machine."
}

# Test seam: `PBT_SOURCED=1 source install.sh` loads the functions and stops here.
if [ "${PBT_SOURCED:-0}" = 1 ]; then return 0; fi

if [ "$(id -u)" != 0 ]; then
    # Only re-exec when $0 is a real file. Piped from curl, $0 is "bash" and
    # `sudo -E bash bash` would run whatever "bash" resolves to, not this script.
    if [ -f "$0" ] && [ -r "$0" ]; then
        exec sudo -E bash "$0" "$@"
    fi
    die "Please re-run this as root, e.g.:
    curl -fsSL $REPO_RAW/install.sh | sudo bash -s -- $*"
fi

# /usr/local is read-only on immutable guests (ChimeraOS, Bazzite) - fall back
# to /var, which stays writable and survives their OS updates.
if mkdir -p /usr/local/bin 2>/dev/null && touch /usr/local/bin/.pbt-w 2>/dev/null; then
    rm -f /usr/local/bin/.pbt-w
    BIN=/usr/local/bin/btproxy
else
    mkdir -p /var/lib/proxmox-bluetooth
    BIN=/var/lib/proxmox-bluetooth/btproxy
fi

# --- argument parsing ---
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --adapter)
            ADAPTER="${2:-}"
            # Must be digits: a bare `--adapter --allow 1.2.3.4` would otherwise set
            # ADAPTER=--allow and let the IP fall through to the client path, quietly
            # turning a Proxmox host into a bridge *client*.
            [[ "$ADAPTER" =~ ^[0-9]+$ ]] \
                || die "--adapter needs a number (run --check to list adapters)"
            shift 2 ;;
        --allow)
            [ "$ALLOW_ANY" = 0 ] || die "--allow and --allow-any contradict each other. Pick one."
            ALLOW="${2:-}"
            validate_allow "$ALLOW"
            shift 2 ;;
        --allow-any)
            [ -z "$ALLOW" ] || die "--allow and --allow-any contradict each other. Pick one."
            ALLOW_ANY=1; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]:-}"

case "${1:-}" in
    --check)     check ;;
    --status)    status ;;
    --pause)     pause ;;
    --resume)    resume ;;
    --uninstall) uninstall ;;
    "")
        # systemd-detect-virt exits 0 only when virtualization is detected
        if systemd-detect-virt --quiet 2>/dev/null; then
            die "This looks like a VM. Run the command printed by the host install, or: $(self) <host-ip>"
        else
            check; server
        fi ;;
    *)
        [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Not an IP address: $1"
        client "$1" ;;
esac
