#!/usr/bin/env bash
# Runs `svelte-kit sync` in the root and each npm workspace that depends on
# @sveltejs/kit, so tsconfigs extending .svelte-kit/tsconfig.json resolve.
set -euo pipefail

# npm resolves its own workspace globs; fall back to plain and `dir/*` patterns
# (warning on anything else) when `npm query` is unavailable.
ws_json=$(NODE_NO_WARNINGS=1 npm query .workspace 2>/dev/null || echo null)

# shellcheck disable=SC2016 # single-quoted JS source
mapfile -t dirs < <(WS_JSON="$ws_json" node -e '
  const fs = require("fs"), path = require("path");
  const read = (d) => { try { return JSON.parse(fs.readFileSync(path.join(d, "package.json"), "utf8")); } catch { return null; } };
  const dirs = ["."];
  let queried = null;
  try { queried = JSON.parse(process.env.WS_JSON); } catch {}
  if (Array.isArray(queried)) {
    for (const w of queried) dirs.push(w.location || path.relative(".", w.path));
  } else {
    let ws = (read(".") || {}).workspaces || [];
    if (!Array.isArray(ws)) ws = ws.packages || [];
    for (const pat of ws) {
      if (pat.endsWith("/*") && !/[*?{[!]/.test(pat.slice(0, -2))) {
        const base = pat.slice(0, -2);
        if (fs.existsSync(base)) for (const e of fs.readdirSync(base, { withFileTypes: true })) if (e.isDirectory()) dirs.push(path.join(base, e.name));
      } else if (!/[*?{[!]/.test(pat)) dirs.push(pat);
      else console.error(`::warning::svelte-kit-sync: cannot resolve workspace pattern ${pat}; skipped`);
    }
  }
  for (const d of dirs) {
    const p = read(d);
    if (!p) continue;
    const deps = { ...p.dependencies, ...p.devDependencies };
    const cfg = ["js", "mjs", "cjs", "ts"].some((x) => fs.existsSync(path.join(d, "svelte.config." + x)));
    if (deps["@sveltejs/kit"] && cfg) console.log(d);
  }
')

for d in "${dirs[@]}"; do
  echo "svelte-kit sync in $d"
  (cd "$d" && npx --no-install svelte-kit sync)
done
