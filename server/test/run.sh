#!/usr/bin/env bash
# Deployer test suite. Runs as root inside a THROWAWAY container (it installs
# into /etc/algo3 and /usr/local), with docker/curl/systemd-run faked:
#
#   docker run --rm -v "$PWD/server:/src:ro" python:3.12-slim bash /src/test/run.sh
#
# Each case starts from a clean fake server, injects one failure, and asserts
# the end state: which release is routed, which containers exist, what was
# logged. A deploy that "fails safely" must leave the previous release serving.
set -uo pipefail

SRC="${SRC:-/src}"
export STUB_DIR=/tmp/stub STUB_SITES_DIR=/etc/algo3/caddy/sites ALGO3_RETRY_SECONDS=0
export PATH="/tmp/stubbin:$PATH"
APP=nexwe-website
pass=0; failed=0; current=""

sha() { printf 'release-%s' "$1" | sha1sum | cut -c1-40; }   # deterministic fake SHAs
digest() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
A="$(sha 1)"; B="$(sha 2)"; C="$(sha 3)"

reset() {
    current="$1"
    rm -rf /etc/algo3 /var/lib/algo3 /var/log/algo3 /run/lock/algo3 "$STUB_DIR" /tmp/stubbin
    unset "${!STUB_@}" 2>/dev/null || true
    export STUB_DIR=/tmp/stub STUB_SITES_DIR=/etc/algo3/caddy/sites ALGO3_RETRY_SECONDS=0
    mkdir -p "$STUB_DIR" /tmp/stubbin
    cp "$SRC"/test/stubs/* /tmp/stubbin/ && chmod +x /tmp/stubbin/*
    printf '{"containers": {"studio-caddy": {"id": "edge", "status": "running", "labels": {}, "created": "0", "restarts": 0}}}' \
        > "$STUB_DIR/state.json"
    bash "$SRC/install.sh" --app "$APP" >/dev/null || { echo "install failed"; exit 1; }
    sed -i 's#^HEARTBEAT_URL=.*#HEARTBEAT_URL=https://hc.example/ping/deploys#' /etc/algo3/delivery.conf
    sed -i 's/^HEALTH_ATTEMPTS=.*//' /etc/algo3/apps/$APP/*.conf
    printf 'HEALTH_ATTEMPTS=3\n' | tee -a /etc/algo3/apps/$APP/staging.conf >> /etc/algo3/apps/$APP/production.conf
}

deploy()   { /usr/local/libexec/algo3-deploy deploy "$APP" "$@" >"$STUB_DIR/out" 2>&1; }
rollback() { /usr/local/libexec/algo3-deploy rollback "$APP" "$1" >"$STUB_DIR/out" 2>&1; }

# The container(s) actually answering a hostname: the edge routes the host to an
# alias; Docker DNS answers the alias with every RUNNING container holding it.
routed()   { python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
alias = s.get("routes", {}).get(sys.argv[2], "")
print("+".join(sorted(n for n, c in s["containers"].items() if c["status"] == "running" and alias and alias in c.get("aliases", []))))
' "$STUB_DIR/state.json" "$1"; }
reloads()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("counters",{}).get("reload",0))' "$STUB_DIR/state.json"; }
status_of(){ python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["containers"].get(sys.argv[2]); print(c["status"] if c else "absent")' "$STUB_DIR/state.json" "$1"; }
n_containers(){ python3 -c 'import json,sys; print(sum(1 for c in json.load(open(sys.argv[1]))["containers"].values() if c["labels"].get("algo3.env")==sys.argv[2]))' "$STUB_DIR/state.json" "$1"; }

ok() { if "$@"; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "FAIL [$current]: $*"; sed 's/^/      /' "$STUB_DIR/out" 2>/dev/null | tail -15; fi; }
eq() { [[ "$1" == "$2" ]] || { echo "      expected '$2', got '$1'"; return 1; }; }
has() { grep -q -- "$2" "$1"; }
no()  { ! "$@"; }

S=nexwe-website-staging
P=nexwe-website-production

# ── Happy paths ──────────────────────────────────────────────────────────────
reset "first deploy"
ok deploy staging "$A"
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok has /var/lib/algo3/$APP/staging.history "$A $(digest "$A")"
ok has /var/log/algo3/deploys.log "action=deploy app=$APP env=staging result=ok"
ok eq "$(cat "$STUB_DIR/heartbeats")" "https://hc.example/ping/deploys"
ok eq "$(head -1 /etc/algo3/caddy/sites/$APP-staging.caddy)" "# algo3: app=$APP env=staging upstream=$S"
ok grep -q "reverse_proxy $S:80" /etc/algo3/caddy/sites/$APP-staging.caddy
ok eq "$(cat /var/lib/algo3/$APP/staging.live)" "$S-${A:0:12}"

reset "a normal deploy never reloads the edge (only the first one does)"
deploy staging "$A"
ok eq "$(reloads)" 1
ok deploy staging "$B"
ok deploy staging "$C"
ok eq "$(reloads)" 1
ok eq "$(routed staging.nexwe.app)" "$S-${C:0:12}"

reset "a release holds the alias only once it passed its checks"
deploy staging "$A"
export STUB_WRONG_MARKER="$B"
ok no deploy staging "$B"
unset STUB_WRONG_MARKER
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"

reset "a template change is validated, then reloaded exactly once"
deploy staging "$A"
sed -i 's/encode zstd gzip/encode gzip/' /etc/algo3/apps/$APP/staging.caddy.tmpl
ok deploy staging "$B"
ok eq "$(reloads)" 2
ok grep -q "encode gzip$" /etc/algo3/caddy/sites/$APP-staging.caddy
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"

reset "a template the edge rejects is refused; the old site and release stay"
deploy staging "$A"
cp /etc/algo3/caddy/sites/$APP-staging.caddy /tmp/site-before
sed -i 's/encode zstd gzip/encode gzip/' /etc/algo3/apps/$APP/staging.caddy.tmpl
export STUB_VALIDATE_FAIL=1
ok no deploy staging "$B"
unset STUB_VALIDATE_FAIL
ok cmp -s /tmp/site-before /etc/algo3/caddy/sites/$APP-staging.caddy
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok eq "$(status_of "$S-${B:0:12}")" absent

reset "an edge reload that fails on a template change is rolled back"
deploy staging "$A"
cp /etc/algo3/caddy/sites/$APP-staging.caddy /tmp/site-before
sed -i 's/encode zstd gzip/encode gzip/' /etc/algo3/apps/$APP/staging.caddy.tmpl
export STUB_RELOAD_FAIL=2   # reload 1 was the first deploy
ok no deploy staging "$B"
unset STUB_RELOAD_FAIL
ok cmp -s /tmp/site-before /etc/algo3/caddy/sites/$APP-staging.caddy
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok eq "$(status_of "$S-${B:0:12}")" absent

reset "a template without retry settings is refused"
sed -i '/lb_try_duration/d' /etc/algo3/apps/$APP/staging.caddy.tmpl
ok no deploy staging "$A"
ok has "$STUB_DIR/out" "must set lb_try_duration and dial_timeout"

reset "second deploy keeps one rollback, third removes the oldest"
deploy staging "$A"; ok deploy staging "$B"
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"
ok eq "$(status_of "$S-${A:0:12}")" exited
ok deploy staging "$C"
ok eq "$(routed staging.nexwe.app)" "$S-${C:0:12}"
ok eq "$(status_of "$S-${B:0:12}")" exited
ok eq "$(status_of "$S-${A:0:12}")" absent
ok eq "$(n_containers staging)" 2

reset "same release again is a no-op"
deploy staging "$A"; ok deploy staging "$A"
ok has "$STUB_DIR/out" "already live"
ok eq "$(n_containers staging)" 1

reset "redeploying the retained release reuses its container"
deploy staging "$A"; deploy staging "$B"; ok deploy staging "$A"
ok has "$STUB_DIR/out" "Reusing retained container"
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok eq "$(status_of "$S-${B:0:12}")" exited

reset "rollback and roll forward"
deploy staging "$A"; deploy staging "$B"
ok rollback staging
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok eq "$(status_of "$S-${B:0:12}")" exited
ok rollback staging
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"
ok has /var/log/algo3/deploys.log "action=rollback"

reset "a failed deploy never touches the retained rollback"
deploy staging "$A"; deploy staging "$B"
export STUB_WRONG_MARKER="$C"
ok no deploy staging "$C"
unset STUB_WRONG_MARKER
ok eq "$(status_of "$S-${A:0:12}")" exited
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"
ok rollback staging
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"

reset "a retained release takes no traffic until it passes its checks again"
deploy staging "$A"; deploy staging "$B"
export STUB_NEVER_READY="$A"
ok no deploy staging "$A"
unset STUB_NEVER_READY
ok eq "$(cat "$STUB_DIR/violations" 2>/dev/null)" ""
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"
ok eq "$(status_of "$S-${A:0:12}")" exited

reset "rollback with nothing retained is refused"
deploy staging "$A"
ok no rollback staging
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"

# ── Failures before the switch: live release untouched, candidate removed ─────
for case in PULL_FAIL EXIT_ON_START NEVER_READY UNHEALTHY WRONG_MARKER TAG_DIGEST; do
    reset "fails before switch: $case"
    deploy staging "$A"; rm -f "$STUB_DIR/heartbeats"
    case "$case" in
        PULL_FAIL) export "STUB_$case=1" ;;
        TAG_DIGEST) STUB_TAG_DIGEST="$(digest other)"; export STUB_TAG_DIGEST ;;
        *) export "STUB_$case=$B" ;;
    esac
    if [[ "$case" == TAG_DIGEST ]]; then ok no deploy staging "$B" "$(digest "$B")"; else ok no deploy staging "$B"; fi
    ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
    ok eq "$(status_of "$S-${A:0:12}")" running
    ok eq "$(status_of "$S-${B:0:12}")" absent
    ok has /var/log/algo3/deploys.log "result=failed"
    ok has /var/log/algo3/deploys.log "detail=recovered"
    ok eq "$(cat "$STUB_DIR/heartbeats")" "https://hc.example/ping/deploys/fail"
done

# ── Failures after the switch (alias moved, old release stopped): restored ───
for case in PUBLIC_FAIL PUBLIC_WRONG; do
    reset "fails after switch: $case"
    deploy staging "$A"
    export "STUB_$case=1"
    ok no deploy staging "$B"
    unset "STUB_$case"
    ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
    ok eq "$(status_of "$S-${A:0:12}")" running
    ok eq "$(status_of "$S-${B:0:12}")" absent
    ok has "$STUB_DIR/out" "serving again"
    ok eq "$(reloads)" 1
    ok eq "$(cat /var/lib/algo3/$APP/staging.live)" "$S-${A:0:12}"
done

reset "previous release is broken too: keep the new route, flag for a human"
deploy staging "$A"
export STUB_PUBLIC_FAIL=1 STUB_BROKEN_ON_RESTART="$A"
# Simulate the previous release having been stopped and failing on restart.
python3 - "$STUB_DIR/state.json" "$S-${A:0:12}" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["containers"][sys.argv[2]]["status"] = "exited"; json.dump(s, open(sys.argv[1], "w"))
PY
ok no deploy staging "$B"
ok eq "$(status_of "$S-${B:0:12}")" running
ok has /var/log/algo3/deploys.log "MANUAL-RECOVERY-NEEDED"
ok has "$STUB_DIR/out" "CRITICAL"

reset "first deploy failing after the switch removes the site"
export STUB_PUBLIC_FAIL=1
ok no deploy staging "$A"
ok eq "$(test -f /etc/algo3/caddy/sites/$APP-staging.caddy && echo present || echo absent)" absent
ok eq "$(status_of "$S-${A:0:12}")" absent

# ── Promotion gate ───────────────────────────────────────────────────────────
reset "production refuses what staging never ran"
ok no deploy production "$A" "$(digest "$A")"
ok has "$STUB_DIR/out" "never verified live on staging"
ok no deploy production "$A"
ok has "$STUB_DIR/out" "a digest is required"
deploy staging "$A"
ok deploy production "$A" "$(digest "$A")"
ok eq "$(routed nexwe.app)" "$P-${A:0:12}"
ok no deploy production "$B" "$(digest "$B")"
ok eq "$(routed nexwe.app)" "$P-${A:0:12}"

# ── Concurrency ──────────────────────────────────────────────────────────────
reset "a second deploy of the same app/env is refused while one runs"
deploy staging "$A"
mkdir -p /run/lock/algo3
flock /run/lock/algo3/$APP-staging.lock sleep 3 &
sleep 0.3
ok no deploy staging "$B"
ok has "$STUB_DIR/out" "Another deploy or rollback"
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
wait

# ── Input validation: deployer, wrapper, SSH shim ────────────────────────────
reset "input validation"
ok no /usr/local/libexec/algo3-deploy deploy "$APP" staging "ABC" >/dev/null 2>&1
ok no /usr/local/libexec/algo3-deploy deploy "$APP" staging "$A" "sha256:nothex" >/dev/null 2>&1
ok no /usr/local/libexec/algo3-deploy deploy "../etc" staging "$A" >/dev/null 2>&1
ok no /usr/local/libexec/algo3-deploy deploy unknown-app staging "$A" >/dev/null 2>&1
W=/usr/local/sbin/algo3-deploy-wrapper
ok no bash -c "printf '%s\n' $APP staging $A | $W extra-arg" >/dev/null 2>&1
ok no bash -c "printf '%s\n' $APP staging NOTASHA | $W" >/dev/null 2>&1
ok no bash -c "printf '%s\n' other-app staging $A | $W" >/dev/null 2>&1
ok no bash -c "printf '%s\n' $APP staging $A '' surplus | $W" >/dev/null 2>&1
ok bash -c "printf '%s\n' $APP staging $A | $W" >/dev/null 2>&1
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
export STUB_WRAPPER="$W"
SSH=/usr/local/sbin/algo3-deploy-ssh
ok no bash -c "printf '%s\n' $B | $SSH $APP" >/dev/null 2>&1
ok no bash -c "printf '%s\n' 'rm -rf /' | $SSH $APP staging" >/dev/null 2>&1
ok bash -c "SSH_ORIGINAL_COMMAND='bash -i' printf '%s\n' $B | $SSH $APP staging" >/dev/null 2>&1
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"

reset "public check uses 443 by default"
ok deploy staging "$A"
ok grep -q "^https://staging.nexwe.app:443/" "$STUB_DIR/public-urls"

reset "public check follows PUBLIC_CHECK_PORT (the dry-run edge)"
sed -i 's/^PUBLIC_CHECK_PORT=.*/PUBLIC_CHECK_PORT=18443/' /etc/algo3/delivery.conf
ok deploy staging "$A"
ok grep -q "^https://staging.nexwe.app:18443/release.json" "$STUB_DIR/public-urls"
ok no grep -q ":443/" "$STUB_DIR/public-urls"
sed -i 's/^PUBLIC_CHECK_PORT=.*/PUBLIC_CHECK_PORT=443x/' /etc/algo3/delivery.conf
ok no deploy staging "$B"
ok has "$STUB_DIR/out" "Invalid PUBLIC_CHECK_PORT"

reset "conf files are data, not code"
# shellcheck disable=SC2016 # the literal $(...) is the point: it must NOT run
printf 'IMAGE=$(touch /tmp/pwned)\n' >> /etc/algo3/apps/$APP/staging.conf
ok no deploy staging "$A"
ok eq "$(test -e /tmp/pwned && echo pwned || echo safe)" safe
printf 'EVIL=1\n' > /etc/algo3/apps/$APP/staging.conf
ok no deploy staging "$A"
ok has "$STUB_DIR/out" "Unknown setting EVIL"

echo
echo "passed: $pass  failed: $failed"
[[ $failed -eq 0 ]]
