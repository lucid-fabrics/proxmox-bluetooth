#!/usr/bin/env bash
# Test suite for proxmox-bluetooth. Plain bash, no framework.
# Run from the repo root:  bash tests/run-tests.sh
# CLI tests (arg validation) only run as root - CI runs the whole thing with sudo.
set -u

cd "$(dirname "$0")/.." || exit 1
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

embedded=$(grep -oE '^BTPROXY_SHA256=[0-9a-f]{64}' install.sh | cut -d= -f2)
[ -n "$embedded" ] && [ "$embedded" = "$want" ] \
    && ok "BTPROXY_SHA256 pinned in install.sh matches the committed binary" \
    || fail "BTPROXY_SHA256 in install.sh ($embedded) != binary hash ($want) - update it"

echo "== self() prints a runnable command =="
# Under `curl ... | sudo bash` there is no script on disk and $0 is "bash", so a hint like
# "$0 --resume" would hand the user a command that cannot run.
out=$(bash -c 'PBT_SOURCED=1 source ./install.sh; self' 2>&1)
case "$out" in
    *"install.sh"*) ok "self() returns an invocable command ($out)" ;;
    *)              fail "self() returned something unusable: $out" ;;
esac

echo "== test seam =="
out=$(bash -c 'PBT_SOURCED=1 source ./install.sh && declare -F list_adapters get_binary pause resume probe_host report lxc_share lxc_remove container_mapped_uid lxc_conf_has_share lxc_conf_add_share lxc_conf_remove_share lxc_sharing_uids lxc_restart_sharing_containers write_proxy_unit >/dev/null && echo SEAM_OK' 2>&1)
check "sourcing loads functions without acting" 0 $? "$out" "SEAM_OK"

echo "== LXC conf mount-line helpers =="
FIXCONF=$(mktemp)
printf 'arch: amd64\nhostname: test\nunprivileged: 1\n' > "$FIXCONF"

bash -c "PBT_SOURCED=1 source ./install.sh; lxc_conf_has_share '$FIXCONF'"
[ $? = 1 ] && ok "fresh conf has no share" || fail "fresh conf incorrectly reports a share"

bash -c "PBT_SOURCED=1 source ./install.sh; lxc_conf_add_share '$FIXCONF'"
grep -qF "lxc.mount.entry: /run/pbt mnt/pbt none bind,ro,create=dir 0 0" "$FIXCONF" \
    && ok "lxc_conf_add_share appends the mount line" || fail "mount line missing after add"

before=$(wc -l < "$FIXCONF")
bash -c "PBT_SOURCED=1 source ./install.sh; lxc_conf_add_share '$FIXCONF'"
after=$(wc -l < "$FIXCONF")
[ "$before" = "$after" ] && ok "lxc_conf_add_share is idempotent (no duplicate line)" \
    || fail "add_share duplicated the line ($before -> $after lines)"

bash -c "PBT_SOURCED=1 source ./install.sh; lxc_conf_has_share '$FIXCONF'"
[ $? = 0 ] && ok "conf with mount line reports a share" || fail "has_share false negative after add"

bash -c "PBT_SOURCED=1 source ./install.sh; lxc_conf_remove_share '$FIXCONF'"
grep -q "unprivileged: 1" "$FIXCONF" && ok "remove_share preserves unrelated lines" || fail "remove_share clobbered unrelated content"
grep -qF "lxc.mount.entry: /run/pbt" "$FIXCONF" && fail "remove_share left the mount line behind" || ok "remove_share strips the mount line"

bash -c "PBT_SOURCED=1 source ./install.sh; lxc_conf_remove_share '$FIXCONF'"
[ $? = 1 ] && ok "remove_share on an already-clean conf returns failure (nothing to remove)" \
    || fail "remove_share should fail when there is nothing to remove"
rm -f "$FIXCONF"

echo "== container_mapped_uid =="
FIXCONF2=$(mktemp)
printf 'unprivileged: 0\n' > "$FIXCONF2"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; container_mapped_uid '$FIXCONF2'")
check "privileged container maps to host uid 0" 0 $? "$out" "^0$"

printf 'unprivileged: 1\nlxc.idmap: u 0 231072 65536\nlxc.idmap: g 0 231072 65536\n' > "$FIXCONF2"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; container_mapped_uid '$FIXCONF2'")
check "unprivileged container reads its own lxc.idmap base uid" 0 $? "$out" "^231072$"

printf 'unprivileged: 1\n' > "$FIXCONF2"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; container_mapped_uid '$FIXCONF2'")
check "unprivileged container without an idmap falls back to the default subuid base" 0 $? "$out" "^100000$"
rm -f "$FIXCONF2"

echo "== probe_host classifies connection failures =="
if command -v timeout >/dev/null; then
    out=$(bash -c 'PBT_SOURCED=1 source ./install.sh; probe_host 127.0.0.1 1' 2>&1)
    check "closed local port -> refused" 0 $? "$out" "refused"
    python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",19700)); s.listen(1); time.sleep(10)' &
    LPID=$!
    sleep 1
    out=$(bash -c 'PBT_SOURCED=1 source ./install.sh; probe_host 127.0.0.1 19700' 2>&1)
    check "open local port -> open" 0 $? "$out" "open"
    kill $LPID 2>/dev/null || true
    wait $LPID 2>/dev/null || true
else
    echo "  skip: no timeout binary on this machine"
fi

echo "== list_adapters against fixture sysfs =="
FIX=$(mktemp -d /tmp/pbt-usb-fixture.XXXXXX)   # path contains "usb" -> bus detection
mkdir -p "$FIX/hci0"
echo "AA:BB:CC:DD:EE:FF" > "$FIX/hci0/address"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; PBT_SYS_BT='$FIX' list_adapters" 2>&1)
check "finds adapter with MAC and bus" 0 $? "$out" "0 AA:BB:CC:DD:EE:FF USB"

rm "$FIX/hci0/address"
out=$(bash -c "PBT_SOURCED=1 source ./install.sh; PBT_SYS_BT='$FIX' list_adapters" 2>&1)
# The placeholder must stay a single token: callers parse this with
# `read -r idx mac bus`, and a multi-word value silently shifts the columns.
check "missing address still yields 3 parseable fields" 0 $? "$out" "0 - USB"

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

echo "== get_binary prefers a btproxy that is already installed =="
GB=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$GB/btproxy"
chmod +x "$GB/btproxy"
# BIN points at a path that does not exist, so get_binary has to acquire something.
# With a btproxy on PATH it must adopt that one rather than put our binary on the box.
# BIN is assigned, not passed as a `BIN=x get_binary` prefix: a prefix assignment is
# temp-scoped to the call, so get_binary repointing it would not be visible out here.
# install.sh itself sets BIN as a plain global before calling, which is what this mimics.
out=$(PATH="$GB:$PATH" bash -c "PBT_SOURCED=1 source ./install.sh; BIN='$GB/our-copy'; get_binary >/dev/null; echo \"BIN=\$BIN\"" 2>&1)
rc=$?
[ $rc = 0 ] && grep -q "BIN=$GB/btproxy" <<< "$out" && [ ! -e "$GB/our-copy" ] \
    && ok "adopts the PATH btproxy and installs no copy of its own" \
    || fail "get_binary did not adopt the PATH btproxy (rc=$rc, out=$out)"
rm -rf "$GB"

if [ "$(id -u)" = 0 ]; then
    echo "== CLI validation (root) =="
    out=$(bash install.sh --adapter 2>&1);      check "--adapter without value dies" 1 $? "$out" "needs a number"
    out=$(bash install.sh not-an-ip 2>&1);      check "garbage arg rejected"         1 $? "$out" "Not an IP address"
    out=$(bash install.sh --allow 2>&1);        check "--allow without value dies"   1 $? "$out" "needs an IP or CIDR"
    out=$(bash install.sh --allow 1.2.3 2>&1);  check "--allow rejects a partial IP" 1 $? "$out" "needs an IP or CIDR"
    out=$(bash install.sh --allow "1.2.3.4; rm -rf /" 2>&1)
    check "--allow rejects shell metacharacters" 1 $? "$out" "needs an IP or CIDR"
    # A rule matching every address is not a restriction; saying "Locked down" would be a lie.
    out=$(bash install.sh --allow 0.0.0.0/0 2>&1)
    check "--allow rejects an allow-everything CIDR" 1 $? "$out" "every address"
    # Without a digits-only check, this sets ADAPTER=--allow and the IP falls through to
    # the client path, turning a Proxmox host into a bridge client.
    out=$(bash install.sh --adapter --allow 1.2.3.4 2>&1)
    check "--adapter cannot swallow the next flag" 1 $? "$out" "needs a number"
    if systemd-detect-virt --quiet 2>/dev/null; then
        out=$(bash install.sh 2>&1);            check "auto mode on a VM refuses to act as host" 1 $? "$out" "looks like a VM"
    fi
    # --report must succeed on any machine, installed or not - it is the command
    # users are told to run precisely when everything else is broken.
    out=$(bash install.sh --report 2>&1);       check "--report always prints a bundle" 0 $? "$out" "proxmox-bluetooth report"
    out=$(bash install.sh --lxc 2>&1);          check "--lxc without ID dies"          1 $? "$out" "needs a container ID"
    out=$(bash install.sh --lxc abc 2>&1);      check "--lxc rejects non-numeric ID"   1 $? "$out" "needs a container ID"
    if ! command -v pct >/dev/null; then
        out=$(bash install.sh --lxc 105 2>&1);  check "--lxc off a Proxmox host dies cleanly" 1 $? "$out" "pct not found"
        out=$(bash install.sh --lxc-remove 105 2>&1); check "--lxc-remove off a Proxmox host dies cleanly" 1 $? "$out" "pct not found"
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
