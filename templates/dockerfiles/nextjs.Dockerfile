# Next.js with `output: "standalone"` in next.config.js. KIND=web.
# Release marker: add app/api/healthz/route.ts returning
#   { status: "ok", version: process.env.RELEASE_SHA }
# Registry: CONTAINER_PORT=3000 HEALTH_PATH=/api/healthz RELEASE_PATH=/api/healthz RELEASE_KEY=version
FROM node:22.23.4-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:22.23.4-alpine
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0 NEXT_TELEMETRY_DISABLED=1
WORKDIR /app
COPY --from=build --chown=node:node /app/.next/standalone ./
COPY --from=build --chown=node:node /app/.next/static ./.next/static
COPY --from=build --chown=node:node /app/public ./public
ARG RELEASE_SHA
ENV RELEASE_SHA=$RELEASE_SHA
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --start-interval=1s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3000/api/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.js"]
