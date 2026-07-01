# syntax=docker/dockerfile:1.7

# ---------- Stage 1: builder ----------
# Compiles wheels with build tools that we will NOT ship to runtime.
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

RUN apt-get update && apt-get install --no-install-recommends -y \
        build-essential \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Pull dependencies through AWS CodeArtifact when the CI passes a token + index
# host; otherwise fall back to public PyPI so local `docker build` still works.
# The token is a BuildKit secret (never baked into an image layer).
ARG PIP_INDEX_HOST=""
RUN --mount=type=secret,id=ca_token \
    if [ -s /run/secrets/ca_token ] && [ -n "$PIP_INDEX_HOST" ]; then \
        TOKEN="$(cat /run/secrets/ca_token)"; \
        pip wheel --wheel-dir /wheels \
            --index-url "https://aws:${TOKEN}@${PIP_INDEX_HOST}" \
            -r requirements.txt; \
    else \
        pip wheel --wheel-dir /wheels -r requirements.txt; \
    fi

# ---------- Stage 2: runtime ----------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH="/home/app/.local/bin:${PATH}"

# Runtime libs only (libpq for asyncpg, curl for healthcheck).
# apt-get upgrade patches base-image OS package CVEs flagged by Trivy.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install --no-install-recommends -y \
        libpq5 \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --create-home --home-dir /home/app app

WORKDIR /app

COPY --from=builder /wheels /wheels
COPY requirements.txt .
# Upgrade pip/setuptools first — the base image ships older versions with known
# HIGH CVEs (e.g. setuptools CVE-2024-6345 / CVE-2025-47273). Then install the
# app wheels offline.
RUN pip install --no-cache-dir --upgrade pip setuptools \
    && pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

COPY --chown=app:app app/ ./app/

USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl --fail --silent http://localhost:8000/healthz || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--access-log", "--no-server-header"]
