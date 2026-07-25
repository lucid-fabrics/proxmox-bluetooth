#!/usr/bin/env bash
# Test suite for proxmox-bluetooth. Plain bash, no framework.
# Run from the repo root:  bash tests/run-tests.sh
# CLI tests (arg validation) only run as root - CI runs the whole thing with sudo.
set -u

cd "$(dirname "$0")/.."
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

check() { # check <description> <expected-rc> <actual-rc> <output> <must-contain>
    local desc="$1" want_rc="$2" rc="$3" out="$4" needle="${5:-}"
    if [ "$rc" != "$want_rc" ]; then fail "$desc (rc=$rc, wanted $want_rc)"; return; fi
    if [ -n "$needle" ] && ! grep -q "$needle" <<< "$out"; then
        fail "$desc (output missing: $needle)"; return
    fi
    ok "$desc"
}

echo "== syntax =="
out=$(bash -n install.sh 2>&1); check "install.sh parses" 0 $? "$out"
out=$(bash -n build.sh 2>&1);   check "build.sh parses"   0 $? "$out"

echo "== docs/ landing page =="
out=$(python3 -c "import json,re,sys
html = open('docs/index.html').read()
blocks = re.findall(r'<script type=\"application/ld\+json\">(.*?)</script>', html, re.S)
assert len(blocks) == 2, f'expected 2 JSON-LD blocks, found {len(blocks)}'
for b in blocks: json.loads(b)
print('JSONLD_OK')" 2>&1)
check "JSON-LD blocks are valid JSON" 0 $? "$out" "JSONLD_OK"

out=$(python3 -c "import xml.dom.minidom as m; m.parse('docs/sitemap.xml'); print('XML_OK')" 2>&1)
check "sitemap.xml is well-formed" 0 $? "$out" "XML_OK"

n_files=$(grep -l "lucid-fabrics.github.io/proxmox-bluetooth" docs/sitemap.xml docs/robots.txt docs/index.html 2>/dev/null | wc -l)
[ "$((n_files))" -eq 3 ] \
    && ok "canonical Pages URL present in sitemap, robots, and page" \
    || fail "canonical Pages URL missing from one of docs/{index.html,sitemap.xml,robots.txt}"

if command -v shellcheck >/dev/null; then
    echo "== shellcheck =="
    out=$(shellcheck -S error install.sh 2>&1); check "no shellcheck errors" 0 $? "$out"
else
    echo "== shellcheck skipped (not installed) =="
fi

echo "== binary checksum consistency =="
want=$(cut -d" " -f1 bin/btproxy-x86_64.sha256)
got=$(sha256sum bin/btproxy-x86_64 2>/dev/null | cut -d" " -f1 || shasum -a 256 bin/btproxy-x86_64 | cut -d" " -f1)
[ "$want" = "$got" ] && ok "bin/btproxy-x86_64.sha256 matches the committed binary" \
    || fail "checksum file does not match the binary - regenerate bin/btproxy-x86_64.sha256"

echo "== test seam =="
out=$(bash -c 'PBT_SOURCED=1 source ./install.sh && declare -F list_adapters get_binary pause resume >/dev/null && echo SEAM_OK' 2>&1)
check "sourcing loads functions without acting" 0 $? "$out" "SEAM_OK"

echo "== list_adapters against fixture sysfs =="
FIX=$(mktemp -d /tmp/pbt-usb-fixture.XXXXXX)   # path contains "usb" -> bus detection
mkdir -p "$FIX/hci0"
echo "AA:BB:CC:DD:EE:FF" > "$FIX/hci0/address"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; PBT_SYS_BT='$FIX' list_adapters" 2>&1)
check "finds adapter with MAC and bus" 0 $? "$out" "0 AA:BB:CC:DD:EE:FF USB"

rm "$FIX/hci0/address"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; PBT_SYS_BT='$FIX' list_adapters" 2>&1)
check "missing address reported as unavailable" 0 $? "$out" "address unavailable"

EMPTY=$(mktemp -d)
bash -c "PBT_SOURCED=1 source ./install.sh; PBT_SYS_BT='$EMPTY' list_adapters" >/dev/null 2>&1
check "no adapters -> nonzero return" 1 $?  ""
rm -rf "$FIX" "$EMPTY"

echo "== wrapper behavior =="
WT=$(mktemp -d)
# Fake btproxy that reports a dead session then hangs forever - the wrapper
# must kill it and exit nonzero instead of sitting there.
cat > "$WT/btproxy" << 'EOF'
#!/bin/bash
echo "Listening on 127.0.0.1:9700"
echo "No controller available: Device or resource busy"
sleep 300
EOF
chmod +x "$WT/btproxy"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; BIN='$WT/btproxy' get_binary; timeout 10 '$WT/btproxy-run'" 2>&1)
rc=$?
[ $rc != 0 ] && [ $rc != 124 ] && grep -q "resource busy" <<< "$out" \
    && ok "wrapper exits fast on dead-session message" \
    || fail "wrapper did not self-terminate (rc=$rc)"

cat > "$WT/btproxy" << 'EOF'
#!/bin/bash
echo "normal output"
exit 0
EOF
bash -c "PBT_SOURCED=1 source ./install.sh; BIN='$WT/btproxy' get_binary; '$WT/btproxy-run'" >/dev/null 2>&1
check "wrapper exits nonzero when btproxy quits (restart semantics)" 1 $? ""
rm -rf "$WT"

if [ "$(id -u)" = 0 ]; then
    echo "== CLI validation (root) =="
    out=$(bash install.sh --adapter 2>&1);      check "--adapter without value dies" 1 $? "$out" "needs a number"
    out=$(bash install.sh not-an-ip 2>&1);      check "garbage arg rejected"         1 $? "$out" "Not an IP address"
    if systemd-detect-virt --quiet 2>/dev/null; then
        out=$(bash install.sh 2>&1);            check "auto mode on a VM refuses to act as host" 1 $? "$out" "looks like a VM"
    fi
    if [ ! -f /etc/systemd/system/btproxy-server.service ] && [ ! -f /etc/systemd/system/btproxy-client.service ]; then
        out=$(bash install.sh --pause 2>&1);    check "--pause with nothing installed dies" 1 $? "$out" "Nothing is shared"
        out=$(bash install.sh --resume 2>&1);   check "--resume with nothing installed dies" 1 $? "$out" "Nothing to resume"
        out=$(bash install.sh --status 2>&1);   check "--status with nothing installed dies" 1 $? "$out" "Nothing installed"
    else
        echo "  skip: pause/resume/status checks (a real bridge is installed here)"
    fi
else
    echo "== CLI validation skipped (needs root) =="
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" = 0 ]
