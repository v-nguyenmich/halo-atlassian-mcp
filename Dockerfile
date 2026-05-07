# syntax=docker/dockerfile:1.7
# Multi-stage: build wheels in slim, final image is distroless.

FROM python:3.12-slim AS build
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY pyproject.toml requirements.lock ./
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir --require-hashes -r requirements.lock
COPY src/ ./src/
RUN /opt/venv/bin/pip install --no-cache-dir --no-deps .

FROM gcr.io/distroless/python3-debian12:nonroot
LABEL org.opencontainers.image.title="halo-mcp-atlassian"
LABEL org.opencontainers.image.source="https://github.com/halostudios/halo-mcp-atlassian"
LABEL org.opencontainers.image.licenses="Proprietary"
COPY --from=build /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HALO_MCP_LOG_LEVEL=INFO
USER nonroot
ENTRYPOINT ["/opt/venv/bin/python", "-m", "halo_mcp_atlassian"]
