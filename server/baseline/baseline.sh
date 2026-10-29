#!/usr/bin/env bash
# baseline.sh — server baseline, one component at a time:
#
#   sudo ./baseline.sh sysctl     kernel.panic=10, swappiness 10 (applied now)
#   sudo ./baseline.sh apt        security updates on, never auto-reboot
#   sudo ./baseline.sh docker     daemon.json: log limits + live-restore
#                                 (installed and validated; Docker is NOT
#                                 restarted, that is a separate, approved step)
#   sudo ./baseline.sh timers     heartbeat, pending-reboot check, weekly prune
#   sudo ./baseline.sh ops        /opt/algo3/ops (autoheal + Netdata), validated,
#                                 NOT started
#   sudo ./baseline.sh ssh        sshd drop-in, validated with sshd -t, NOT
#                                 reloaded; refuses unless key login is set up
#
# Idempotent: a file is replaced only when it differs; the old one is kept as
# <file>.backup.<timestamp>. Secrets (.env, monitoring.conf) are created from
# examples once and never overwritten.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ $# -ge 1 ]] || die "Usage: baseline.sh sysctl|apt|docker|timers|ops|ssh ..."

put() {   # put <src> <dest> <mode> [validate-command…]  → 0 changed, 1 unchanged
    local src="$1" dest="$2" mode="$3"; shift 3
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        say "unchanged  $dest"
        return 1
    fi
    if [[ $# -gt 0 ]]; then
        "$@" "$src" >/dev/null 2>&1 || { "$@" "$src" || true; die "Validation failed for $src; nothing installed"; }
    fi
    install -d -m 0755 "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        cp -p "$dest" "$dest.backup.$stamp"
        say "backup     $dest.backup.$stamp"
    fi
    install -o root -g root -m "$mode" "$src" "$dest.new.$stamp"
    mv -f "$dest.new.$stamp" "$dest"
    say "installed  $dest"
    return 0
}

once() {   # once <example> <dest> <mode>: create from example, never overwrite
    if [[ -f "$2" ]]; then
        chmod "$3" "$2"; chown root:root "$2"
        say "kept       $2 (never overwritten)"
    else
        install -o root -g root -m "$3" "$1" "$2"
        say "created    $2 (fill it in)"
    fi
}

validate_daemon_json() {
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" &&
    dockerd --validate --config-file "$1"
}

c_sysctl() {
    echo "sysctl"
    put "$here/etc/sysctl.d/90-algo3.conf" /etc/sysctl.d/90-algo3.conf 0644 || true
    sysctl --quiet --load /etc/sysctl.d/90-algo3.conf
    say "now: $(sysctl -n kernel.panic | sed 's/^/kernel.panic=/'), $(sysctl -n vm.swappiness | sed 's/^/vm.swappiness=/')"
}

c_apt() {
    echo "apt"
    put "$here/etc/apt/apt.conf.d/52algo3-unattended" /etc/apt/apt.conf.d/52algo3-unattended 0644 || true
    say "now: $(apt-config dump | grep -E '^Unattended-Upgrade::Automatic-Reboot ' || echo 'Automatic-Reboot not set')"
}

c_docker() {
    echo "docker"
    if put "$here/etc/docker/daemon.json" /etc/docker/daemon.json 0644 validate_daemon_json; then
        say "Docker has NOT been restarted. When approved, at a quiet time:"
        say "    sudo systemctl restart docker"
        say "then check: docker info --format '{{.LiveRestoreEnabled}}'   (expect: true)"
    fi
}

c_timers() {
    echo "timers"
    local f unit
    for f in "$here"/bin/*; do bash -n "$f" || die "Syntax error in $f"; done
    for f in "$here"/bin/*; do put "$f" "/usr/local/sbin/$(basename "$f")" 0755 || true; done
    for f in "$here"/systemd/*; do put "$f" "/etc/systemd/system/$(basename "$f")" 0644 || true; done
    install -d -o root -g root -m 0755 /etc/algo3
    once "$here/etc/algo3/monitoring.conf.example" /etc/algo3/monitoring.conf 0600
    systemd-analyze verify /etc/systemd/system/algo3-*.service /etc/systemd/system/algo3-*.timer
    systemctl daemon-reload
    for unit in algo3-heartbeat algo3-maintenance-check algo3-prune; do
        systemctl enable --now "$unit.timer" >/dev/null
        say "enabled    $unit.timer"
    done
    grep -qE '^BOX_CHECK_URL=.+' /etc/algo3/monitoring.conf ||
        say "NOTE: BOX_CHECK_URL is empty, so the heartbeat runs but pings nothing yet"
}

c_ops() {
    echo "ops"
    local dest=/opt/algo3/ops f
    install -d -o root -g root -m 0755 "$dest" "$dest/netdata" "$dest/netdata/health.d" "$dest/netdata/go.d"
    put "$here/ops/compose.yml" "$dest/compose.yml" 0644 || true
    while IFS= read -r f; do
        put "$here/ops/$f" "$dest/$f" 0644 || true
    done < <(cd "$here/ops" && find netdata -type f | sort)
    once "$here/ops/.env.example" "$dest/.env" 0600
    # Certificate checks are generated from the app registry (one per domain,
    # whatever product it belongs to), never copied from this repo.
    local x509="$dest/netdata/go.d/x509check.conf"
    [[ -f "$x509" ]] || { printf 'jobs: []\n' > "$x509"; chmod 0644 "$x509"; }
    if [[ -x /usr/local/sbin/algo3-cert-watch ]]; then
        /usr/local/sbin/algo3-cert-watch | sed 's/^/  /'
    else
        say "x509       no domains yet (install.sh --app <name> adds each app's)"
    fi
    docker compose -p algo3-ops -f "$dest/compose.yml" config --quiet || die "compose.yml does not validate"
    say "validated  $dest/compose.yml"
    grep -qE '^ALGO3_TELEGRAM_BOT_TOKEN=.+' "$dest/.env" ||
        say "NOTE: $dest/.env has no Telegram token yet"
    say "Not started. When ready:"
    say "    sudo docker compose -p algo3-ops -f $dest/compose.yml up -d"
}

c_ssh() {
    echo "ssh"
    local admin="${SUDO_USER:-}" keys
    [[ -n "$admin" && "$admin" != root ]] || die "Run as your admin user through sudo, not as root"
    keys="$(getent passwd "$admin" | cut -d: -f6)/.ssh/authorized_keys"
    [[ -s "$keys" ]] || die "$keys is empty: set up and PROVE key login for $admin before turning passwords off"
    local dest=/etc/ssh/sshd_config.d/10-algo3.conf backup=""
    [[ -f "$dest" ]] && backup="$dest.backup.$stamp"
    if put "$here/etc/ssh/sshd_config.d/10-algo3.conf" "$dest" 0644; then
        if ! sshd -t; then
            say "sshd -t FAILED; restoring the previous state"
            if [[ -n "$backup" ]]; then mv -f "$backup" "$dest"; else rm -f "$dest"; fi
            die "SSH configuration rejected; nothing changed"
        fi
        say "sshd -t ok. Effective settings:"
        sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|maxauthtries|allowusers) ' | sed 's/^/    /'
        say "NOT reloaded. Keep this session open, then:"
        say "    sudo systemctl reload ssh"
        say "and prove a NEW key-only login works before closing this one."
    fi
}

for component in "$@"; do
    case "$component" in
        sysctl|apt|docker|timers|ops|ssh) "c_$component" ;;
        *) die "Unknown component: $component" ;;
    esac
done
