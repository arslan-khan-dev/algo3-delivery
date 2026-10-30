# Phase 4: automated deploys for nexwe-website

After Phase 3 (the edge serves nexwe.app). Rehearsed in the lab
(`lab/rehearse-phase4.sh`): the lab plays GitHub's runner over the same pinned
SSH keys.

**How a deploy switches traffic:** the edge points at a stable name per app and environment (`nexwe-website-staging`, `nexwe-website-production`). The deployer moves that name from the old release container to the new one, then stops the old one gracefully. **Caddy is not reloaded.**

| Measured in the lab | Requests failed |
| --- | --- |
| Staging deploy, as seen from production | 0 |
| Staging deploy, as seen from staging itself | 0 (a few requests ~0.3 s slower) |
| Production promotion | 0 |
| Rollback | 0 |
| Broken, unhealthy or missing image, as seen from staging | 0, and the deploy is refused |
| SSH killed mid-deploy | the deploy finishes anyway |

## 1 · GitHub (on your PC)

1. **Push `algo3-delivery`** to a **private** repo `arslan-khan-dev/algo3-delivery`. Then:

   ```bash
   git tag v1 && git push origin v1
   gh api -X PUT repos/arslan-khan-dev/algo3-delivery/actions/permissions/access -f access_level=user
   ```

2. **Create the deploy keys.** One key per environment, with no passphrase, because CI can't type one:

   ```bash
   ssh-keygen -t ed25519 -N "" -C ci-nexwe-website-staging    -f ~/ci-nexwe-website-staging
   ssh-keygen -t ed25519 -N "" -C ci-nexwe-website-production -f ~/ci-nexwe-website-production
   ssh-keyscan -t ed25519 <server-ip>      # compare with the fingerprint below, then keep the line
   ```

   The fingerprint must be `SHA256:F93NV3c19hWPTV6rrn7SlIHgfCigK4swyCu+arphfwg`. Check it with `ssh-keyscan -t ed25519 <ip> | ssh-keygen -lf -`.

3. **Repository secrets and variables.** GitHub Free offers no environments in
   private repositories, so everything is set at repository level, with the
   environment in the name. In `arslan-khan-dev/nexwe-website`, go to
   **Settings → Secrets and variables → Actions**:
   - **Secrets** tab: `DEPLOY_SSH_KEY_STAGING` (the whole **private** staging
     key file) and `DEPLOY_SSH_KEY_PRODUCTION` (the production one).
   - **Variables** tab: `VPS_HOST` (the server IP) and `VPS_KNOWN_HOSTS` (the
     keyscan line).

   What protects production without environments: the production key can only
   run `deploy nexwe-website production` (pinned on the server); the server
   refuses any release staging didn't run with the same digest
   (`PROMOTE_FROM=staging`); and the workflow's production job runs only for
   pushes to `main` and only promotes an image labelled `staging-ok-<sha>`.
   Any workflow in the repo could read the secrets, so give push access only
   to people you would trust with a deploy.

4. **Delete the private keys** from your PC once they're stored in GitHub.

## 2 · Server (as `algo3`)

Rehearsed in the lab from the server's real state (2026-10-30, 17/17),
including the full lock-down applied on top afterwards.

**1. Pin the keys.** This **replaces** the old unrestricted
`github-actions-algo3-deploy` key (kept only as a backup file):

```bash
sudo install -d -m 700 -o algo3-deploy -g algo3-deploy ~algo3-deploy/.ssh
sudo cp -p ~algo3-deploy/.ssh/authorized_keys ~algo3-deploy/.ssh/authorized_keys.backup.$(date +%Y%m%d) 2>/dev/null || true
sudo tee ~algo3-deploy/.ssh/authorized_keys >/dev/null <<'EOF'
restrict,command="/usr/local/sbin/algo3-deploy-ssh nexwe-website staging" ssh-ed25519 AAAA…staging-public-key… ci-nexwe-website-staging
restrict,command="/usr/local/sbin/algo3-deploy-ssh nexwe-website production" ssh-ed25519 AAAA…production-public-key… ci-nexwe-website-production
EOF
sudo chown algo3-deploy:algo3-deploy ~algo3-deploy/.ssh/authorized_keys && sudo chmod 600 ~algo3-deploy/.ssh/authorized_keys
```

The `install -d` line creates `.ssh` if it is missing (the lab found the
`tee` fails without it) and is harmless when it exists.

**2. Let `algo3-deploy` through SSH (`AllowUsers`)**, only now, with the old key
gone; allowing the account while it was still there would give that key a
shell. The full lock-down (Phase 2 step 7) also does this; on the real server
that lock-down is the last step, so a minimal drop-in does it for now and is
replaced (with a backup) by the lock-down later:

```bash
sudo passwd -S algo3-deploy          # must not say "P" (a usable password); if it does: sudo usermod -p '*' algo3-deploy
printf '%s\n' "# algo3: let the CI account in (its keys are pinned to a forced command)." \
  "# Passwords stay on until the full lock-down (baseline.sh ssh) replaces this file." \
  "AllowUsers zain algo3 algo3-deploy" | sudo tee /etc/ssh/sshd_config.d/10-algo3.conf >/dev/null
sudo sshd -t && sudo systemctl reload ssh
```

**Test from your PC.** The key must not run anything:

```bash
ssh -i ~/ci-nexwe-website-staging algo3-deploy@<server-ip> id </dev/null
```

Expect `ERROR: Missing commit SHA`, not a `uid=` line.

## 3 · nexwe-website (on your PC): the first automatic deploy

1. **Commit the prepared changes on `staging` and push.**
   - The changes: `deliver.yml`; the pinned Dockerfile with its health check; the removed `deploy.yml`, `.algo3.yml` and `scripts/deploy-nexwe`.
   - **Effect: staging deploys automatically.** Watch it under **Actions → Deliver**, and check that `https://staging.nexwe.app/release.json` shows the new sha.
2. **Failure drills on staging (optional, recommended).** Push a commit that breaks the site. The deploy must be refused and staging keeps serving.
3. **Merge `staging` → `main`.** **Production: ask first.** It deploys the image staging ran, byte for byte.

## Everyday use

- **Normal flow:** feature → PR → `staging` (deploys staging), then `staging` → `main` (deploys production).
- **Production refuses anything staging never ran,** both in CI (by git tree) and on the server (by sha and digest).
- **Emergency rollback:** on the server, `sudo /usr/local/libexec/algo3-deploy rollback nexwe-website production`. It takes seconds, and running it again returns to the newer release.
- **Status:** `sudo /usr/local/libexec/algo3-deploy status nexwe-website production`, and `tail /var/log/algo3/deploys.log`.
