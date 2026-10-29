# algo3-delivery

Shared CI/CD for every algo3 product on the VPS: one reusable GitHub workflow
and one server-side blue/green deployer.

```
push staging ─► validate ─► build :<sha> (digest) ─► smoke test + scan ─► deploy staging
merge → main ─► promote: find the staging deploy with the same git tree
             ─► deploy production with staging's exact digest (never rebuilt)

server: ssh (key pinned to one app/env) ─► algo3-deploy-ssh ─► sudo algo3-deploy-wrapper
        ─► systemd unit (survives SSH loss) ─► algo3-deploy:
           pull by digest → start <app>-<env>-<sha12> → health + release marker via the edge
           → give it the stable alias <app>-<env> → stop the old release gracefully
           → public check → keep one rollback   (Caddy is NOT reloaded on a deploy)
```

- **Any app, any language.** Ship a Docker image and pick a kind: `web` (public), `internal` (HTTP for other containers), or `worker` (no HTTP). Migrations run automatically from the new image before it takes traffic (`RELEASE_COMMAND`). See `docs/app-contract.md`.
- **Any number of products and domains.** Each app declares its domains (primary, aliases, `www` redirects); one domain has exactly one owner, and every domain is checked and certificate-monitored.
- **Deploys are automatic.** Pushing or merging to `staging` deploys staging. Merging to `main` deploys production.
- **Production only ever runs what staging ran.** This is checked in CI (git tree), and again on the server (`PROMOTE_FROM=staging`, by sha and digest).
- **Anything that fails before the switch leaves the live release untouched.**
- **Anything that fails after the switch puts the route back.** If the previous release is itself broken, the deployer stops, flags `MANUAL-RECOVERY-NEEDED` and alerts.

| Path | What |
| --- | --- |
| `.github/workflows/deploy-app.yml` | The reusable workflow |
| `examples/deliver.yml` | What a product repo adds (about 15 lines) |
| `examples/deliver-multi-service.yml` | A repo with several services (API + web + worker), ordered |
| `templates/dockerfiles/` | Starter Dockerfiles: static, Node API, Next.js, Python, Go, worker. Each is tested by `templates/test-templates.sh` |
| `examples/apps/` | Tiny sample apps the template test builds |
| `docs/app-contract.md` | Rules a product meets before onboarding, plus the checklist |
| `server/bin/algo3-deploy` | The deployer (`deploy` / `rollback` / `status`) |
| `server/bin/algo3-deploy-wrapper` | The only command the deploy account may `sudo` |
| `server/bin/algo3-deploy-ssh` | Forced command on each CI key |
| `server/install.sh` | Idempotent installer (`--app <name>` for a registry entry) |
| `server/apps/<app>/` | Per-app registry: `<env>.conf` declares the image, kind and domains; the edge site is generated (an optional `<env>.caddy.tmpl` covers custom routing) |
| `server/bin/algo3-cert-watch` | Keeps Netdata's certificate checks equal to every registered domain |
| `server/test/run.sh` | The test suite. It fakes docker and curl and covers every failure path |
| `edge/` | `algo3-edge`, the single Caddy container on 80/443, its installer, and `CUTOVER.md` |
| `docs/rollout-nexwe-website.md` | Phase 4: GitHub settings, deploy keys, the first automatic deploys |
| `lab/` | A local stand-in for the VPS. Every server step is rehearsed there first. **Start with `lab/GUIDE.md`**: the step-by-step guide, from the first test to the server |
| `server/baseline/baseline.sh` | Server baseline, one component at a time: `sysctl`, `apt`, `docker`, `timers`, `ops`, `ssh` |
| `server/baseline/ops/` | autoheal (restarts unhealthy containers) + Netdata (alerts to Telegram), pinned by digest |
| `server/baseline/bin/` | Heartbeat to healthchecks.io (every 5 min), pending-reboot alert (daily), image prune (weekly; never containers) |
| `server/baseline/test/baseline-test.sh` | Validates every config with the real tool that reads it, and tests the alert scripts |

## Everyday operations (on the server, as `algo3`)

```bash
sudo /usr/local/libexec/algo3-deploy status   nexwe-website production   # what is live / retained
sudo /usr/local/libexec/algo3-deploy rollback nexwe-website production   # previous release, seconds
tail -n 20 /var/log/algo3/deploys.log                                     # every deploy and rollback
journalctl -u 'algo3-deploy-nexwe-website-*' --since today                # full output of a deploy
```

A normal rollback goes through git: revert the change on `staging`, then
merge it to `main`. The `rollback` command is the emergency path.

## Tests

```bash
docker run --rm -v "$PWD/server:/src:ro" python:3.12-slim \
  bash -c 'apt-get update -qq && apt-get install -y -qq sudo >/dev/null && bash /src/test/run.sh'
docker run --rm -v "$PWD/server:/mnt:ro" koalaman/shellcheck:v0.11.0 -x bin/* install.sh test/run.sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -no-color
```
