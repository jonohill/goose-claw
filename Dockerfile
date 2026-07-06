# syntax=docker/dockerfile:1.4

# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
# Matches rust-toolchain.toml (channel 1.92). rustup in the base image will
# still honour rust-toolchain.toml if the pinned version ever drifts.
FROM rust:1.92-bookworm AS builder

# Which repo / revision to build.
#
# GOOSE_REF is pinned to the exact commit that patches/0001-adversary-fail-closed.patch
# was generated against, so `git apply` always succeeds. You can override it with
# --build-arg GOOSE_REF=<branch|tag|sha> to track a different revision, but the
# patch may then fail to apply and the build will stop by design — better to fail
# loudly than ship a binary that silently reverted to upstream fail-open.
ARG GOOSE_REPO=https://github.com/aaif-goose/goose.git
ARG GOOSE_REF=a0aed81f36076cfe48def4b21c04d7f0d33072e8

# Cargo feature set for goose-server. Default drops the heavy `local-inference`
# feature (statically-linked llama.cpp/GGML, ~80MB of binary) — the server talks
# to remote providers instead. `portable-default` = rustls-tls, aws-providers,
# telemetry, otel. To re-enable on-device inference, pass e.g.:
#   --build-arg GOOSE_FEATURES="portable-default,local-inference"
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

# Clone the requested revision (shallow, to keep the layer small). This form
# fetches a single commit and works for a branch name, a tag, OR a full commit
# SHA — GitHub allows fetching a reachable SHA directly, which `git clone
# --branch` does not.
WORKDIR /build
RUN git init -q . && \
    git remote add origin "${GOOSE_REPO}" && \
    git fetch --depth 1 origin "${GOOSE_REF}" && \
    git checkout -q FETCH_HEAD

# Apply local source patches on top of the checked-out revision, before building.
# A failure here stops the build rather than silently producing an unpatched
# binary. Patches (in apply order by filename):
#   0001-adversary-fail-closed.patch — adversary mode fails CLOSED when the
#     reviewer cannot render a verdict (no provider / review error) instead of
#     the upstream fail-open. In Auto mode the tool call is escalated to a human
#     approval prompt; in every other mode it is hard-denied. A real BLOCK
#     verdict is always a hard deny regardless of mode. Runtime-toggleable back
#     to fail-open via GOOSE_ADVERSARY_FAIL_CLOSED (see runtime stage).
COPY patches/ /build/patches/
RUN for p in /build/patches/*.patch; do \
      echo "Applying $p" && git apply --verbose "$p"; \
    done

# Release build tuned for a small binary. Cache mounts keep the registry and
# target dir warm across rebuilds (requires BuildKit / docker buildx).
ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_OPT_LEVEL=z \
    CARGO_PROFILE_RELEASE_STRIP=true
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --package goose-server --bin goosed \
      --no-default-features --features "${GOOSE_FEATURES}" && \
    cp /build/target/release/goosed /usr/local/bin/goosed

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

# yq (mikefarah) — used by the entrypoint to deep-merge the baked default
# config with any user-supplied override. Single static Go binary. Pinned for
# reproducible builds. TARGETARCH is provided automatically by buildx.
ARG TARGETARCH=amd64
ARG YQ_VERSION=v4.53.3

# Runtime dependencies:
#  - libdbus-1-3   -> dbus (kept for safety; not needed once system-keyring is off)
#  - libxcb1       -> transitive graphics dep
#  - git / curl    -> commonly needed by agent tooling
# NOTE: libgomp1 (OpenMP) dropped along with the local-inference feature.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libssl3 \
      libdbus-1-3 \
      libxcb1 \
      curl \
      git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

COPY --from=builder /usr/local/bin/goosed /usr/local/bin/goosed

# Baked default config + entrypoint that layers user overrides on top of it.
COPY config.default.yaml /etc/goose/config.default.yaml
# Baked default adversary policy (claw mode). Its presence at
# ~/.config/goose/adversary.md — placed there by the entrypoint — turns the
# adversary reviewer ON by default. Override with a mounted
# /etc/goose/adversary.override.md, or disable via GOOSE_ADVERSARY_DISABLE.
COPY adversary.default.md /etc/goose/adversary.default.md
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash goose && \
    mkdir -p /home/goose/.config/goose && \
    chown -R goose:goose /home/goose

ENV HOME=/home/goose \
    PATH=/usr/local/bin:$PATH \
    # Bind to all interfaces so the server is reachable from outside the container.
    GOOSE_HOST=0.0.0.0 \
    GOOSE_PORT=3000 \
    # TLS defaults to on in goosed; disable for plain HTTP, or mount certs and
    # set GOOSE_TLS=true with GOOSE_TLS_CERT_PATH / GOOSE_TLS_KEY_PATH.
    GOOSE_TLS=false \
    # Adversary mode (enabled by mounting ~/.config/goose/adversary.md) fails
    # CLOSED in this build: if the adversary reviewer can't reach a verdict
    # (no provider / review error), the reviewed tool call is escalated to a
    # human approval prompt in Auto mode and hard-DENIED in every other mode.
    # Set this to false/0/no/off to restore upstream fail-open (allow) behaviour
    # without a rebuild.
    GOOSE_ADVERSARY_FAIL_CLOSED=true \
    # The baked claw adversary policy (/etc/goose/adversary.default.md) is
    # installed to ~/.config/goose/adversary.md by the entrypoint, enabling the
    # reviewer by default. Set truthy to ship without it (reviewer off), or
    # mount /etc/goose/adversary.override.md to replace the policy wholesale.
    GOOSE_ADVERSARY_DISABLE=false

USER goose
WORKDIR /home/goose

EXPOSE 3000

# The entrypoint merges baked defaults with any user override, then exec's
# `goosed` with the given arguments. `goosed agent` starts the agent server.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["agent"]
