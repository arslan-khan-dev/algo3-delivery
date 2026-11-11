#!/usr/bin/env bash
# install.sh — install or update the algo3 deployer on this server.
#
#   sudo ./install.sh                    tools, sudoers, logrotate, directories
#   sudo ./install.sh --app <name>       also that app's registry files
#
# Idempotent: a file is only replaced when it differs, and the old one is kept
# as <file>.backup.<timestamp>. It never touches SSH keys, sshd, any *.env
# secret file, or an existing /etc/algo3/delivery.conf.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"
changed=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run with sudo"

put() {   # put <src> <dest> <mode> [validate-command…]
    local src="$1" dest="$2" mode="$3"; shift 3
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        say "unchanged  $dest"
        return 0
    fi
    if [[ $# -gt 0 ]]; then
        "$@" "$src" >/dev/null || die "Validation failed for $src; nothing installed"
    fi
    if [[ -f "$dest" ]]; then
        cp -p "$dest" "$dest.backup.$stamp"
        say "backup     $dest.backup.$stamp"
    fi
    install -o root -g root -m "$mode" "$src" "$dest.new.$stamp"
    mv -f "$dest.new.$stamp" "$dest"
    say "installed  $dest"
    changed=$((changed + 1))
}

echo "Directories"
install -d -o root -g root -m 0755 /etc/algo3 /etc/algo3/apps /etc/algo3/caddy \
    /etc/algo3/caddy/sites /etc/algo3/caddy/check /usr/local/libexec
install -d -o root -g root -m 0700 /var/lib/algo3
install -d -o root -g adm -m 0750 /var/log/algo3
say "ok"

echo "Programs"
for f in "$here"/bin/*; do bash -n "$f" || die "Syntax error in $f"; done
put "$here/bin/algo3-deploy" /usr/local/libexec/algo3-deploy 0755
put "$here/bin/algo3-deploy-stack" /usr/local/libexec/algo3-deploy-stack 0755
put "$here/bin/algo3-deploy-wrapper" /usr/local/sbin/algo3-deploy-wrapper 0755
put "$here/bin/algo3-deploy-ssh" /usr/local/sbin/algo3-deploy-ssh 0755
put "$here/bin/algo3-cert-watch" /usr/local/sbin/algo3-cert-watch 0755
# algo3-deploy-stack (KIND=stack) copies releases with rsync; minimal images
# lack it (the lab did, 2026-11-11). A warning, not a refusal: apps don't need it.
command -v rsync >/dev/null || say "WARNING: rsync is not installed; KIND=stack deploys need it: sudo apt-get install -y rsync"

echo "sudoers"
put "$here/etc/sudoers.d/algo3-deploy" /etc/sudoers.d/algo3-deploy 0440 visudo -cf
visudo -c >/dev/null || die "visudo reports an error in the installed sudoers set"
say "visudo -c ok"

echo "logrotate"
put "$here/etc/logrotate.d/algo3" /etc/logrotate.d/algo3 0644

echo "Shared settings"
if [[ -f /etc/algo3/delivery.conf ]]; then
    say "kept       /etc/algo3/delivery.conf (never overwritten)"
else
    install -o root -g root -m 0644 "$here/etc/delivery.conf.example" /etc/algo3/delivery.conf
    say "created    /etc/algo3/delivery.conf"
    changed=$((changed + 1))
fi

if [[ "${1:-}" == "--app" ]]; then
    app="${2:-}"
    [[ "$app" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || die "Usage: install.sh --app <name>"
    [[ -d "$here/apps/$app" ]] || die "No registry files for $app in $here/apps"
    echo "Registry: $app"
    install -d -o root -g root -m 0755 "/etc/algo3/apps/$app"
    shopt -s nullglob
    for f in "$here/apps/$app"/*.conf "$here/apps/$app"/*.caddy.tmpl; do
        put "$f" "/etc/algo3/apps/$app/$(basename "$f")" 0644
    done
    # A template removed from the repo must not linger here: it would override
    # the site generated from the domain settings.
    for f in "/etc/algo3/apps/$app"/*.caddy.tmpl; do
        [[ -f "$here/apps/$app/$(basename "$f")" ]] && continue
        mv -f "$f" "$f.backup.$stamp"
        say "retired    $f (no longer in the repo; kept as $f.backup.$stamp)"
        changed=$((changed + 1))
    done
    shopt -u nullglob
    for conf in "$here/apps/$app"/*.conf; do
        envname="$(basename "$conf" .conf)"
        secrets="/etc/algo3/apps/$app/$envname.env"
        if [[ -f "$secrets" ]]; then
            chmod 0600 "$secrets"; chown root:root "$secrets"
            say "secrets    $secrets present (0600, not modified)"
        else
            say "secrets    $secrets absent (create it only if the app needs runtime secrets)"
        fi
    done
    echo "Certificate monitoring"
    /usr/local/sbin/algo3-cert-watch | sed 's/^/  /'
fi

echo
echo "Done: $changed file(s) changed."
echo "Not touched by design: SSH keys and sshd, *.env secrets, Docker, the edge."
echo "(The one exception: Netdata is restarted when the list of domains to watch changes.)"
