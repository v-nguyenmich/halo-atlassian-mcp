# syntax=docker/dockerfile:1.7
# Multi-stage: build wheels in slim, final image is distroless.

# Build stage uses python:3.11-slim to match distroless/python3-debian12 (Python 3.11).
FROM python:3.11-slim AS build
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY pyproject.toml requirements.lock README.md ./
# Install dependencies into a target directory we can copy into distroless.
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --require-hashes --target /install -r requirements.lock
COPY src/ ./src/
RUN pip install --no-cache-dir --no-deps --target /install .

# renovate: datasource=docker depName=gcr.io/distroless/python3-debian12
FROM gcr.io/distroless/python3-debian12:nonroot@sha256:7d1042ce588ab97019fe95c24ffca7bc5a82ccdac572511d5e09bda4435c89c5
LABEL org.opencontainers.image.title="halo-mcp-atlassian"
LABEL org.opencontainers.image.source="https://github.com/v-nguyenmich/halo-atlassian-mcp"
LABEL org.opencontainers.image.licenses="Proprietary"
COPY --from=build /install /app
ENV PYTHONPATH="/app" \
    PATH="/app/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HALO_MCP_LOG_LEVEL=INFO
USER nonroot
ENTRYPOINT ["python", "-m", "halo_mcp_atlassian"]
