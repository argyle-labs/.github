#!/usr/bin/env bash
# Prints the source hash. Run from working-directory. Env: IMAGE, EXTRA_PATHS,
# WORKFLOW_FILE (GITHUB_WORKFLOW_REF when empty), ACTIONS. Writes hash= to
# GITHUB_OUTPUT when set.
set -euo pipefail
IMAGE=${IMAGE:-}
EXTRA_PATHS=${EXTRA_PATHS:-}
WORKFLOW_FILE=${WORKFLOW_FILE:-}
ACTIONS=${ACTIONS:-}
workflow=$WORKFLOW_FILE
# GITHUB_WORKFLOW_REF is `owner/repo/<path>@<ref>`, <path> relative to
# the repo root.
if [ -z "$workflow" ] && [ -n "${GITHUB_WORKFLOW_REF:-}" ]; then
  workflow=${GITHUB_WORKFLOW_REF#"${GITHUB_REPOSITORY:-}/"}
  workflow=${workflow%%@*}
fi
if [ -z "$workflow" ] || ! git ls-files --error-unmatch -- ":(top)$workflow" >/dev/null 2>&1; then
  echo "::error title=source-hash::calling workflow file '$workflow' not tracked (workflow-file / GITHUB_WORKFLOW_REF)"
  exit 1
fi
extras=()
while IFS= read -r line; do
  read -ra ps <<< "$line"
  for p in ${ps[@]+"${ps[@]}"}; do
    if [ -z "$(git ls-files -- "$p")" ]; then
      echo "::error title=source-hash::extra-paths entry '$p' matches no tracked files"
      exit 1
    fi
    extras+=("$p")
  done
done <<< "$EXTRA_PATHS"
GITHUB_ACTION_PATH=${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")" && pwd)}
shared=$GITHUB_ACTION_PATH/../..
source "$GITHUB_ACTION_PATH/../path-utils/normpath.sh"
if [ -z "$ACTIONS" ]; then
  actions=$(cd "$shared" && find actions workflows lib -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
else
  read -ra queue <<< "$ACTIONS"
  declare -A seen=()
  while ((${#queue[@]})); do
    a=${queue[0]}
    queue=("${queue[@]:1}")
    [ -n "${seen[$a]:-}" ] && continue
    if [ ! -d "$shared/actions/$a" ]; then
      echo "::error title=source-hash::actions entry '$a' is not a shared action"
      exit 1
    fi
    seen[$a]=1
    while IFS= read -r dep; do
      queue+=("$dep")
    done < <(grep -rhoE 'argyle-labs/\.github/\.github/actions/[A-Za-z0-9_-]+@|GITHUB_ACTION_PATH}?/\.\./[A-Za-z0-9_-]+/' "$shared/actions/$a" | sed -E 's#.*actions/([^@]+)@#\1#; s#.*/\.\./([^/]+)/#\1#')
  done
  actions=$(cd "$shared/actions" && printf '%s\0' "${!seen[@]}" | LC_ALL=C sort -z | xargs -0 -I{} find {} -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
  actions=$( { echo "$actions"; cd "$shared" && find lib -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } | sha256sum | cut -d' ' -f1)
fi
specs=(
  ':(glob)**/*.rs'
  ':(glob)**/Cargo.toml'
  ':(glob)**/Cargo.lock'
  ':(glob)**/build.rs'
  ':(glob)**/rust-toolchain*'
  ':(glob)**/.cargo/config.toml'
  ':(glob)**/rustfmt.toml'
  ':(glob)**/.rustfmt.toml'
  ':(glob)**/clippy.toml'
  ':(glob)**/.clippy.toml'
  ':(top)size-budget.toml'
  ':(glob)**/tests/**'
  ":(top)$workflow"
  ${extras[@]+"${extras[@]}"}
)
# Literal include_str!/include_bytes! targets resolve against the
# including file's dir, rust-embed #[folder] against the crate dir;
# hash the directory each one lives in.
crate_dir() {
  local d
  d=$(dirname "$1")
  until [ -n "$(git ls-files -- "$d/Cargo.toml")" ] || [ "$d" = . ]; do
    d=$(dirname "$d")
  done
  echo "$d"
}
embed_re='include_(str|bytes)!\("[^"]+"\)|#\[folder *= *"[^"]+"\]|include_(str|bytes)!\( *(concat!\( *)?env!\( *"[^"]+"'
while IFS= read -r hit; do
  file=${hit%%:*}
  line=${hit#*:}
  line=${line#*:}
  [[ "$line" =~ ^[[:space:]]*// ]] && continue
  while IFS= read -r arg; do
    if [[ "$arg" == *'env!('* ]]; then
      if [[ "$arg" =~ env!\(\ *\"OUT_DIR\"$ ]] && ((${#extras[@]})); then
        continue
      fi
      echo "::error title=source-hash::$file uses env!() in an include path; OUT_DIR includes need extra-paths naming the build script's inputs, other variables an extra-paths entry for the included files"
      exit 1
    fi
    path=$(sed -E 's/^[^"]*"([^"]+)".*$/\1/' <<< "$arg")
    base=$(dirname "$file")
    [[ "$arg" == '#'* ]] && base=$(crate_dir "$file")
    # shellcheck disable=SC2016 # literal variable names
    for v in '${CARGO_MANIFEST_DIR}' '$CARGO_MANIFEST_DIR'; do
      if [[ "$path" == "$v"* ]]; then
        path=.${path#"$v"}
        base=$(crate_dir "$file")
      fi
    done
    if [[ "$path" == *'$'* ]]; then
      echo "::error title=source-hash::$file includes '$path' with an unresolvable variable; add an extra-paths entry instead"
      exit 1
    fi
    if [[ "$arg" == '#'* ]]; then
      dir=$(normpath "$base/$path")
    else
      dir=$(normpath "$base/$(dirname "$path")")
    fi
    case "$dir" in
      ..|../*)
        echo "::error title=source-hash::$file includes '$path', outside working-directory; move it in or widen working-directory"
        exit 1 ;;
    esac
    if [ -z "$(git ls-files -- "$dir")" ]; then
      echo "::error title=source-hash::$file includes '$path' but '$dir' has no tracked files"
      exit 1
    fi
    specs+=("$dir")
  done < <(grep -oE "$embed_re" <<< "$line")
done < <(git grep -nE "$embed_re" -- '*.rs' || true)
hash=$(
  {
    echo "image=$IMAGE"
    echo "actions=$actions"
    rustc -vV 2>/dev/null || true
    printf '%s\0' ${specs[@]+"${specs[@]}"} | sort -zu | xargs -0 git ls-files -s --
  } | sha256sum | cut -d' ' -f1
)
[ -z "${GITHUB_OUTPUT:-}" ] || echo "hash=$hash" >> "$GITHUB_OUTPUT"
echo "$hash"
