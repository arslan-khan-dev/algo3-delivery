#!/usr/bin/env bash
# Tests for algo3-deploy-stack (KIND=stack: studio-platform). Runs as root inside
# a THROWAWAY container, with docker and curl faked (test/stack-stubs/):
#
#   docker run --rm -v "$PWD/server:/src:ro" python:3.12-slim bash -c \
#     'apt-get update -qq && apt-get install -y -qq sudo rsync >/dev/null && bash /src/test/stack.sh'
#
# A "bundle" is a directory in the fake registry; `compose up` fails for a
# release listed in $STUB_DIR/broken. Each case asserts the end state on disk:
# which release's files are in the stack directory, what was kept, what was
# recorded.
set -uo pipefail

SRC="${SRC:-/src}"
export STUB_DIR=/tmp/stub PATH="/tmp/stubbin:$PATH"
APP=studio-platform
STG=/opt/studio-platform-staging
PRD=/opt/studio-platform
DEPLOY=/usr/local/libexec/algo3-deploy          # the entry point CI reaches (dispatches)
STACK=/usr/local/libexec/algo3-deploy-stack
pass=0; failed=0; current=""

sha() { printf 'stack-%s' "$1" | sha1sum | cut -c1-40; }
digest() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
A="$(sha A)"; B="$(sha B)"; C="$(sha C)"

bundle() {   # bundle <name>: a release in the fake registry
    local dir
    dir="$STUB_DIR/registry/$(sha "$1")"
    mkdir -p "$dir/scripts"
    printf '%s\n' "$1" > "$dir/VERSION"
    printf '# compose file of release %s\n' "$1" > "$dir/docker-compose.yml"
    printf '# the repo copy of identities.yml, release %s\n' "$1" > "$dir/identities.yml"
    # The fake post commands log which release ran them ($(cat VERSION) runs
    # later, inside them: single quotes on purpose).
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "harden-db $(cat VERSION)" >> %s/post.log\n' "$STUB_DIR" > "$dir/scripts/harden-db.sh"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "edge-sites $(cat VERSION)" >> %s/post.log\n' "$STUB_DIR" > "$dir/scripts/edge-sites.sh"
    # Release A has a file the later ones dropped: a deploy must delete it.
    [[ "$1" == A ]] && printf 'only in A\n' > "$dir/old-include.yml"
    digest "$1" > "$STUB_DIR/registry/$(sha "$1").digest"
}

install_by_hand() {   # install_by_hand <dir> <release>: what the operator does once
    mkdir -p "$1"
    cp -a "$STUB_DIR/registry/$(sha "$2")/." "$1/"
    printf 'POSTGRES_PASSWORD=secret-%s\n' "$1" > "$1/.env"
    printf '# this host GoTrue blocks\n' > "$1/identities.yml"
    mkdir -p "$1/scripts"; printf '{"identities":["host"]}\n' > "$1/scripts/s3-identities.json"
}

reset() {
    current="$1"
    rm -rf /etc/algo3 /var/lib/algo3 /var/log/algo3 /run/lock/algo3 "$STUB_DIR" /tmp/stubbin "$STG" "$PRD"
    mkdir -p "$STUB_DIR/registry" /tmp/stubbin
    cp "$SRC"/test/stack-stubs/* /tmp/stubbin/ && chmod +x /tmp/stubbin/*
    bash "$SRC/install.sh" --app "$APP" >/dev/null || { echo "install failed"; exit 1; }
    sed -i 's#^HEARTBEAT_URL=.*#HEARTBEAT_URL=https://hc.example/ping/deploys#' /etc/algo3/delivery.conf
    bundle A; bundle B; bundle C
    install_by_hand "$STG" A
}

run() { "$@" >"$STUB_DIR/out" 2>&1; }
deploy() { run "$DEPLOY" deploy "$APP" "$@"; }

ok() { if "$@"; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "FAIL [$current]: $*"; sed 's/^/      /' "$STUB_DIR/out" 2>/dev/null | tail -15; fi; }
eq() { [[ "$1" == "$2" ]] || { echo "      expected '$2', got '$1'"; return 1; }; }
has() { grep -q -- "$2" "$1"; }
no() { ! "$@"; }
version() { cat "$1/VERSION"; }
live() { cut -d' ' -f1 "/var/lib/algo3/$APP/$1.current" 2>/dev/null; }

# ── Adopting what is installed ───────────────────────────────────────────────
reset "deploy before adopt is refused"
ok no deploy staging "$B"
ok has "$STUB_DIR/out" "No adopted release"
ok eq "$(version "$STG")" A

reset "adopt refuses a commit that is not what is installed"
ok no run "$STACK" adopt "$APP" staging "$B"
ok has "$STUB_DIR/out" "differs from"
ok eq "$(live staging)" ""

reset "adopt records the installed commit, once"
ok run "$STACK" adopt "$APP" staging "$A"
ok eq "$(live staging)" "$A"
ok no run "$STACK" adopt "$APP" staging "$A"
ok has "$STUB_DIR/out" "only for the first time"
ok no test -f "$STUB_DIR/compose.log"   # adopt never restarts anything

# ── A deploy ─────────────────────────────────────────────────────────────────
reset "deploy through algo3-deploy (CI's entry point)"
run "$STACK" adopt "$APP" staging "$A"
ok deploy staging "$B"
ok eq "$(version "$STG")" B
ok eq "$(live staging)" "$B"
ok has "$STG/docker-compose.yml" "release B"
ok has "$STG/.env" "secret-$STG"                         # never shipped, never written
ok has "$STG/identities.yml" "this host GoTrue blocks"   # PRESERVE
ok has "$STG/scripts/s3-identities.json" '"host"'        # PRESERVE
ok no test -e "$STG/old-include.yml"                     # dropped by the release
ok has "$STUB_DIR/post.log" "harden-db B"
ok has "$STUB_DIR/post.log" "edge-sites B"
ok has "$STUB_DIR/compose.log" "up B"
ok has /var/lib/algo3/$APP/staging.history "$B $(digest B)"
ok has /var/log/algo3/deploys.log "action=deploy app=$APP env=staging result=ok release=$B"
ok has "$STUB_DIR/heartbeats" "hc.example/ping/deploys$"
ok eq "$(stat -c %U "$STG/docker-compose.yml")" root

reset "deploying the live release again only checks it"
run "$STACK" adopt "$APP" staging "$A"
deploy staging "$B"
: > "$STUB_DIR/post.log"
ok deploy staging "$B"
ok has /var/log/algo3/deploys.log "result=noop release=$B"
ok no has "$STUB_DIR/post.log" "harden-db"

reset "a digest that does not match the tag is refused"
run "$STACK" adopt "$APP" staging "$A"
ok no deploy staging "$B" "$(digest C)"
ok has "$STUB_DIR/out" "does not resolve to"
ok eq "$(version "$STG")" A

# ── Drift: hand edits on the server ──────────────────────────────────────────
reset "a hand edit on the server stops the deploy, and nothing changes"
run "$STACK" adopt "$APP" staging "$A"
printf 'NEXWE_AI_MODEL: added by hand\n' >> "$STG/docker-compose.yml"
ok no deploy staging "$B"
ok has "$STUB_DIR/out" "docker-compose.yml"
ok has "$STUB_DIR/out" "Commit them to the repo"
ok has "$STG/docker-compose.yml" "added by hand"
ok eq "$(version "$STG")" A
ok eq "$(live staging)" "$A"
ok no test -f "$STUB_DIR/compose.log"
ok has /var/log/algo3/deploys.log "result=failed"
ok has "$STUB_DIR/heartbeats" "/fail$"
run "$STACK" status "$APP" staging
ok has "$STUB_DIR/out" "drift: docker-compose.yml"

reset "a deleted released file is drift too"
run "$STACK" adopt "$APP" staging "$A"
rm "$STG/scripts/harden-db.sh"
ok no deploy staging "$B"
ok has "$STUB_DIR/out" "scripts/harden-db.sh"

# ── Failure after the switch: the previous release comes back ────────────────
reset "a release that does not come up healthy is replaced by the previous one"
run "$STACK" adopt "$APP" staging "$A"
deploy staging "$B"
echo C > "$STUB_DIR/broken"
: > "$STUB_DIR/post.log"
ok no deploy staging "$C"
ok eq "$(version "$STG")" B
ok eq "$(live staging)" "$B"
ok has "$STUB_DIR/compose.log" "up C"
ok eq "$(tail -1 "$STUB_DIR/compose.log")" "up B"       # the restore ran compose again
ok has "$STUB_DIR/post.log" "edge-sites B"              # and the post commands
ok has /var/log/algo3/deploys.log "result=rolled-back release=$C"
ok has "$STG/.env" "secret-$STG"
ok no has /var/lib/algo3/$APP/staging.history "$C"
ok has "$STUB_DIR/heartbeats" "/fail$"

# ── Rollback ─────────────────────────────────────────────────────────────────
reset "rollback returns to the previous release, and back again"
run "$STACK" adopt "$APP" staging "$A"
deploy staging "$B"
ok run "$DEPLOY" rollback "$APP" staging
ok eq "$(version "$STG")" A
ok eq "$(live staging)" "$A"
ok has "$STG/old-include.yml" "only in A"
ok run "$DEPLOY" rollback "$APP" staging
ok eq "$(version "$STG")" B

# ── Promotion to production ──────────────────────────────────────────────────
reset "production takes only what staging ran, by digest"
install_by_hand "$PRD" A
run "$STACK" adopt "$APP" staging "$A"
run "$STACK" adopt "$APP" production "$A"
ok no deploy production "$B" "$(digest B)"
ok has "$STUB_DIR/out" "never verified live on staging"
ok no deploy production "$B"
ok has "$STUB_DIR/out" "a digest is required"
ok eq "$(version "$PRD")" A
deploy staging "$B"
ok deploy production "$B" "$(digest B)"
ok eq "$(version "$PRD")" B
ok has "$PRD/.env" "secret-$PRD"
ok has "$STG/.env" "secret-$STG"

# ── Settings ─────────────────────────────────────────────────────────────────
reset "a STACK_DIR outside /opt is refused"
sed -i 's#^STACK_DIR=.*#STACK_DIR=/etc#' /etc/algo3/apps/$APP/staging.conf
ok no run "$STACK" status "$APP" staging
ok has "$STUB_DIR/out" "Invalid STACK_DIR"

reset "a post command outside scripts/ is refused"
sed -i 's#^POST_COMMANDS=.*#POST_COMMANDS=../../bin/sh#' /etc/algo3/apps/$APP/staging.conf
ok no run "$STACK" status "$APP" staging
ok has "$STUB_DIR/out" "Invalid POST_COMMANDS"

reset "an unknown setting is refused"
printf 'HOSTNAME=files.example\n' >> /etc/algo3/apps/$APP/staging.conf
ok no run "$STACK" status "$APP" staging
ok has "$STUB_DIR/out" "Unknown setting HOSTNAME"

echo
echo "stack: $pass passed, $failed failed"
[[ $failed -eq 0 ]]
