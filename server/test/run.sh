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

# nexwe-website's sites are generated from its settings; the template tests
# give staging a custom template first.
custom_staging_template() {
    cat > /etc/algo3/apps/$APP/staging.caddy.tmpl <<'EOF'
staging.nexwe.app {
	encode zstd gzip
	reverse_proxy {{UPSTREAM}} {
		lb_try_duration 5s
		transport http {
			dial_timeout 300ms
		}
	}
}
EOF
}

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
custom_staging_template
deploy staging "$A"
sed -i 's/encode zstd gzip/encode gzip/' /etc/algo3/apps/$APP/staging.caddy.tmpl
ok deploy staging "$B"
ok eq "$(reloads)" 2
ok grep -q "encode gzip$" /etc/algo3/caddy/sites/$APP-staging.caddy
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"

reset "a template the edge rejects is refused; the old site and release stay"
custom_staging_template
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
custom_staging_template
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
custom_staging_template
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

reset "SSH shim: app= from the workflow, and keys shared by every app"
export STUB_WRAPPER="$W"
# An app-pinned key accepts app= only when it names that app.
ok bash -c "printf '%s\n' app=$APP $A | $SSH $APP staging" >/dev/null 2>&1
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok no bash -c "printf '%s\n' app=other-app $B | $SSH $APP staging" >/dev/null 2>&1
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
# A key for every app needs app=, and only reaches registered apps.
ok no bash -c "printf '%s\n' $B | $SSH --any-app staging" >/dev/null 2>&1
ok no bash -c "printf '%s\n' app=unknown-app $B | $SSH --any-app staging" >/dev/null 2>&1
ok no bash -c "printf '%s\n' app=../etc $B | $SSH --any-app staging" >/dev/null 2>&1
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok bash -c "printf '%s\n' app=$APP $B | $SSH --any-app staging" >/dev/null 2>&1
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"
# The environment is the key's: the staging key never touched production.
ok eq "$(n_containers production)" 0
ok no bash -c "printf '%s\n' app=$APP $B | $SSH --any-app ../production" >/dev/null 2>&1
# The shared production key promotes only what staging verified...
ok no bash -c "printf '%s\n' app=$APP $C $(digest "$C") | $SSH --any-app production" >/dev/null 2>&1
ok eq "$(n_containers production)" 0
ok bash -c "printf '%s\n' app=$APP $B $(digest "$B") | $SSH --any-app production" >/dev/null 2>&1
ok eq "$(routed nexwe.app)" "$P-${B:0:12}"
# ...and refuses outright an environment without PROMOTE_FROM.
mkdir -p /etc/algo3/apps/demo-direct
printf '%s\n' IMAGE=reg.example/demo-direct HOSTNAME=direct.example HEALTH_ATTEMPTS=3 > /etc/algo3/apps/demo-direct/production.conf
ok no bash -c "printf '%s\n' app=demo-direct $A $(digest "$A") | $SSH --any-app production" >"$STUB_DIR/out" 2>&1
ok has "$STUB_DIR/out" "does not set PROMOTE_FROM"
ok eq "$(n_containers production)" 1

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

# ── Any kind of app ──────────────────────────────────────────────────────────
register() {   # register <app> <env> <KEY=value>...
    mkdir -p "/etc/algo3/apps/$1"; printf '%s\n' "${@:3}" HEALTH_ATTEMPTS=3 > "/etc/algo3/apps/$1/$2.conf"
}
web_template() {   # web_template <app> <env> <hostname>
    printf '%s {\n\treverse_proxy {{UPSTREAM}} {\n\t\tlb_try_duration 5s\n\t\ttransport http {\n\t\t\tdial_timeout 300ms\n\t\t}\n\t}\n}\n' "$3" \
        > "/etc/algo3/apps/$1/$2.caddy.tmpl"
}
dep() { /usr/local/libexec/algo3-deploy deploy "$@" >"$STUB_DIR/out" 2>&1; }
holders() { python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
print("+".join(sorted(n for n, c in s["containers"].items() if c["status"] == "running" and sys.argv[2] in c.get("aliases", []))))
' "$STUB_DIR/state.json" "$1"; }
field() { python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["containers"].get(sys.argv[2],{}); print(json.dumps(c.get(sys.argv[3])))' "$STUB_DIR/state.json" "$1" "$2"; }

reset "a container not running the requested image is refused (any kind)"
deploy staging "$A"
export STUB_IMAGE_SWAP="$B"
ok no deploy staging "$B"
unset STUB_IMAGE_SWAP
ok has "$STUB_DIR/out" "is not running image"
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"

reset "web app without a release marker: identity from the image digest alone"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example RELEASE_PATH=
web_template demo-web staging demo.example
ok dep demo-web staging "$A"
ok dep demo-web staging "$B"
ok eq "$(holders demo-web-staging)" "demo-web-staging-${B:0:12}"
ok no grep -q "demo.example.*release.json" "$STUB_DIR/public-urls"

reset "internal service: stable alias, no edge site, no reload"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 HEALTH_PATH=/healthz
ok dep demo-api staging "$A"
ok dep demo-api staging "$B"
ok eq "$(holders demo-api-staging)" "demo-api-staging-${B:0:12}"
ok eq "$(status_of "demo-api-staging-${A:0:12}")" exited
ok test ! -e /etc/algo3/caddy/sites/demo-api-staging.caddy
ok eq "$(reloads)" 0

reset "worker: no alias; ready once it stays up; the old one stops after"
register demo-jobs staging KIND=worker IMAGE=reg.example/demo-jobs STARTUP_SECONDS=0
ok dep demo-jobs staging "$A"
ok dep demo-jobs staging "$B"
ok eq "$(status_of "demo-jobs-staging-${B:0:12}")" running
ok eq "$(status_of "demo-jobs-staging-${A:0:12}")" exited
ok eq "$(field "demo-jobs-staging-${B:0:12}" aliases)" "[]"
ok grep -q "demo-jobs-staging-${B:0:12} started while demo-jobs-staging-${A:0:12} ran" "$STUB_DIR/overlaps"

reset "worker that crash-loops is refused; the old one keeps working"
register demo-jobs staging KIND=worker IMAGE=reg.example/demo-jobs STARTUP_SECONDS=0
dep demo-jobs staging "$A"
export STUB_CRASHLOOP="$B"
ok no dep demo-jobs staging "$B"
unset STUB_CRASHLOOP
ok eq "$(status_of "demo-jobs-staging-${A:0:12}")" running
ok eq "$(status_of "demo-jobs-staging-${B:0:12}")" absent

reset "worker with a Docker HEALTHCHECK goes live when Docker says healthy"
export STUB_HAS_HEALTHCHECK=1
register demo-jobs staging KIND=worker IMAGE=reg.example/demo-jobs STARTUP_SECONDS=9999
ok dep demo-jobs staging "$A"
ok eq "$(status_of "demo-jobs-staging-${A:0:12}")" running

reset "OVERLAP=false: never two copies at once"
register demo-jobs staging KIND=worker IMAGE=reg.example/demo-jobs STARTUP_SECONDS=0 OVERLAP=false
dep demo-jobs staging "$A"; rm -f "$STUB_DIR/overlaps"
ok dep demo-jobs staging "$B"
ok eq "$(cat "$STUB_DIR/overlaps" 2>/dev/null)" ""
ok eq "$(status_of "demo-jobs-staging-${A:0:12}")" exited
ok eq "$(status_of "demo-jobs-staging-${B:0:12}")" running

reset "OVERLAP=false: a failed new release brings the old one back"
register demo-jobs staging KIND=worker IMAGE=reg.example/demo-jobs STARTUP_SECONDS=0 OVERLAP=false
dep demo-jobs staging "$A"
export STUB_CRASHLOOP="$B"
ok no dep demo-jobs staging "$B"
unset STUB_CRASHLOOP
ok eq "$(status_of "demo-jobs-staging-${A:0:12}")" running
ok has "$STUB_DIR/out" "serving again"

reset "worker rollback"
register demo-jobs staging KIND=worker IMAGE=reg.example/demo-jobs STARTUP_SECONDS=0
dep demo-jobs staging "$A"; dep demo-jobs staging "$B"
ok /usr/local/libexec/algo3-deploy rollback demo-jobs staging
ok eq "$(status_of "demo-jobs-staging-${A:0:12}")" running
ok eq "$(status_of "demo-jobs-staging-${B:0:12}")" exited

reset "release command: once, from the NEW image, quoted arguments intact"
# shellcheck disable=SC2016 # literal command line, parsed by the deployer
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 "RELEASE_COMMAND=sh -c 'npx prisma migrate deploy && echo done'"
ok dep demo-api staging "$A"
ok eq "$(wc -l < "$STUB_DIR/release-commands")" 1
ok python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); sys.exit(0 if r["argv"]==["sh","-c","npx prisma migrate deploy && echo done"] and r["image"]==sys.argv[2] else 1)' \
    "$STUB_DIR/release-commands" "reg.example/demo-api@$(digest "$A")"
ok eq "$(status_of "demo-api-staging-release-${A:0:12}")" absent

reset "a failing release command stops the deploy before the new release starts"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 RELEASE_COMMAND=migrate
dep demo-api staging "$A"
export STUB_RELEASE_EXIT=3
ok no dep demo-api staging "$B"
unset STUB_RELEASE_EXIT
ok has "$STUB_DIR/out" "Release command"
ok eq "$(status_of "demo-api-staging-${B:0:12}")" absent
ok eq "$(holders demo-api-staging)" "demo-api-staging-${A:0:12}"
ok eq "$(status_of "demo-api-staging-release-${B:0:12}")" absent

reset "a malformed release command is refused before anything is pulled, with the reason"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 RELEASE_COMMAND=migrate
dep demo-api staging "$A"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 "RELEASE_COMMAND=node -e \"process.exit(4)"
ok no dep demo-api staging "$B"
ok has "$STUB_DIR/out" "RELEASE_COMMAND cannot be parsed (No closing quotation)"
ok no grep -q "Pulling" "$STUB_DIR/out"
ok eq "$(holders demo-api-staging)" "demo-api-staging-${A:0:12}"

reset "a malformed release command never blocks a rollback"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 RELEASE_COMMAND=migrate
dep demo-api staging "$A"; dep demo-api staging "$B"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 "RELEASE_COMMAND=node -e \"process.exit(4)"
ok /usr/local/libexec/algo3-deploy rollback demo-api staging
ok eq "$(holders demo-api-staging)" "demo-api-staging-${A:0:12}"

reset "rollback never re-runs the release command"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 RELEASE_COMMAND=migrate
dep demo-api staging "$A"; dep demo-api staging "$B"
ok /usr/local/libexec/algo3-deploy rollback demo-api staging
ok eq "$(wc -l < "$STUB_DIR/release-commands")" 2

reset "volumes: the app's own named volumes reach the release and its release command"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 VOLUMES=demo-api-uploads:/data/uploads RELEASE_COMMAND=migrate
ok dep demo-api staging "$A"
ok eq "$(field "demo-api-staging-${A:0:12}" volumes)" '["demo-api-uploads:/data/uploads"]'
ok grep -q '"volumes": \["demo-api-uploads:/data/uploads"\]' "$STUB_DIR/release-commands"

reset "another app's volume, or any host path, is refused"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api VOLUMES=nexwe-website-data:/data
ok no dep demo-api staging "$A"
ok has "$STUB_DIR/out" "Invalid VOLUMES"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api VOLUMES=/etc:/host
ok no dep demo-api staging "$A"
ok has "$STUB_DIR/out" "Invalid VOLUMES"

reset "kind rules: unknown kind refused, web needs a hostname, internal needs no template"
register demo staging KIND=batch IMAGE=reg.example/demo
ok no dep demo staging "$A"
ok has "$STUB_DIR/out" "Invalid KIND"
register demo-web staging IMAGE=reg.example/demo-web
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "Invalid HOSTNAME"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api
ok dep demo-api staging "$A"

reset "an app on its own network is checked from that network"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api CONTAINER_PORT=3000 NETWORKS=demo-private,studio
ok dep demo-api staging "$A"
ok grep -q "^demo-private http://demo-api-staging-${A:0:12}:3000/" "$STUB_DIR/checker-calls"

# ── Domains ──────────────────────────────────────────────────────────────────
site() { cat "/etc/algo3/caddy/sites/$1.caddy"; }

reset "no template: the site is generated from the settings (nexwe staging: noindex)"
ok test ! -e /etc/algo3/apps/$APP/staging.caddy.tmpl
ok deploy staging "$A"
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok grep -q 'header X-Robots-Tag "noindex, nofollow, noarchive"' /etc/algo3/caddy/sites/$S.caddy
ok grep -q 'lb_try_duration 5s' /etc/algo3/caddy/sites/$S.caddy
ok grep -q 'dial_timeout 300ms' /etc/algo3/caddy/sites/$S.caddy

reset "aliases are served, redirects redirect, and both are checked"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example.org,demo.example.net REDIRECTS=www.demo.example RELEASE_PATH=
ok dep demo-web staging "$A"
ok eq "$(routed demo.example)" "demo-web-staging-${A:0:12}"
ok eq "$(routed demo.example.org)" "demo-web-staging-${A:0:12}"
ok eq "$(routed demo.example.net)" "demo-web-staging-${A:0:12}"
ok grep -q '^demo.example, demo.example.org, demo.example.net {$' /etc/algo3/caddy/sites/demo-web-staging.caddy
ok grep -q 'redir https://demo.example{uri} permanent' /etc/algo3/caddy/sites/demo-web-staging.caddy
ok has "$STUB_DIR/out" "https://demo.example.org (alias) answers"
ok has "$STUB_DIR/out" "https://www.demo.example redirects to https://demo.example/"
ok no grep -q 'X-Robots-Tag' /etc/algo3/caddy/sites/demo-web-staging.caddy

reset "different products on different domains live side by side"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example RELEASE_PATH=
ok deploy staging "$A"
ok dep demo-web staging "$B"
ok eq "$(routed staging.nexwe.app)" "$S-${A:0:12}"
ok eq "$(routed demo.example)" "demo-web-staging-${B:0:12}"
ok deploy staging "$C"
ok eq "$(routed demo.example)" "demo-web-staging-${B:0:12}"
ok eq "$(reloads)" 2   # one per app's first deploy; deploys themselves never reload

reset "a domain another app already claims is refused, before anything is pulled"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=staging.nexwe.app
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "staging.nexwe.app is already claimed by nexwe-website/staging"
ok no grep -q Pulling "$STUB_DIR/out"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example REDIRECTS=www.nexwe.app
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "www.nexwe.app is already claimed by nexwe-website/production"

reset "a domain the platform serves is refused"
mkdir -p /etc/algo3/caddy/platform
printf 'studio.example, api.studio.example {\n\treverse_proxy studio-api:3000\n}\n' > /etc/algo3/caddy/platform/studio.caddy
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=api.studio.example
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "api.studio.example is already served by the platform"

reset "with platform sites present, an app whose domains do NOT clash deploys"
# The case the lab found: a clean ownership check ended on a false `[[ ]] && die`
# and returned failure, so set -e stopped every deploy once the platform had sites.
mkdir -p /etc/algo3/caddy/platform
printf 'files.studio.example {\n\treverse_proxy seaweedfs:8333\n}\n\nmail.studio.example {\n\trespond 404\n}\n' > /etc/algo3/caddy/platform/studio-platform.caddy
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example.org RELEASE_PATH=
ok dep demo-web staging "$A"
ok eq "$(routed demo.example)" "demo-web-staging-${A:0:12}"
ok deploy staging "$B"
ok eq "$(routed staging.nexwe.app)" "$S-${B:0:12}"

reset "another app's mistake never blocks a rollback"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example RELEASE_PATH=
dep demo-web staging "$A"; dep demo-web staging "$B"
register demo-other staging IMAGE=reg.example/demo-other HOSTNAME=demo.example
ok /usr/local/libexec/algo3-deploy rollback demo-web staging
ok eq "$(routed demo.example)" "demo-web-staging-${A:0:12}"

reset "domain settings are validated"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "Domain declared more than once: demo.example"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example "ALIASES=bad domain.example"
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "Invalid ALIASES"
register demo-api staging KIND=internal IMAGE=reg.example/demo-api HOSTNAME=api.example
ok no dep demo-api staging "$A"
ok has "$STUB_DIR/out" "Only KIND=web has public domains"

reset "a custom template must serve exactly the declared domains"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example.org RELEASE_PATH=
web_template demo-web staging demo.example
ok no dep demo-web staging "$A"
ok has "$STUB_DIR/out" "serves \[demo.example\] but the settings declare \[demo.example demo.example.org\]"
web_template demo-web staging "{{HOSTNAME}}, demo.example.org"
ok dep demo-web staging "$A"
ok eq "$(routed demo.example.org)" "demo-web-staging-${A:0:12}"
ok grep -q '^demo.example, demo.example.org {$' /etc/algo3/caddy/sites/demo-web-staging.caddy

reset "an alias without a certificate yet warns, but does not roll back"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example.org REDIRECTS=www.demo.example RELEASE_PATH=
export STUB_DOMAIN_FAIL="demo.example.org www.demo.example"
ok dep demo-web staging "$A"
unset STUB_DOMAIN_FAIL
ok has "$STUB_DIR/out" "WARNING: https://demo.example.org (alias) does not answer"
ok has "$STUB_DIR/out" "WARNING: https://www.demo.example does not redirect"
ok eq "$(routed demo.example)" "demo-web-staging-${A:0:12}"
ok grep -q 'app=demo-web .*result=ok .*domain-warnings=2' /var/log/algo3/deploys.log

reset "DNS that does not point here is reported, and explains a failed public check"
sed -i 's/^SERVER_IPS=.*/SERVER_IPS=203.0.113.10,2001:db8::10/' /etc/algo3/delivery.conf
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example.org,new.example RELEASE_PATH=
export STUB_DNS="demo.example=203.0.113.10,2001:db8::10 demo.example.org=198.51.100.7"
ok dep demo-web staging "$A"
ok has "$STUB_DIR/out" "DNS: demo.example.org resolves to 198.51.100.7, which is not this server"
ok has "$STUB_DIR/out" "DNS: new.example does not resolve"
ok no grep -q "DNS: demo.example resolves" "$STUB_DIR/out"
export STUB_PUBLIC_FAIL=1
ok no dep demo-web staging "$B"
unset STUB_PUBLIC_FAIL STUB_DNS
ok has "$STUB_DIR/out" "does not serve release $B. DNS: demo.example.org resolves to 198.51.100.7"
ok eq "$(routed demo.example)" "demo-web-staging-${A:0:12}"

reset "status lists every domain and its DNS"
sed -i 's/^SERVER_IPS=.*/SERVER_IPS=203.0.113.10/' /etc/algo3/delivery.conf
export STUB_DNS="nexwe.app=203.0.113.10 www.nexwe.app=203.0.113.10"
ok /usr/local/libexec/algo3-deploy status "$APP" production >"$STUB_DIR/out" 2>&1
unset STUB_DNS
ok has "$STUB_DIR/out" "domain: nexwe.app (primary)"
ok has "$STUB_DIR/out" "domain: www.nexwe.app (redirects to nexwe.app)"
ok has "$STUB_DIR/out" "site: generated from the settings"
ok has "$STUB_DIR/out" "dns: every domain points at this server"

reset "the installer retires a template the repo no longer has"
custom_staging_template
bash "$SRC/install.sh" --app "$APP" >"$STUB_DIR/out" 2>&1
ok test ! -e /etc/algo3/apps/$APP/staging.caddy.tmpl
ok ls /etc/algo3/apps/$APP/staging.caddy.tmpl.backup.*
ok has "$STUB_DIR/out" "retired"

reset "certificate monitoring covers every domain of every web app, nothing else"
register demo-web staging IMAGE=reg.example/demo-web HOSTNAME=demo.example ALIASES=demo.example.org
register demo-api staging KIND=internal IMAGE=reg.example/demo-api
mkdir -p /tmp/netdata-go.d
ALGO3_X509_CONF=/tmp/netdata-go.d/x509check.conf /usr/local/sbin/algo3-cert-watch >"$STUB_DIR/out" 2>&1
ok eq "$(grep -c 'source:' /tmp/netdata-go.d/x509check.conf)" 5
ok grep -q 'source: https://www.nexwe.app:443' /tmp/netdata-go.d/x509check.conf
ok grep -q 'name: demo_example_org' /tmp/netdata-go.d/x509check.conf
ALGO3_X509_CONF=/tmp/netdata-go.d/x509check.conf /usr/local/sbin/algo3-cert-watch >"$STUB_DIR/out" 2>&1
ok has "$STUB_DIR/out" "unchanged"
rm -rf /tmp/netdata-go.d

reset "certificate monitoring on a fresh server (no apps registered yet) succeeds, empty"
# Phase 2 runs this before any app exists: "no domains" must not be an error.
rm -rf /etc/algo3/apps/*
mkdir -p /tmp/netdata-go.d
ok env ALGO3_X509_CONF=/tmp/netdata-go.d/x509check.conf /usr/local/sbin/algo3-cert-watch
ok grep -q '^jobs: \[\]$' /tmp/netdata-go.d/x509check.conf
rm -rf /tmp/netdata-go.d

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
