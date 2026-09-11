# ci-rust — prebuilt Rust toolchain image for orca plugin CI + release.
#
# Bakes everything a plugin CI/release job re-acquired per run (rustup, the
# toolchain, cross tooling, sccache) so job-time never touches
# static.rust-lang.org / sh.rustup.rs / github release curls — the recurring
# Fastly-egress failure the `Ensure rustup (resilient bootstrap)` hack works
# around. Pulled from the internal Gitea registry, so the hot path stays on-LAN.
#
# The pin MUST track orca's rust-toolchain.toml (channel + components). Bump
# RUST_VERSION here when that file bumps; the image tag is the rust version.
#
#   docker build -t ci-rust:1.95.0 --build-arg RUST_VERSION=1.95.0 ci-image/
#
# One image serves every Linux target: native x86_64-gnu plus cross
# (aarch64-gnu, x86_64/aarch64-musl) via cargo-zigbuild. macOS is not a
# container target — the mint-macos runner is prebaked separately.

ARG RUST_VERSION=1.95.0
FROM docker.io/library/rust:${RUST_VERSION}-bookworm

# Cross linkers/toolchains come from zig (via cargo-zigbuild), so the OS layer
# only needs the basics + musl headers for anything that probes them.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git perl xz-utils musl-tools pkg-config; \
    rm -rf /var/lib/apt/lists/*

# Node.js — required by the CI job runner, NOT by the build. Gitea/act runs
# JavaScript actions (actions/checkout@v4, upload-artifact, etc.) by exec'ing
# `node` INSIDE the job container; without it every container job dies at the
# first `uses:` step ("job not started" / checkout failure). Official static
# build, pinned; x86_64 host (CI runners are x86_64).
ARG NODE_VERSION=24.21.0
RUN set -eux; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
            --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'; \
    node --version; npm --version

# Toolchain components (match orca/rust-toolchain.toml) + every Linux target the
# release matrix builds. `rust:<ver>` already carries the pinned rustc/cargo.
RUN set -eux; \
    rustup component add clippy rustfmt llvm-tools-preview; \
    rustup target add \
        x86_64-unknown-linux-gnu \
        aarch64-unknown-linux-gnu \
        x86_64-unknown-linux-musl \
        aarch64-unknown-linux-musl

# zig: the cross linker/sysroot cargo-zigbuild drives. Pinned; x86_64 host only
# (CI runners are x86_64 and cross-compile the arm targets).
ARG ZIG_VERSION=0.13.0
RUN set -eux; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt; \
    ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    zig version

# sccache (shared MinIO compile cache) + cargo-zigbuild + the coverage/test
# runners CI uses (`cargo llvm-cov nextest`). Prebuilt binaries where available
# to keep the image build cheap.
ARG SCCACHE_VERSION=v0.8.2
RUN set -eux; \
    curl -fsSL "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin --wildcards '*/sccache'; \
    chmod +x /usr/local/bin/sccache; \
    sccache --version
RUN set -eux; \
    curl -fsSL "https://get.nexte.st/latest/linux" | tar -xz -C /usr/local/cargo/bin; \
    cargo-nextest --version
RUN set -eux; \
    cargo install --locked cargo-zigbuild cargo-llvm-cov

# Warm the cargo registry index so the first job doesn't pay a cold index fetch.
# (A best-effort update; harmless if the network is unavailable at build time.)
RUN cargo search --limit 1 serde >/dev/null 2>&1 || true

LABEL org.opencontainers.image.source="https://github.com/argyle-labs/.github" \
      org.opencontainers.image.description="orca plugin CI/release toolchain (rust ${RUST_VERSION} + linux targets + zig + sccache)" \
      org.opencontainers.image.licenses="MIT"
