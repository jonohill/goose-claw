# syntax=docker/dockerfile:1.4

# ---------------------------------------------------------------------------
# Build stage 1: the patched goose CLI (provides `goose acp`)
# ---------------------------------------------------------------------------
FROM rust:1.92-bookworm AS goose-builder

ARG GOOSE_REPO=https://github.com/aaif-goose/goose.git
ARG GOOSE_REF=a0aed81f36076cfe48def4b21c04d7f0d33072e8

ARG GOOSE_FEATURES=portable-default

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      build-essential \
      cmake \
      pkg-config \
      libssl-dev \
      libdbus-1-dev \
      libclang-dev \
      protobuf-compiler \
      libprotobuf-dev \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git init -q . && \
    git remote add origin "${GOOSE_REPO}" && \
    git fetch --depth 1 origin "${GOOSE_REF}" && \
    git checkout -q FETCH_HEAD

# Apply local source patches. A failure here
# stops the build rather than silently producing an unpatched, fail-open binary.
#   0001-adversary-fail-closed.patch — adversary reviewer fails CLOSED when it
#     cannot render a verdict; a real BLOCK is always a hard Deny.
COPY patches/ /build/patches/
RUN for p in /build/patches/*.patch; do \
      echo "Applying $p" && git apply --verbose "$p"; \
    done

ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_OPT_LEVEL=z \
    CARGO_PROFILE_RELEASE_STRIP=true
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --package goose-cli --bin goose \
      --no-default-features --features "${GOOSE_FEATURES}" && \
    cp /build/target/release/goose /usr/local/bin/goose

# ---------------------------------------------------------------------------
# Build stage 2: the OpenAB harness
# ---------------------------------------------------------------------------
FROM rust:1.92-bookworm AS openab-builder

ARG OPENAB_REPO=https://github.com/openabdev/openab.git
# Pinned to a known-good revision (HEAD of main at time of writing). Override
# with --build-arg OPENAB_REF=<tag|sha> to track a release.
ARG OPENAB_REF=342f76dba25fd128be6debcbe78295ef9f430e00

# Slack-only build: drops discord + the AWS SDK (secrets-aws / config-s3 /
# agentcore) + pre-seed, which are the bulk of the compile. For the full
# upstream default (adds Discord + AWS integrations) pass:
#   --build-arg OPENAB_FEATURES=default-passthrough  (see below)
ARG OPENAB_FEATURES=slack

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      build-essential \
      cmake \
      pkg-config \
      libssl-dev \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /openab
RUN git init -q . && \
    git remote add origin "${OPENAB_REPO}" && \
    git fetch --depth 1 origin "${OPENAB_REF}" && \
    git checkout -q FETCH_HEAD

ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
# `slack` (default) -> --no-default-features --features slack (lean).
# `default-passthrough` -> plain `cargo build` (upstream default features).
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/openab/target \
    if [ "${OPENAB_FEATURES}" = "default-passthrough" ]; then \
      cargo build --release --bin openab; \
    else \
      cargo build --release --bin openab \
        --no-default-features --features "${OPENAB_FEATURES}"; \
    fi && \
    cp /openab/target/release/openab /usr/local/bin/openab

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

ARG TARGETARCH=amd64
ARG YQ_VERSION=v4.53.3

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      tini \
      ripgrep \
      libssl3 \
      libdbus-1-3 \
      libxcb1 \
      curl \
      git \
      python3 \
      python3-venv \
      jq \
      procps \
      unzip \
      openssh-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

COPY --from=goose-builder  /usr/local/bin/goose  /usr/local/bin/goose
COPY --from=openab-builder /usr/local/bin/openab /usr/local/bin/openab

# Baked goose config + adversary policy + the shared entrypoint
# The entrypoint lays down ~/.config/goose (config.yaml +
# adversary.md) before exec'ing OpenAB, so the reviewer is active for the
# `goose acp` children.
COPY config.default.yaml   /etc/goose/config.default.yaml
COPY adversary.default.md  /etc/goose/adversary.default.md
COPY docker-entrypoint.sh  /usr/local/bin/docker-entrypoint.sh
# Default OpenAB config: Slack adapter + `[agent] command = goose acp`.
# The entrypoint deep-merges an optional /etc/openab/config.override.toml over
# this (same semantics as the goose config) into /data/.openab/config.toml,
# which is what the CMD points at.
COPY config.openab.toml    /etc/openab/config.toml
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

RUN useradd -u 1000 -s /bin/bash -d /data goose && \
    mkdir -p /data/.config/goose /data/.openab /data/workspace && \
    chown -R goose:goose /data

ENV HOME=/data \
    PATH=/usr/local/bin:$PATH \
    # Entrypoint-level knob: whether to install adversary.md at all (reviewer
    # on/off). Read by the entrypoint, which runs before OpenAB starts.
    GOOSE_ADVERSARY_DISABLE=false

# NOTE on env propagation: OpenAB only forwards HOME/PATH/USER to the `goose
# acp` child by default. So goose's *runtime* knobs — GOOSE_MODE=auto,
# GOOSE_ADVERSARY_FAIL_CLOSED, GOOSE_PROVIDER/GOOSE_MODEL and the provider API
# key — are set in [agent].env in config.openab.toml, NOT here, otherwise they
# would never reach the process that actually reads them. (Fail-closed is the
# code default when GOOSE_ADVERSARY_FAIL_CLOSED is unset, so it is safe either
# way; config.openab.toml sets it explicitly for clarity.)

USER goose
WORKDIR /data

# tini as PID 1 (reaps goose children) -> shared entrypoint (lays down goose
# config) -> OpenAB, which connects to Slack and spawns `goose acp` per thread.
# Provide SLACK_BOT_TOKEN / SLACK_APP_TOKEN and your provider key at runtime
# (see config.openab.toml). No port is exposed — Slack Socket Mode is outbound.
# Mount a volume at /data to persist all agent + OpenAB state across restarts.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["openab", "run", "-c", "/data/.openab/config.toml"]
