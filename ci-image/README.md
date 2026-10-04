# ci-rust — prebuilt CI toolchain image

Bakes the Rust toolchain + cross tooling + sccache so plugin CI/release jobs
stop re-acquiring them per run (the recurring rustup / `static.rust-lang.org`
Fastly-egress failure). Published to the **internal Gitea registry** and consumed
via `container:`. Epic: [.github#53](https://gitea.scottkey.me/argyle-labs/.github/issues/53).

## What's baked
- Rust **1.95.0** (tracks `orca/rust-toolchain.toml`) + `clippy`, `rustfmt`, `llvm-tools-preview`
- Linux targets: `x86_64`/`aarch64` × `gnu`/`musl`
- `zig` + `cargo-zigbuild` (cross), `sccache`, `cargo-nextest`, `cargo-llvm-cov`
- `jq`, `libssl-dev`, `mold`
- A warm `CARGO_HOME`: `cargo fetch` of `warm/Cargo.lock` (every plugin-facing
  `plugin-toolkit` dependency) plus the orca git db at `ORCA_TAG`. When the
  pinned orca tag moves, bump the tag in `warm/Cargo.toml` and `ORCA_TAG` in the
  Dockerfile together and regenerate the lock (`cargo generate-lockfile`).

## Tags
`ci-rust:<rust-version>` (pinned) and `ci-rust:latest` (current toolchain).

## Bumping Rust
1. Bump `channel` in `orca/rust-toolchain.toml`.
2. Bump `RUST_VERSION` in `ci-image/Dockerfile` + the `ci-image.yml` default to match.
3. Merge → `ci-image.yml` rebuilds `:latest` and the new pinned tag.

Consumers pin `vars.CI_IMAGE` (default `…/ci-rust:latest`), so the bump propagates
on the next CI run — no per-repo edit.

## Prerequisites (epic slice 1 — Gitea admin)
- Gitea container registry enabled + a `ci-publish` robot account.
- Org secrets `CI_REGISTRY_USER` / `CI_REGISTRY_TOKEN`.
- Org var `CI_REGISTRY` (committed default `gitea.scottkey.me`; set it to the
  LAN `IP:port` on runners that can't resolve the vanity name). If served over
  plain HTTP, the runner docker daemon needs it in `insecure-registries`. The
  real LAN endpoint lives in the var, never committed (this repo mirrors public).

## Consumers
`plugin-ci.yml`, the Linux legs of `plugin-release.yml`, the shared
`release.yml` build leg, `sccache-prewarm.yml` and `cargo-publish.yml` run in
`ci-rust:1.95.0`. The composites (`plugin-build`, `rust-setup`, `build-target`)
detect the baked toolchain and skip their rustup / toolchain / zig / sccache
bootstraps; macOS legs run on the host and keep them.
