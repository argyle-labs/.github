<p align="center">
  <img src="https://raw.githubusercontent.com/argyle-labs/.github/main/assets/argyle-labs-icon.png" width="128" alt="argyle-labs" />
</p>

# Argyle Labs

Local-first homelab & developer-tooling, built around **[orca](https://github.com/argyle-labs/orca)** — a single self-contained binary that orchestrates infrastructure, services, and AI agents, with everything else shipped as standalone **orca plugins**.

## orca

[**orca**](https://github.com/argyle-labs/orca) — the core. A single Rust binary with an embedded web UI that acts as CLI, TUI, web server, and MCP server. It owns the domain model (containers, storage, namespaces, pods, notifications, agents) and loads plugins as ABI-stable `cdylib`s at runtime. Local models run by default; Claude is escalation-only.

## Plugins

Each plugin is its own repository and registers with orca. Most build as a `cdylib` whose only orca dependency is `plugin-toolkit`. (Some plugin code is still being migrated out of the orca tree — the standalone repos below are the canonical homes.)

### Infrastructure & hosts

| Plugin | What it does |
|--------|--------------|
| [proxmox](https://github.com/argyle-labs/proxmox) | Proxmox VE — nodes/guests, cluster status, plus `cluster_roster` + `topology` ABI backends. |
| [unraid](https://github.com/argyle-labs/unraid) | Unraid host GraphQL — typed queries, endpoint registry, topology, schema-drift detection. |
| [docker](https://github.com/argyle-labs/docker) | Docker Engine + Compose adapted into orca's containers domain. |
| [dockge](https://github.com/argyle-labs/dockge) | Dockge — self-hosted Docker Compose stack manager (plugin + deploy assets). |

### Storage

| Plugin | What it does |
|--------|--------------|
| [nfs](https://github.com/argyle-labs/nfs) | NFS `StorageBackend` with stale-mount self-heal (backend-only). |
| [smb](https://github.com/argyle-labs/smb) | SMB/CIFS `StorageBackend` for orca's storage domain (backend-only). |

### Media

| Plugin | What it does |
|--------|--------------|
| [plex](https://github.com/argyle-labs/plex) | Self-hosted Plex with GPU hardware transcoding + orca lifecycle/diagnostics. |
| [jellyfin](https://github.com/argyle-labs/jellyfin) | Self-hosted Jellyfin with GPU hardware transcoding + orca lifecycle/diagnostics. |
| [arr](https://github.com/argyle-labs/arr) | The *arr stack — Sonarr, Radarr, Prowlarr, Lidarr — in one cdylib. |

### AI, messaging & home

| Plugin | What it does |
|--------|--------------|
| [llm](https://github.com/argyle-labs/llm) | The `model.*` registry + LLM backend runtime (Anthropic, LM Studio, Ollama, claude-code). |
| [mcp](https://github.com/argyle-labs/mcp) | Federates MCP servers (stdio + HTTP/SSE) into orca's tool surface — an MCP client. |
| [ntfy](https://github.com/argyle-labs/ntfy) | ntfy push notifications — a notifications backend + self-host deploy lifecycle. |
| [homeassistant](https://github.com/argyle-labs/homeassistant) | Home Assistant — lifecycle + entities/automations/service API. |

## Developing a plugin

A plugin is its own repo with an `orca-plugin` manifest, registered via `orca plugin add`. See the [orca plugin authoring guide](https://github.com/argyle-labs/orca/blob/main/docs/plugin-authoring.md), and [docker](https://github.com/argyle-labs/docker) or [unraid](https://github.com/argyle-labs/unraid) as worked references.
