#!/usr/bin/env bash
# Tests for apps/nexwe/make-env.sh: which platform each environment's database
# and files address come from. Runs as root inside a THROWAWAY container:
#
#   docker run --rm -v "$PWD/server:/src:ro" node:22-slim bash /src/test/make-env.sh
#
# Each platform is a directory with a .env and a fake scripts/product-env.sh
# that prints what the real one prints: a DATABASE_URL naming the platform it
# ran on, and STORAGE_PUBLIC_ENDPOINT from that platform's STUDIO_FILES_HOST.
set -uo pipefail

SRC="${SRC:-/src}"
pass=0; failed=0
ok()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; }
expect() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# openssl: only `openssl rand -hex 32` is used.
mkdir -p /tmp/bin
printf '#!/bin/sh\nnode -e "process.stdout.write(require(\\"crypto\\").randomBytes(32).toString(\\"hex\\")+\\"\\\\n\\")"\n' > /tmp/bin/openssl
chmod +x /tmp/bin/openssl
export PATH="/tmp/bin:$PATH"

platform() {   # platform <dir> <label> [files host]
    mkdir -p "$1/scripts"
    {
        echo "STUDIO_DOMAIN=algo3.test"
        echo "GOTRUE_SMTP_USER=no-reply@algo3.test"
        echo "GOTRUE_SMTP_PASS=smtp-pass"
        [[ -n "${3:-}" ]] && echo "STUDIO_FILES_HOST=$3"
    } > "$1/.env"
    cat > "$1/scripts/product-env.sh" <<EOF
#!/usr/bin/env bash
host="\$(sed -n 's/^STUDIO_FILES_HOST=//p' "$1/.env")"
echo "DATABASE_URL=postgres://\${1//-/_}:pw@postgres:5432/\${1//-/_}?platform=$2"
echo "STORAGE_PUBLIC_ENDPOINT=https://\${host:-files.algo3.test}"
echo "STORAGE_BUCKET=\$1-files"
echo "STORAGE_ACCESS_KEY=key-\$1"
echo "STORAGE_SECRET_KEY=secret-\$1"
EOF
}

run_make_env() {   # run_make_env <apps dir> <production platform> <staging platform dir>
    mkdir -p "$1"
    echo '{"type":"service_account"}' > /tmp/firebase.json
    printf 'AC1\ntoken\nVA1\nreports@algo3.test\n' |
        NEXWE_APPS_DIR="$1" NEXWE_PLATFORM_DIR="$2" NEXWE_STAGING_PLATFORM_DIR="$3" \
        bash "$SRC/apps/nexwe/make-env.sh" /tmp/firebase.json >/tmp/out 2>&1
}
val() { sed -n "s/^$2=//p" "$1"; }

echo "Case 1: a staging platform exists — staging reads it"
rm -rf /tmp/c1; platform /tmp/c1/prod production; platform /tmp/c1/stg staging files-staging.algo3.test
if run_make_env /tmp/c1/apps /tmp/c1/prod /tmp/c1/stg; then ok "make-env.sh succeeds"; else bad "make-env.sh succeeds"; cat /tmp/out; fi
expect "staging S3_ENDPOINT is the staging platform's files address" "$(val /tmp/c1/apps/staging.env S3_ENDPOINT)" https://files-staging.algo3.test
expect "production S3_ENDPOINT stays files." "$(val /tmp/c1/apps/production.env S3_ENDPOINT)" https://files.algo3.test
expect "staging's database comes from the staging platform" "$(val /tmp/c1/apps/staging.env DATABASE_URL | sed 's/.*platform=//')" staging
expect "production's database comes from production's" "$(val /tmp/c1/apps/production.env DATABASE_URL | sed 's/.*platform=//')" production
expect "staging's bucket" "$(val /tmp/c1/apps/staging.env S3_BUCKET)" nexwe-staging-files

echo "Case 2: one platform for both (no staging platform installed)"
rm -rf /tmp/c2; platform /tmp/c2/prod production
if run_make_env /tmp/c2/apps /tmp/c2/prod /tmp/c2/none; then ok "make-env.sh succeeds"; else bad "make-env.sh succeeds"; cat /tmp/out; fi
expect "staging's database comes from the one platform" "$(val /tmp/c2/apps/staging.env DATABASE_URL | sed 's/.*platform=//')" production
expect "staging S3_ENDPOINT is that platform's files address" "$(val /tmp/c2/apps/staging.env S3_ENDPOINT)" https://files.algo3.test

echo "Case 3: an existing env file is never overwritten"
before="$(sha256sum /tmp/c1/apps/staging.env)"
if run_make_env /tmp/c1/apps /tmp/c1/prod /tmp/c1/stg; then bad "refuses"; else ok "refuses"; fi
expect "staging.env unchanged" "$(sha256sum /tmp/c1/apps/staging.env)" "$before"

printf '\nmake-env: %s passed, %s failed\n' "$pass" "$failed"
[[ $failed -eq 0 ]]
