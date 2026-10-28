#!/usr/bin/env bash
# Baseline tests, inside a throwaway Ubuntu container (it installs packages and
# writes to /etc):
#
#   docker run --rm -v "$PWD/server/baseline:/b:ro" ubuntu:24.04 bash /b/test/baseline-test.sh
#
# Validates each config file with the real tool that will read it on the
# server, and exercises the heartbeat and maintenance scripts against fake
# curl/df/systemctl.
set -uo pipefail
B="${B:-/b}"
pass=0; failed=0; current=""

ok() { if "$@"; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "FAIL [$current]: $*"; fi; }
eq() { [[ "$1" == "$2" ]] || { echo "      expected '$2', got '$1'"; return 1; }; }
no() { ! "$@"; }

export DEBIAN_FRONTEND=noninteractive
if ! { apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server systemd apt-utils python3 >/dev/null 2>&1; }; then
    echo "package install failed"; exit 1
fi

# ── sshd drop-in: valid, and it WINS over cloud-init's password setting ──────
current="sshd drop-in"
ssh-keygen -A >/dev/null 2>&1
mkdir -p /run/sshd /etc/ssh/sshd_config.d
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config ||
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
cp "$B/etc/ssh/sshd_config.d/10-algo3.conf" /etc/ssh/sshd_config.d/
for u in zain algo3 algo3-deploy; do id "$u" >/dev/null 2>&1 || useradd -m "$u"; done
ok sshd -t
T="$(sshd -T -C user=algo3,host=x,addr=1.2.3.4 2>/dev/null)"
ok eq "$(grep '^passwordauthentication ' <<<"$T")" "passwordauthentication no"
ok eq "$(grep '^kbdinteractiveauthentication ' <<<"$T")" "kbdinteractiveauthentication no"
ok eq "$(grep '^permitrootlogin ' <<<"$T")" "permitrootlogin no"
ok eq "$(grep '^maxauthtries ' <<<"$T")" "maxauthtries 3"
ok eq "$(grep -c '^allowusers ' <<<"$T")" "3"
ok grep -q '^allowusers algo3-deploy$' <<<"$T"

# ── apt policy: Automatic-Reboot false ───────────────────────────────────────
current="apt policy"
cp "$B/etc/apt/apt.conf.d/52algo3-unattended" /etc/apt/apt.conf.d/
ok eq "$(apt-config dump | grep '^Unattended-Upgrade::Automatic-Reboot ')" 'Unattended-Upgrade::Automatic-Reboot "false";'

# ── sysctl file: well-formed, and the two settings present ───────────────────
current="sysctl"
ok no grep -vE '^[[:space:]]*(#.*)?$|^[a-z0-9_.]+ = [0-9]+$' "$B/etc/sysctl.d/90-algo3.conf"
ok grep -qx 'kernel.panic = 10' "$B/etc/sysctl.d/90-algo3.conf"
ok grep -qx 'vm.swappiness = 10' "$B/etc/sysctl.d/90-algo3.conf"

# ── daemon.json: JSON, the three settings ────────────────────────────────────
current="daemon.json"
ok python3 - "$B/etc/docker/daemon.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["live-restore"] is True
assert d["log-driver"] == "json-file"
assert d["log-opts"] == {"max-size": "10m", "max-file": "5"}
PY

# ── systemd units verify against the real binaries ──────────────────────────
current="systemd units"
cp "$B"/bin/* /usr/local/sbin/ && chmod +x /usr/local/sbin/algo3-*
cp "$B"/systemd/* /etc/systemd/system/
chmod 0644 /etc/systemd/system/algo3-*            # what baseline.sh installs
# The server has Docker's unit; this container does not. A stand-in lets
# Requires=docker.service resolve exactly as it will there.
printf '[Unit]\nDescription=stand-in\n[Service]\nExecStart=/bin/true\n' > /etc/systemd/system/docker.service
ok systemd-analyze verify /etc/systemd/system/algo3-*.service /etc/systemd/system/algo3-*.timer

# ── prune can never delete a retained rollback ───────────────────────────────
current="prune"
ok no grep -qE 'container prune|system prune|rm -f|docker rm' <(grep -v '^#' "$B/bin/algo3-prune")
ok grep -q 'image prune' "$B/bin/algo3-prune"

# ── heartbeat and maintenance, against fake curl/df/systemctl ────────────────
FAKE=/tmp/fake; mkdir -p "$FAKE"
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" >> /tmp/pings
EOF
cat > "$FAKE/df" <<'EOF'
#!/usr/bin/env bash
printf ' Use%%\n %s%%\n' "${FAKE_DISK:-40}"
EOF
cat > "$FAKE/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_DOCKER:-active}" == active ]]
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" ALGO3_MONITORING_CONF=/tmp/monitoring.conf
mkdir -p /etc/algo3 && touch /etc/algo3/delivery.conf
HB=/usr/local/sbin/algo3-heartbeat MC=/usr/local/sbin/algo3-maintenance-check
U=https://hc-ping.com/11111111-2222-3333-4444-555555555555
pings() { cat /tmp/pings 2>/dev/null; }

current="heartbeat: not configured"
rm -f /tmp/pings; cp "$B/etc/algo3/monitoring.conf.example" /tmp/monitoring.conf
ok "$HB" >/dev/null
ok eq "$(pings)" ""

current="heartbeat: healthy"
rm -f /tmp/pings; printf 'BOX_CHECK_URL=%s\nDISK_FAIL_PERCENT=85\n' "$U" > /tmp/monitoring.conf
ok "$HB" >/dev/null
ok eq "$(pings)" "$U"

current="heartbeat: disk full"
rm -f /tmp/pings; FAKE_DISK=91 "$HB" >/dev/null
ok eq "$(pings)" "$U/fail"

current="heartbeat: docker down"
rm -f /tmp/pings; FAKE_DOCKER=inactive "$HB" >/dev/null
ok eq "$(pings)" "$U/fail"

current="heartbeat: delivery.conf missing"
rm -f /tmp/pings /etc/algo3/delivery.conf; "$HB" >/dev/null
ok eq "$(pings)" "$U/fail"
touch /etc/algo3/delivery.conf

current="heartbeat: a hostile URL is refused, not pinged"
rm -f /tmp/pings
# shellcheck disable=SC2016 # the literal $(id) is the attack being refused
printf 'BOX_CHECK_URL=https://x.y/$(id) z\n' > /tmp/monitoring.conf
ok no "$HB" >/dev/null 2>&1
ok eq "$(pings)" ""

current="maintenance: reboot pending"
rm -f /tmp/pings; printf 'MAINTENANCE_CHECK_URL=%s\n' "$U" > /tmp/monitoring.conf
printf '*** System restart required ***\n' > /tmp/rr; printf 'linux-image-6.x\n' > /tmp/rr.pkgs
ALGO3_REBOOT_FLAG=/tmp/rr "$MC" >/dev/null
ok eq "$(pings)" "$U/fail"

current="maintenance: nothing pending"
rm -f /tmp/pings /tmp/rr /tmp/rr.pkgs
ALGO3_REBOOT_FLAG=/tmp/rr "$MC" >/dev/null
ok eq "$(pings)" "$U"

current="installer syntax"
ok bash -n "$B/baseline.sh"

echo
echo "passed: $pass  failed: $failed"
[[ $failed -eq 0 ]]
