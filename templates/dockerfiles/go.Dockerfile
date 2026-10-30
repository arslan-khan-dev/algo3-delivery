# Go service. KIND=web or internal. Expected endpoint:
#   GET /healthz → 200 {"status":"ok","version":"<os.Getenv("RELEASE_SHA")>"}
# Registry: CONTAINER_PORT=8080 HEALTH_PATH=/healthz RELEASE_PATH=/healthz RELEASE_KEY=version
FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/server

FROM alpine:3.24
# Security fixes published after the base image was built: CI's scan refuses
# fixable CRITICAL vulnerabilities, and base images lag behind the fixes.
RUN apk upgrade --no-cache
RUN adduser -D -u 10001 app
COPY --from=build /out/app /usr/local/bin/app
ARG RELEASE_SHA
ENV RELEASE_SHA=$RELEASE_SHA
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
# Handle SIGTERM with http.Server.Shutdown(ctx) so in-flight requests finish.
ENTRYPOINT ["/usr/local/bin/app"]
