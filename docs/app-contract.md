# The deployable-app contract

Any app in any language or framework can be deployed by algo3-delivery, as
long as it ships as **a Docker image that meets these rules**. Each rule exists
because the deployer or the operations layer depends on it.

Starter Dockerfiles that already meet every rule, each tested with a sample
app by `templates/test-templates.sh`:

| Stack | Template | Kind |
| --- | --- | --- |
| Static site (Vite, React, Vue, Angular, Astro, HTML) | `templates/dockerfiles/static.Dockerfile` | web |
| Node API or server (Express, Fastify, NestJS, Hono…) | `node-api.Dockerfile` | web / internal |
| Next.js (standalone output) | `nextjs.Dockerfile` (follows node-api; not built by the test) | web |
| Python (FastAPI, Flask, Django) | `python.Dockerfile` | web / internal |
| Go | `go.Dockerfile` | web / internal |
| Background worker / scheduler (any language) | `worker.Dockerfile` | worker |

## Choosing a kind (`KIND=` in the registry)

| Kind | Use for | How a release goes live |
| --- | --- | --- |
| **`web`** (default) | anything with a public hostname: sites, public APIs | it gets the stable alias `<app>-<env>`, the edge site routes the hostname there, and the deployer checks the public URL |
| **`internal`** | an HTTP service only other containers call | it gets the stable alias `<app>-<env>`, which its consumers use; there is no site and no public URL |
| **`worker`** | queue consumers, schedulers, cron-like jobs | no alias, nothing routes to it; readiness comes from Docker's HEALTHCHECK, or from staying up for `STARTUP_SECONDS` |

The stable alias means other services can always reach yours by the same name.
For example, Atlas's web site can route `/api/*` to `atlas-api-production:3000`
in its own template, and that keeps working across every deploy of the API.

## The rules

| # | Rule | What depends on it |
| --- | --- | --- |
| 1 | **The image is built only by CI**, tagged `:<full sha>` and deployed **by digest**. | The deployer checks that the running container is exactly that image. Production runs the byte-identical image staging tested. |
| 2 | **The Dockerfile accepts `ARG RELEASE_SHA`** and makes it visible. Static sites write it to `/release.json`; servers expose it as `version` on their health endpoint (from `ENV RELEASE_SHA`). This is *recommended*, not required: with `RELEASE_PATH=` empty, identity rests on the image digest alone. | Proof that the *app* answering is the new release, not just its container. |
| 3 | **Readiness**: an HTTP health path (`HEALTH_PATH`) answering 2xx, and/or a **Dockerfile `HEALTHCHECK`**. A worker without either must at least stay up for `STARTUP_SECONDS`. | The deployer waits for it before switching traffic. autoheal restarts on unhealthy, and Netdata alerts. |
| 4 | **Non-root user, pinned base images** (exact version, ideally digest), no `:latest`. | A small blast radius, and builds that can be repeated. |
| 5 | **SIGTERM → finish in-flight work and exit within 15 s**, using exec-form `CMD` so the app is PID 1. | The old release drains instead of dropping requests or jobs mid-switch. |
| 6 | **Logs go to stdout**, ideally JSON, with no secrets or personal data. | `docker logs` and the size caps. |
| 7 | **Configuration comes from the environment**, validated at boot. Secrets live only in `/etc/algo3/apps/<app>/<env>.env` on the server. | A misconfigured release fails its readiness check, not a user. |
| 8 | **Migrations run through `RELEASE_COMMAND`**: once, from the new image, before it takes traffic, and never on app start. They must be **expand → contract**, meaning release N+1's migration must not break release N. Add columns first and remove them in a later release. | Deploys are automatic, and the previous release is still serving while the migration runs. A rollback runs the previous code against the migrated database. |
| 9 | **No published ports.** Web and internal apps listen on `CONTAINER_PORT` and are reached by name. Only the container that needs the edge joins `studio`; internal services can live on their own network (`NETWORKS=myapp-private`). | Not publishing a port is the real firewall, because Docker bypasses `ufw`. |
| 10 | **Persistent files go only in named volumes** (`VOLUMES=<app>-data:/data`). They must carry the app's own prefix; host paths are refused. During a switch two releases share the volume, so use `OVERLAP=false` if your app can't tolerate that. | Data survives releases. One app can't mount another app's data. |
| 11 | **`mem_limit` and CPU share** are set from measurement (`MEM_LIMIT`, `CPUS`). | One app's leak or loop can't take the server down. |

## Domains

Every product has its own domains, and one app can have several. They are
declared in the app's settings; the deployer **generates the edge site** from
them, so a new product needs no Caddy file at all:

```ini
# server/apps/biruno-ai/production.conf
# Primary domain: the release is checked here.
HOSTNAME=biruno.ai
# Also served, by the same app.
ALIASES=biruno.com
# Answer with a permanent redirect to https://biruno.ai/…
REDIRECTS=www.biruno.ai,www.biruno.com

# server/apps/biruno-ai/staging.conf
HOSTNAME=staging.biruno.ai
# Search engines must never index staging.
NOINDEX=true
```

Comments go on their own line: `KEY=value  # note` would make the note part of
the value, and the deployer refuses it.

What the platform guarantees:

- **One domain, one owner.** A deploy that would claim a domain another app or
  environment already declares, or that studio-platform serves
  (`/etc/algo3/caddy/platform/`), is refused before anything is pulled, naming
  the owner. A rollback is never blocked by this, even if another app's
  settings conflict.
- **Every domain is checked after each deploy.** The primary must serve the new
  release, or the deploy is rolled back. Aliases must answer and redirects must
  redirect. If one doesn't, that's a **warning** (`domain-warnings=N` in the
  deploy log), not a rollback, because it is DNS or a certificate still being
  issued, which no rollback fixes.
- **Certificates are automatic** (Let's Encrypt, through the edge) for every
  declared domain, and Netdata alerts 14 days before any of them would expire.
  `install.sh --app` updates that list.

### Putting a new domain live

1. **DNS first.** Create `A` (and `AAAA` if the server has IPv6) records for every
   domain, including staging and `www`, pointing at the server. Let's Encrypt
   cannot issue a certificate for a domain that points elsewhere, so a first
   deploy before DNS is ready fails, and says why when `SERVER_IPS` is set in
   `/etc/algo3/delivery.conf`.
2. Check: `sudo /usr/local/libexec/algo3-deploy status <app> <env>` lists the
   domains and whether each one points here.
3. Declare the domain in the settings, then `sudo ./install.sh --app <app>`.
4. The next deploy reloads the edge once to add the site, then gets the
   certificates. Adding or removing a domain later works the same way.

**Cloudflare:** use **DNS only (grey cloud)**, which is what this setup is built
and rehearsed for. Proxied (orange cloud) DNS points at Cloudflare instead of the
server, so `SERVER_IPS` checks would warn, and whether Let's Encrypt's challenge
gets through depends on Cloudflare settings this platform does not control or
test. Treat proxying as a separate, deliberate change.

### When a custom template is needed

Only for routing the generated site can't express, e.g. Atlas serving its API
under the web app's domain. Create `<env>.caddy.tmpl` next to the conf:

```caddy
{{HOSTNAME}} {
	encode zstd gzip
	handle /api/* {
		reverse_proxy atlas-api-production:3000 {
			lb_try_duration 5s
			transport http {
				dial_timeout 300ms
			}
		}
	}
	handle {
		reverse_proxy {{UPSTREAM}} {
			lb_try_duration 5s
			lb_try_interval 50ms
			transport http {
				dial_timeout 300ms
			}
		}
	}
}
```

`{{UPSTREAM}}` becomes this app's stable name and `{{HOSTNAME}}` its primary
domain. A template must serve **exactly** the declared domains (the deployer
compares them), and every `reverse_proxy` needs `lb_try_duration` and a short
`dial_timeout`. Remove the template from the repo and `install.sh --app` retires
it from the server, so the generated site takes over again.

## Registry settings (`/etc/algo3/apps/<app>/<env>.conf`)

| Setting | Default | Meaning |
| --- | --- | --- |
| `KIND` | `web` | `web`, `internal` or `worker` (see above) |
| `IMAGE` | (required) | e.g. `ghcr.io/arslan-khan-dev/atlas-api` (no tag) |
| `HOSTNAME` | (required for web) | the primary domain; the release marker is checked here |
| `ALIASES` | (none) | more domains served exactly the same way, comma-separated |
| `REDIRECTS` | (none) | domains that redirect permanently to `HOSTNAME` (typically `www.`) |
| `NOINDEX` | `false` | `true` adds `X-Robots-Tag: noindex` (use on staging) |
| `CONTAINER_PORT` | `80` | port the app listens on inside the container |
| `HEALTH_PATH` | `/` | HTTP readiness path; empty means rely on the Docker HEALTHCHECK |
| `RELEASE_PATH` / `RELEASE_KEY` | `/release.json` / `release` (web) | release marker; empty means identity by image digest only |
| `RELEASE_COMMAND` | (none) | migrations etc.; one line, no shell (use `sh -c '…'` for shell features) |
| `RELEASE_TIMEOUT` | `300` | seconds before the release command is killed and the deploy refused |
| `VOLUMES` | (none) | `<app>-name:/path[:ro]`, comma-separated |
| `OVERLAP` | `true` | `false` means the old release is stopped *before* the new one starts |
| `STARTUP_SECONDS` | `10` | for apps with no health signal: how long they must stay up |
| `NETWORKS` | `studio` | first one is where the alias lives; then extra networks (e.g. the app's database network) |
| `MEM_LIMIT`, `CPUS`, `READ_ONLY`, `TMPFS` | `256m`, `0.5`, `false`, — | limits and hardening |
| `PROMOTE_FROM` | (none) | set `staging` on production: only releases verified on staging deploy |
| `HEALTH_ATTEMPTS` | `30` | readiness attempts, 2 s apart |

## Onboarding checklist

- [ ] Rules 1–11 met. Start from the matching template.
- [ ] Registry files in this repo under `server/apps/<app>/`: `staging.conf` (with `NOINDEX=true`) and `production.conf` (with `PROMOTE_FROM=staging`), declaring the domains. No Caddy template unless the app needs custom routing (see Domains).
- [ ] DNS for every domain points at the server, **before** the first deploy (see Domains). `sudo algo3-deploy status <app> <env>` reports it.
- [ ] On the server: `sudo ./install.sh --app <app>`, plus `<env>.env` (root, 0600) for runtime secrets.
- [ ] One SSH key per app and environment, added to `~algo3-deploy/.ssh/authorized_keys` as
      `restrict,command="/usr/local/sbin/algo3-deploy-ssh <app> <env>" ssh-ed25519 … ci-<app>-<env>`.
- [ ] Repository secrets `DEPLOY_SSH_KEY_STAGING` and `DEPLOY_SSH_KEY_PRODUCTION`, and variables `VPS_HOST` and `VPS_KNOWN_HOSTS` (GitHub Free has no environments in private repos). A repo with several apps uses one pair of secrets per app and maps them in its workflow (see `examples/deliver-multi-service.yml`).
- [ ] `.github/workflows/deliver.yml`: copy `examples/deliver.yml`, or `examples/deliver-multi-service.yml` for a repo with several services. Set `validate-image` and `validate-command` for your language's tests.
- [ ] UptimeRobot monitor for each primary domain. Certificate expiry for **every** domain is watched by Netdata automatically, from the registry.
- [ ] First staging deploy watched, then the first production promotion.
