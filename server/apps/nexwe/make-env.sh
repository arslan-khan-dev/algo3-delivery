#!/usr/bin/env bash
# Writes nexwe's runtime secrets: /etc/algo3/apps/nexwe/{staging,production}.env
#
#   sudo bash /opt/algo3/delivery/server/apps/nexwe/make-env.sh FIREBASE.json PLAY.json
#
# Run once, after studio-platform's `add-product.sh nexwe …` and `nexwe-staging …`.
# Everything is generated or read from where it already lives, except the
# outside services, which it asks for (hidden) or takes as files:
#
#   from studio-platform    database URL (a NEW password, via product-env.sh),
#                           the S3 bucket and keys, the mail account
#   generated               JWT_SECRET per environment, the TURN secret (shared
#                           with coturn, kept in /etc/algo3/apps/nexwe/turn-secret)
#   asked                   Twilio, Google Play's package, RTDN token and product id
#   files                   the Firebase and Google Play service-account JSON
#
# Both environments get the same outside services for now; only the database,
# bucket, JWT secret and public address differ. It refuses to overwrite an env
# file: the database password it sets would break a running nexwe.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

APPS="${NEXWE_APPS_DIR:-/etc/algo3/apps/nexwe}"
PLATFORM="${NEXWE_PLATFORM_DIR:-/opt/studio-platform}"

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ $# -eq 2 ]] || die "usage: make-env.sh FIREBASE_SERVICE_ACCOUNT.json GOOGLE_PLAY_SERVICE_ACCOUNT.json"
firebase_file="$1"; play_file="$2"
for f in "$firebase_file" "$play_file"; do [[ -s "$f" ]] || die "$f is missing or empty"; done
for e in staging production; do
    [[ -e "$APPS/$e.env" ]] && die "$APPS/$e.env exists: nothing changed (move it aside deliberately to rebuild)"
done
[[ -d "$APPS" ]] || die "$APPS missing: run install.sh --app nexwe first"

# One line of JSON: an env file takes the rest of the line literally, so the
# service account must not contain a newline (its private key keeps "\n" escaped).
oneline() { node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))))' "$1" ||
    die "$1 is not valid JSON"; }
firebase="$(oneline "$firebase_file")"
play="$(oneline "$play_file")"

read -rp  "Twilio Account SID: " twilio_sid
read -rsp "Twilio Auth Token (hidden): " twilio_token; echo
read -rp  "Twilio phone number (+…): " twilio_phone
read -rp  "Google Play package name: " play_package
read -rsp "Google Play RTDN token (hidden): " play_rtdn; echo
read -rp  "FutureLock Plus product id: " futurelock
for v in twilio_sid twilio_token twilio_phone play_package play_rtdn futurelock; do
    [[ -n "${!v}" ]] || die "$v is empty"
done

penv() { grep -E "^$1=" "$PLATFORM/.env" | tail -1 | cut -d= -f2- || true; }
smtp_user="$(penv GOTRUE_SMTP_USER)"; smtp_pass="$(penv GOTRUE_SMTP_PASS)"; domain="$(penv STUDIO_DOMAIN)"
[[ -n "$smtp_user" && -n "$smtp_pass" && -n "$domain" ]] || die "the platform's .env has no mail account or domain"

umask 077
if [[ ! -s "$APPS/turn-secret" ]]; then
    openssl rand -hex 32 > "$APPS/turn-secret"
fi
turn_secret="$(cat "$APPS/turn-secret")"

for e in staging production; do
    product=nexwe; origin=https://api.nexwe.app
    [[ $e == staging ]] && product=nexwe-staging && origin=https://staging-api.nexwe.app
    block="$(bash "$PLATFORM/scripts/product-env.sh" "$product" --rotate-db-password)"
    get() { sed -n "s/^$1=//p" <<<"$block"; }
    [[ "$(get DATABASE_URL)" == postgres://* ]] || die "no database URL for $product"
    cat > "$APPS/$e.env" <<EOF
NODE_ENV=production
DATABASE_URL=$(get DATABASE_URL)
JWT_SECRET=$(openssl rand -hex 32)
PUBLIC_API_URL=$origin
CORS_ORIGIN=*
S3_ENDPOINT=https://files.$domain
S3_REGION=us-east-1
S3_BUCKET=$(get STORAGE_BUCKET)
S3_ACCESS_KEY_ID=$(get STORAGE_ACCESS_KEY)
S3_SECRET_ACCESS_KEY=$(get STORAGE_SECRET_KEY)
S3_FORCE_PATH_STYLE=true
TRANSLATE_URL=
SMTP_HOST=mail.$domain
SMTP_PORT=465
SMTP_USER=$smtp_user
SMTP_PASSWORD=$smtp_pass
SMTP_FROM=$smtp_user
TURN_URLS=turn:turn.nexwe.app:3478,turn:turn.nexwe.app:3478?transport=tcp
TURN_SECRET=$turn_secret
TWILIO_ACCOUNT_SID=$twilio_sid
TWILIO_AUTH_TOKEN=$twilio_token
TWILIO_PHONE_NUMBER=$twilio_phone
FIREBASE_SERVICE_ACCOUNT=$firebase
GOOGLE_PLAY_PACKAGE_NAME=$play_package
GOOGLE_PLAY_SERVICE_ACCOUNT=$play
GOOGLE_PLAY_RTDN_TOKEN=$play_rtdn
FUTURELOCK_PLUS_PRODUCT_ID=$futurelock
EOF
    chmod 600 "$APPS/$e.env"
    echo "✓ $APPS/$e.env ($(grep -c = "$APPS/$e.env") settings)"
done
echo "✓ $APPS/turn-secret (coturn uses the same value)"
