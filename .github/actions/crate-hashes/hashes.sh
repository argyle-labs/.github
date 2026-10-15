#!/usr/bin/env bash
# Prints a JSON map crate -> sha256 of every input that can change that crate's
# build or test result. Run from the workspace root. Env: IMAGE (CI image tag),
# WORKFLOW_FILE (calling workflow path; GITHUB_WORKFLOW_REF when empty),
# EXTRA_PATHS (lines of `crate: path [path...]`; `*` applies to every crate).
# Literal include!/include_str!/include_bytes!/include_dir!/sqlx::migrate!/
# #[folder] targets outside a crate are added to it automatically. Any unresolvable input (workflow file, path, crate,
# include) fails the run rather than hashing less.
set -euo pipefail

meta=$(cargo metadata --format-version 1 --no-deps)
# --all-features so optional workspace deps are in the closure.
full=$(cargo metadata --format-version 1 --all-features)
root=$(jq -r '.workspace_root' <<< "$meta")

# name<TAB>relative dir, one line per workspace member.
members=$(jq -r --arg root "$root/" '
  .workspace_members as $ids
  | .packages[] | select(.id as $id | $ids | index($id))
  | [.name, (.manifest_path | ltrimstr($root) | sub("/?Cargo.toml$"; "") | if . == "" then "." else . end)]
  | @tsv' <<< "$meta")

# Transitive closure of workspace-internal deps (normal, dev and build) per
# crate. A closure rather than a recursive hash-of-hashes so dev-dependency
# cycles (A dev-depends on B, B depends on A) still terminate.
closure=$(jq -c '
  (.workspace_members) as $ids
  | (.packages | map({key: .id, value: .name}) | from_entries) as $name
  | (.resolve.nodes
     | map(select(.id as $id | $ids | index($id)))
     | map({key: $name[.id],
            value: [.deps[] | select(.pkg as $p | $ids | index($p)) | $name[.pkg]]})
     | from_entries) as $g
  | def reach($seen):
      ($seen + [$seen[] | $g[.][]?] | unique) as $next
      | if $next == $seen then $seen else reach($next) end;
    $g | with_entries(.value = (reach(.value) - [.key]))' <<< "$full")


workflow=${WORKFLOW_FILE:-}
# GITHUB_WORKFLOW_REF is `owner/repo/<path>@<ref>`, <path> relative to the repo
# root.
if [ -z "$workflow" ] && [ -n "${GITHUB_WORKFLOW_REF:-}" ]; then
  workflow=${GITHUB_WORKFLOW_REF#"${GITHUB_REPOSITORY:-}/"}
  workflow=${workflow%%@*}
fi
workflow_blob=""
[ -z "$workflow" ] || workflow_blob=$(git ls-files -s -- ":(top)$workflow")
if [ -z "$workflow_blob" ]; then
  echo "::error title=crate-hashes::calling workflow file '$workflow' not tracked (workflow-file / GITHUB_WORKFLOW_REF)" >&2
  exit 1
fi

# This repo's actions and workflows, as checked out for this action.
actions=$(cd "$(dirname "$0")/../.." && find actions workflows -type f | LC_ALL=C sort | xargs -d '\n' sha256sum | sha256sum | cut -d' ' -f1)

declare -A extra
extra_all=()
while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  if [[ "$line" != *:* ]]; then
    echo "::error title=crate-hashes::extra-paths line is not \`crate: path [path...]\`: $line" >&2
    exit 1
  fi
  key=$(tr -d '[:space:]' <<< "${line%%:*}")
  read -ra paths <<< "${line#*:}"
  if [ -z "$key" ] || [ "${#paths[@]}" -eq 0 ]; then
    echo "::error title=crate-hashes::extra-paths line needs a crate and at least one path: $line" >&2
    exit 1
  fi
  for p in "${paths[@]}"; do
    if [ -z "$(git ls-files -- "$p")" ]; then
      echo "::error title=crate-hashes::extra-paths entry '$p' ($key) matches no tracked files" >&2
      exit 1
    fi
  done
  if [ "$key" = '*' ]; then
    extra_all+=("${paths[@]}")
  else
    extra[$key]="${extra[$key]:-} ${paths[*]}"
  fi
done <<< "${EXTRA_PATHS:-}"

# Literal include!/include_str!/include_bytes!, include_dir!, sqlx::migrate! and
# rust-embed #[folder] targets outside their crate's directory count as that
# crate's extra paths. include!/include_str!/include_bytes! resolve against the
# including file's dir; include_dir!, migrate! and #[folder] name a directory
# relative to the crate root. env!("OUT_DIR") paths are build outputs and skipped.
owner() {
  local best="" best_dir="" name dir
  while IFS=$'\t' read -r name dir; do
    if [ "$dir" = . ] || [[ "$1" == "$dir"/* ]]; then
      if [ -z "$best" ] || [ "${#dir}" -gt "${#best_dir}" ] || [ "$best_dir" = . ]; then
        best=$name best_dir=$dir
      fi
    fi
  done <<< "$members"
  printf '%s\t%s\n' "$best" "$best_dir"
}
embed_re='\b(include|include_str|include_bytes|include_dir|migrate)!\( *"[^"]+" *\)|#\[folder *= *"[^"]+"\]|\b(include|include_str|include_bytes|include_dir)!\( *(concat!\( *)?env!\( *"[^"]+"'
while IFS= read -r hit; do
  file=${hit%%:*}
  line=${hit#*:}
  line=${line#*:}
  [[ "$line" =~ ^[[:space:]]*// ]] && continue
  IFS=$'\t' read -r crate cdir < <(owner "$file")
  [ -n "$crate" ] || continue
  while IFS= read -r arg; do
    if [[ "$arg" == *'env!('* ]]; then
      [[ "$arg" =~ env!\(\ *\"OUT_DIR\"$ ]] && continue
      echo "::error title=crate-hashes::$file uses env!() in an include path; add an extra-paths entry instead" >&2
      exit 1
    fi
    path=$(sed -E 's/^[^"]*"([^"]+)".*$/\1/' <<< "$arg")
    base=$(dirname "$file")
    dir_arg=false
    if [[ "$arg" =~ ^(#|include_dir!|migrate!) ]]; then
      dir_arg=true
      base=$cdir
    fi
    # shellcheck disable=SC2016 # literal variable names
    for v in '${CARGO_MANIFEST_DIR}' '$CARGO_MANIFEST_DIR'; do
      if [[ "$path" == "$v"* ]]; then
        path=.${path#"$v"}
        base=$cdir
      fi
    done
    if [[ "$path" == *'$'* ]]; then
      echo "::error title=crate-hashes::$file embeds '$path' with an unresolvable variable; add an extra-paths entry instead" >&2
      exit 1
    fi
    if $dir_arg; then
      target=$(realpath -m --relative-to=. "$base/$path")
    else
      target=$(realpath -m --relative-to=. "$base/$(dirname "$path")")
    fi
    if [ "$cdir" = . ]; then
      case "$target" in ..|../*) ;; *) continue ;; esac
    elif [ "$target" = "$cdir" ] || [[ "$target" == "$cdir"/* ]]; then
      continue
    fi
    if [ -z "$(git ls-files -- "$target")" ]; then
      echo "::error title=crate-hashes::$file embeds '$path' but '$target' has no tracked files" >&2
      exit 1
    fi
    if ! $dir_arg && [ -z "$(git ls-files -- "$base/$path")" ]; then
      echo "::error title=crate-hashes::$file embeds '$path' but it is not a tracked file" >&2
      exit 1
    fi
    extra[$crate]="${extra[$crate]:-} $target"
  done < <(grep -oE "$embed_re" <<< "$line")
done < <(git grep -nE "$embed_re" -- '*.rs' || true)

common=$(
  {
    echo "image=${IMAGE:-}"
    echo "workflow=$workflow_blob"
    echo "actions=$actions"
    rustc -vV 2>/dev/null || true
    git ls-files -s -- Cargo.lock Cargo.toml ':(glob)rust-toolchain*' .cargo/config.toml
  } | sha256sum | cut -d' ' -f1
)

declare -A own
while IFS=$'\t' read -r name dir; do
  # A member nested inside another member's directory is that member's input,
  # not this one's.
  excludes=()
  while IFS=$'\t' read -r _ other; do
    if [ "$other" != "$dir" ] && { [ "$dir" = . ] || [[ "$other" == "$dir"/* ]]; }; then
      excludes+=(":(exclude)$other")
    fi
  done <<< "$members"
  read -ra mine <<< "${extra[$name]:-}"
  unset "extra[$name]"
  # Excludes apply to the crate dir only, never to its extra paths.
  own[$name]=$(
    {
      git ls-files -s -- "$dir" "${excludes[@]}"
      extras=("${extra_all[@]}" "${mine[@]}")
      [ "${#extras[@]}" -eq 0 ] || git ls-files -s -- "${extras[@]}"
    } | sha256sum | cut -d' ' -f1
  )
done <<< "$members"
for k in "${!extra[@]}"; do
  echo "::error title=crate-hashes::extra-paths names unknown crate '$k'" >&2
  exit 1
done

while IFS=$'\t' read -r name _; do
  deps=$(jq -r --arg n "$name" '.[$n][]?' <<< "$closure" | sort)
  h=$(
    {
      echo "common=$common"
      echo "own=${own[$name]}"
      while IFS= read -r d; do
        if [ -n "$d" ]; then echo "dep $d=${own[$d]}"; fi
      done <<< "$deps"
    } | sha256sum | cut -d' ' -f1
  )
  printf '%s\t%s\n' "$name" "$h"
done <<< "$members" | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries'
