# syntax=docker/dockerfile:1.7

# ---------- Stage 1: deps ----------
# Install ALL deps (incl. dev) needed to build static assets.
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
# Point npm at the CodeArtifact proxy when CI supplies a token + registry host;
# otherwise fall back to the public registry. Token is a BuildKit secret.
# npm ci uses the lockfile and refuses to mutate it — reproducible builds.
ARG NPM_REGISTRY_HOST=""
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=secret,id=ca_token \
    if [ -s /run/secrets/ca_token ] && [ -n "$NPM_REGISTRY_HOST" ]; then \
        TOKEN="$(cat /run/secrets/ca_token)"; \
        npm config set registry "https://${NPM_REGISTRY_HOST}/"; \
        npm config set "//${NPM_REGISTRY_HOST}/:_authToken" "${TOKEN}"; \
    fi; \
    if [ -f package-lock.json ]; then npm ci; else npm install --no-audit --no-fund; fi

# ---------- Stage 2: builder ----------
FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN node build.js

# ---------- Stage 3: runtime ----------
# Production-only deps, no build toolchain shipped.
FROM node:20-alpine AS runtime

ENV NODE_ENV=production \
    PORT=3000

# wget is in busybox on alpine; use it for the healthcheck (no curl needed)
RUN addgroup -S -g 1001 app \
    && adduser -S -u 1001 -G app app

WORKDIR /app

COPY --chown=app:app package.json package-lock.json* ./
ARG NPM_REGISTRY_HOST=""
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=secret,id=ca_token \
    if [ -s /run/secrets/ca_token ] && [ -n "$NPM_REGISTRY_HOST" ]; then \
        TOKEN="$(cat /run/secrets/ca_token)"; \
        npm config set registry "https://${NPM_REGISTRY_HOST}/"; \
        npm config set "//${NPM_REGISTRY_HOST}/:_authToken" "${TOKEN}"; \
    fi; \
    if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev --no-audit --no-fund; fi \
    && npm cache clean --force

COPY --chown=app:app --from=builder /app/dist ./dist
COPY --chown=app:app server.js ./

USER app

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:3000/healthz || exit 1

CMD ["node", "server.js"]
