# Static site (Vite / React / Vue / Angular / Astro / plain HTML) → Caddy.
# KIND=web. Release marker: /release.json (the deployer's default).
# Set OUTPUT_DIR to your build's output folder (dist, build, dist/<app>/browser…).
FROM node:22.23.4-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
ARG OUTPUT_DIR=dist
ARG RELEASE_SHA
RUN test -n "$RELEASE_SHA" && mkdir -p /out && cp -r "/app/$OUTPUT_DIR/." /out/ \
    && printf '{"release":"%s"}\n' "$RELEASE_SHA" > /out/release.json

FROM caddy:2.11.7-alpine
# Serves /srv, falls back to index.html for client-side routes.
RUN printf ':80 {\n\troot * /srv\n\tencode zstd gzip\n\ttry_files {path} /index.html\n\tfile_server\n}\n' > /etc/caddy/Caddyfile
COPY --from=build /out /srv
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
