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
           → caddy validate → switch the route → public check → keep one rollback
```

- **Deploys are automatic.** Pushing or merging to `staging` deploys staging. Merging to `main` deploys production.
- **Production only ever runs what staging ran.** This is checked in CI (git tree), and again on the server (`PROMOTE_FROM=staging`, by sha and digest).
- **Anything that fails before the switch leaves the live release untouched.**
- **Anything that fails after the switch puts the route back.** If the previous release is itself broken, the deployer stops, flags `MANUAL-RECOVERY-NEEDED` and alerts.

| Path | What |
| --- | --- |
| `.github/workflows/deploy-app.yml` | The reusable workflow |
| `examples/deliver.yml` | What a product repo adds (about 15 lines) |
| `docs/app-contract.md` | Rules a product meets before onboarding, plus the checklist |
| `server/bin/algo3-deploy` | The deployer (`deploy` / `rollback` / `status`) |
| `server/bin/algo3-deploy-wrapper` | The only command the deploy account may `sudo` |
| `server/bin/algo3-deploy-ssh` | Forced command on each CI key |
| `server/install.sh` | Idempotent installer (`--app <name>` for a registry entry) |
| `server/apps/<app>/` | Per-app registry: `<env>.conf` and `<env>.caddy.tmpl` |
| `server/test/run.sh` | The test suite. It fakes docker and curl and covers every failure path |

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
