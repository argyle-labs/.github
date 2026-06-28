# argyle-labs / .github

Org-level GitHub config and **fleet tooling** for the argyle-labs org.

- [`profile/README.md`](profile/README.md) — the public org profile page.
- [`bin/labs`](bin/labs) — unified multi-repo management CLI (below).
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — lints `bin/labs`.

## `labs` — fleet management

`labs` manages every repo in the org as one fleet. It discovers repos **live**
from GitHub (`gh repo list argyle-labs`), so new plugin repos are picked up
automatically with no manifest to maintain. Each repo is a sibling directory
under `$LABS_HOME` (default `~/code/argyle-labs`).

```sh
# Put it on PATH (or symlink into ~/.local/bin)
export PATH="$HOME/code/argyle-labs/.github/bin:$PATH"

labs list                         # every repo: visibility, group, clone state
labs clone --plugins              # clone any missing plugin repos
labs sync                         # clone missing + ff-pull everything
labs status                       # per-repo branch + dirty count

# Branch -> commit -> push -> PR, across the whole fleet (or a filter)
labs branch feat/deploy-target --plugins
labs foreach --plugins -- cargo fmt --all
labs commit -m "feat: add deploy-target trait" --plugins
labs push --plugins
labs pr -t "Add deploy-target trait" -b "See orca#NNN" --plugins
labs switch main --all && labs pull
```

**Filters:** `--all` (default) · `--public` · `--private` · `--plugins` ·
`--core` · `--meta`, or an explicit list of repo names.

**Safety:** `commit`, `push`, and `pr` refuse to act on a repo's default branch
(`main`/`master`) — pass `--allow-default` to override. The org standard is
branch + PR, never a direct push to protected main.

Run `labs --help` for the full command list.

## Org branch & CI policy

Applied uniformly with `labs protect` and enforced by GitHub branch protection:

- **Protected default branch.** Direct pushes to `main`/`master` are restricted
  to a single override user (`scottdkey`); everyone else lands changes via PR.
- **Override.** `enforce_admins` is **off**, so the override user can bypass in a
  pinch — no other actor can.
- **Required checks.** Every PR must pass the repo's `ci` check before it can be
  merged. For plugin repos `ci` runs `cargo fmt --check`, `clippy -D warnings`,
  and `cargo test` (build **and** test) on PR open/update. This repo's `ci`
  lints `bin/labs`.
- **No force-push / no branch deletion** on the default branch.

```sh
labs protect --all                # apply the policy everywhere (public repos)
labs protect --check ci .github   # force-require a named check on a repo
```

> Private repos on the current GitHub plan can't carry branch protection
> (it needs Pro), so `labs protect` reports them as skipped. They pick up the
> policy automatically once made public — `orca` already ships a full CI
> workflow ready to be required at that point.
