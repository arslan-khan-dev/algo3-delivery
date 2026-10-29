# Background worker / scheduler (any language; Node shown). KIND=worker.
# No HTTP. Readiness comes from this HEALTHCHECK, or, without one, from the
# container staying up for STARTUP_SECONDS. The worker touches /tmp/alive
# every few seconds while its loop is healthy; the check fails if it stops.
# Registry: KIND=worker  OVERLAP=false (if it must never run twice: schedulers, cron)
FROM node:22.23.4-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
# mkdir: node_modules must exist even for an app with no dependencies.
RUN npm run build && npm prune --omit=dev && mkdir -p node_modules

FROM node:22.23.4-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
ARG RELEASE_SHA
ENV RELEASE_SHA=$RELEASE_SHA
USER node
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --start-interval=1s --retries=3 \
    CMD find /tmp/alive -mmin -1 | grep -q . || exit 1
# On SIGTERM: stop taking new jobs, finish the current one, exit (within 15 s).
CMD ["node", "dist/worker.js"]
