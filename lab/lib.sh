# lab/lib.sh — shared by the rehearse-phase*.sh scripts (sourced, not run).
# shellcheck shell=bash
# shellcheck disable=SC2016 # commands are single-quoted on purpose: they run INSIDE the lab

export MSYS_NO_PATHCONV=1
pass=0; failed=0
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

as_algo3() { docker exec -u algo3 -w /home/algo3 algo3-lab bash -lc "$1"; }
as_root()  { docker exec algo3-lab bash -lc "$1"; }
title()    { printf '\n\033[1m════ %s\033[0m\n' "$*"; }
run()      { printf '\033[2m$ %s\033[0m\n' "$1"; as_algo3 "$1"; }
check() {   # check <description> <command run as root in the lab>
    if as_root "$2" >/dev/null 2>&1; then pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"
    else failed=$((failed + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; fi
}
note()     { printf '  %s\n' "$*"; }
finish() {
    printf '\n\033[1mRehearsal: %s passed, %s failed\033[0m\n' "$pass" "$failed"
    [[ $failed -eq 0 ]]
}

# ── Inner probe: from inside the lab, through loopback ───────────────────────
probe_start() {
    as_root '[ -f /tmp/probe.pid ] && kill "$(cat /tmp/probe.pid)" 2>/dev/null; rm -f /tmp/probe.log /tmp/probe.pid; install -m 0755 /lab/algo3-delivery/lab/files/lab-probe /usr/local/bin/lab-probe' >/dev/null 2>&1
    docker exec -d algo3-lab bash -c 'exec /usr/local/bin/lab-probe > /tmp/probe.log 2>&1'
    sleep 0.5
}
probe_stop() {   # prints: requests failures longest-outage-seconds
    as_root 'kill "$(cat /tmp/probe.pid)"; sleep 0.2; cat /tmp/probe.log' | probe_stats
}

# ── External probe: a separate container reaching the lab's own IP ───────────
# The path real visitors take (network → port 443 → whatever owns it), not
# loopback, so it is what Phase 3+ measures. It checks the certificate against
# the lab's CA and sends the real hostname (SNI + Host).
xprobe_start() {   # xprobe_start <hostname> [probe-name]
    local host="${1:-nexwe.app}" name="${2:-lab-xprobe}" ip
    ip="$(docker inspect -f '{{.NetworkSettings.IPAddress}}' algo3-lab)"
    docker rm -f "$name" >/dev/null 2>&1 || true
    # Docker on Windows needs a Windows path, both to copy into and to mount.
    local work; work="$(cygpath -w "$LAB_DIR/.work" 2>/dev/null || echo "$LAB_DIR/.work")"
    mkdir -p "$LAB_DIR/.work"; rm -rf "$LAB_DIR/.work/lab-ca.crt"
    docker cp algo3-lab:/usr/local/share/ca-certificates/lab-caddy-host.crt "$work/lab-ca.crt" >/dev/null
    [[ -f "$LAB_DIR/.work/lab-ca.crt" ]] || { echo "xprobe: could not fetch the lab CA" >&2; return 1; }
    docker run -d --name "$name" -e "IP=$ip" -e "HOST=$host" \
        -v "$work/lab-ca.crt:/ca.crt:ro" \
        python:3.12-slim python -u -c '
import os, socket, ssl, time
ip, host = os.environ["IP"], os.environ["HOST"]
ctx = ssl.create_default_context(cafile="/ca.crt")
while True:
    code = "000"
    try:
        with socket.create_connection((ip, 443), timeout=1) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                s.settimeout(1)
                s.sendall(f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                code = s.recv(64).split(b" ")[1].decode()
    except Exception:
        pass
    print(f"{time.time():.3f} {code}")
    time.sleep(0.1)
' >/dev/null
    sleep 1
}
xprobe_stop() {   # xprobe_stop [probe-name] → requests failures longest-outage-seconds
    docker logs "${1:-lab-xprobe}" 2>/dev/null | probe_stats
    docker rm -f "${1:-lab-xprobe}" >/dev/null 2>&1 || true
}

probe_stats() {   # stdin "<epoch> <code>" lines → "requests failures longest-outage"
    python -c '
import sys
rows = [l.split() for l in sys.stdin if len(l.split()) == 2]
bad = sum(1 for _, c in rows if c != "200")
longest, start, prev = 0.0, None, None
for t, c in rows:
    t = float(t)
    if c != "200":
        start = start if start is not None else (prev if prev is not None else t)
    elif start is not None:
        longest = max(longest, t - start); start = None
    prev = t
if start is not None and prev is not None:
    longest = max(longest, prev - start)
if len(rows) < 10:
    # A probe that measured nothing must FAIL every check, never pass one.
    print(f"{len(rows)} 999 999.0")
else:
    print(f"{len(rows)} {bad} {longest:.1f}")
'
}
