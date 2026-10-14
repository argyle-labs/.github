#!/usr/bin/env bash
# Runs `svelte-kit sync` in the root and each npm workspace that depends on
# @sveltejs/kit, so tsconfigs extending .svelte-kit/tsconfig.json resolve.
set -euo pipefail

# shellcheck disable=SC2016 # single-quoted JS source
mapfile -t dirs < <(node -e '
  const fs = require("fs"), path = require("path");
  const read = (d) => { try { return JSON.parse(fs.readFileSync(path.join(d, "package.json"), "utf8")); } catch { return null; } };
  const root = read(".") || {};
  let ws = root.workspaces || [];
  if (!Array.isArray(ws)) ws = ws.packages || [];
  const dirs = ["."];
  for (const pat of ws) {
    // npm workspaces: plain paths or a trailing `/*` directory glob.
    if (pat.endsWith("/*")) {
      const base = pat.slice(0, -2);
      if (fs.existsSync(base)) for (const e of fs.readdirSync(base, { withFileTypes: true })) if (e.isDirectory()) dirs.push(path.join(base, e.name));
    } else dirs.push(pat);
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
