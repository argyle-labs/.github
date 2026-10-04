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
        ca-certificates curl git jq perl xz-utils musl-tools pkg-config sudo \
        libssl-dev mold; \
    rm -rf /var/lib/apt/lists/*
# libssl-dev + mold serve the CI compile-speed path:
#   - libssl-dev lets `OPENSSL_NO_VENDOR=1` link the system OpenSSL on the PR
#     gate instead of compiling openssl-src from source every cold build (the
#     single biggest cold-compile cost — pulled in twice, via git2's
#     vendored-openssl and rusqlite's bundled-sqlcipher-vendored-openssl).
#     Release/cross builds do NOT set OPENSSL_NO_VENDOR, so they keep vendoring
#     the static lib for musl — libssl-dev's mere presence changes nothing there.
#   - mold is the fast linker (was best-effort apt at job time); baking it in
#     makes it guaranteed and removes a per-job install.

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

# Warm CARGO_HOME: the sparse index entries + .crate files for the union of
# plugin dependencies, and the orca git db/checkout at ORCA_TAG. A job then
# downloads only what drifted from this lock, and a plugin pinned to another
# orca rev fetches a delta into the existing git db instead of a full clone.
# Extracted sources are dropped; re-extracting a .crate is cheap.
ARG ORCA_TAG=v0.2.1-rc.10
COPY warm /tmp/ci-warm
RUN set -eux; \
    grep -q "tag = \"${ORCA_TAG}\"" /tmp/ci-warm/Cargo.toml; \
    CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked --manifest-path /tmp/ci-warm/Cargo.toml; \
    ls -d "${CARGO_HOME}"/git/db/orca-*; \
    rm -rf /tmp/ci-warm "${CARGO_HOME}/registry/src"

LABEL org.opencontainers.image.source="https://github.com/argyle-labs/.github" \
      org.opencontainers.image.description="orca plugin CI/release toolchain (rust ${RUST_VERSION} + linux targets + zig + sccache + warm CARGO_HOME at orca ${ORCA_TAG})" \
      org.opencontainers.image.licenses="MIT"
