# The deployable-app contract

Every product deployed by algo3-delivery meets this contract **before** it is
onboarded. Each rule exists because the deployer or the operations layer
depends on it. Breaking one means a deploy that cannot be verified, a rollback
that cannot work, or a failure nobody hears about.

| # | Rule | What depends on it |
| --- | --- | --- |
| 1 | **The image is built only by CI**, tagged `:<full 40-char sha>`, and deployed by **digest**. Never `:latest`, never built on the server. | Production runs the byte-identical image staging tested. A rollback is exact. |
| 2 | **The Dockerfile accepts `ARG RELEASE_SHA`** and the app serves it: `GET /release.json` returns `{"release":"<sha>"}`, or another path and key set in the registry. | The deployer proves which build is answering, before and after the switch. |
| 3 | **A health endpoint** (`HEALTH_PATH`) answers 2xx once the app can serve traffic. Apps with a database also check the DB on it, or on a separate readiness path. | The switch waits for it. `autoheal` and the alerts use it. |
| 4 | **Dockerfile `HEALTHCHECK`** on the same endpoint, with a non-root user and pinned base images. | Docker knows "running but broken". `autoheal` restarts it. |
| 5 | **Graceful shutdown**: on SIGTERM, stop accepting connections, finish in-flight requests, and exit within 25 s. | The old release drains instead of dropping requests mid-switch. |
| 6 | **Logs go to stdout as JSON**, one event per line, with no secrets, tokens or personal data. | `docker logs` stays readable and searchable. Docker caps log size. |
| 7 | **Configuration comes from the environment and is validated at boot**, failing fast with a clear message. Secrets live only in `/etc/algo3/apps/<app>/<env>.env` on the server. | A misconfigured release fails its readiness check, not a user. |
| 8 | **Migrations never run on start.** They ship as a separate command in the image, are forward-only, and are **expand → contract**: release N+1's migration must not break release N. | Blue/green runs two releases side by side, and a rollback must work after a migration. |
| 9 | **No published ports.** The container listens on its own port, reached by name on the `studio` network. Only the edge-facing container joins `studio`. Database-facing internals stay on the app's own network. | Docker publishes ports past `ufw`, so not publishing is the real firewall. |
| 10 | **A memory limit and CPU share** are set in the registry (`MEM_LIMIT`, `CPUS`), sized from measurement. | One product's leak or loop cannot take the server down. |

## Onboarding checklist

- [ ] Rules 1–10 met. The image's `release.json` matches its commit in the CI smoke test.
- [ ] `server/apps/<app>/{staging,production}.conf` and `*.caddy.tmpl` added to this repo. Production has `PROMOTE_FROM=staging`.
- [ ] On the server: `sudo ./install.sh --app <app>`, plus `<env>.env` (root, 0600) if the app needs secrets.
- [ ] One SSH key **per environment**, added to `~algo3-deploy/.ssh/authorized_keys` as
      `restrict,command="/usr/local/sbin/algo3-deploy-ssh <app> <env>" ssh-ed25519 … ci-<app>-<env>`.
- [ ] GitHub environments `<app>-staging` and `<app>-production`, each with `DEPLOY_SSH_KEY`, `VPS_HOST` and `VPS_KNOWN_HOSTS`.
- [ ] `.github/workflows/deliver.yml` copied from `examples/deliver.yml`.
- [ ] UptimeRobot monitor for each public hostname, including TLS expiry.
- [ ] First staging deploy verified, then the first production promotion. **A human watches both.**
