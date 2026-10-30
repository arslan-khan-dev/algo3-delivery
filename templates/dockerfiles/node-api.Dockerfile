# Node.js API or server (Express, Fastify, NestJS, Hono, Koa…).
# KIND=web (public) or internal. Expected endpoint:
#   GET /healthz → 200 {"status":"ok","version":"<process.env.RELEASE_SHA>"}
# Registry: CONTAINER_PORT=3000 HEALTH_PATH=/healthz RELEASE_PATH=/healthz RELEASE_KEY=version
# Migrations: RELEASE_COMMAND=npx prisma migrate deploy   (keep the CLI in the
# runtime image — move it from devDependencies, or use `node dist/migrate.js`).
FROM node:22.23.4-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
# mkdir: node_modules must exist even for an app with no dependencies.
RUN npm run build && npm prune --omit=dev && mkdir -p node_modules

FROM node:22.23.4-alpine
# Security fixes published after the base image was built: CI's scan refuses
# fixable CRITICAL vulnerabilities, and base images lag behind the fixes.
RUN apk upgrade --no-cache
ENV NODE_ENV=production PORT=3000
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/package.json ./
ARG RELEASE_SHA
ENV RELEASE_SHA=$RELEASE_SHA
# Mount point for persistent data (VOLUMES=<app>-data:/data). A new named
# volume copies this ownership, so the non-root app can write to it.
RUN mkdir -p /data && chown node:node /data
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --start-interval=1s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
# Exec form: node is PID 1 and receives SIGTERM directly. Handle it in the app
# (server.close(), then exit) so in-flight requests finish during a switch.
CMD ["node", "dist/main.js"]
