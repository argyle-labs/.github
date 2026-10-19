#!/usr/bin/env bash
# Prints `true` when a library target in the cargo package selection in "$@"
# may have a doctest, `false` otherwise. Exit 2 when a -p name is not a
# workspace member; any other nonzero exit = error.
# Scans only *.rs under each lib target's directory: modules pulled in via
# #[path] from outside it, and docs from include!/include_str! of OUT_DIR
# (build-script output), are not seen.
set -euo pipefail

args=("$@")
pkgs=()
excludes=()
workspace=false
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -p|--package|--exclude)
      if ((i + 1 >= ${#args[@]})); then
        echo "has-doctests: ${args[i]} needs a value" >&2
        exit 2
      fi
      if [[ ${args[i]} == --exclude ]]; then excludes+=("${args[i+1]}"); else pkgs+=("${args[i+1]}"); fi
      i=$((i + 1)) ;;
    --package=*) pkgs+=("${args[i]#--package=}") ;;
    --exclude=*) excludes+=("${args[i]#--exclude=}") ;;
    -p*) pkgs+=("${args[i]#-p}") ;;
    --workspace|--all) workspace=true ;;
  esac
done

# Cargo's selection: -p wins; else --workspace minus --exclude; else default members.
if ((${#pkgs[@]})); then
  mode=packages
elif $workspace; then
  mode=workspace
else
  mode=default
fi

srcs=$(mktemp)
trap 'rm -f "$srcs"' EXIT
meta=$(cargo metadata --locked --format-version 1 --no-deps)
jq -r --arg mode "$mode" \
      --argjson pkgs "$(jq -nc '$ARGS.positional' --args ${pkgs[@]+"${pkgs[@]}"})" \
      --argjson excl "$(jq -nc '$ARGS.positional' --args ${excludes[@]+"${excludes[@]}"})" '
  (if $mode == "default" then (.workspace_default_members // .workspace_members) else .workspace_members end) as $m
  | [.packages[]
     | select(.id as $id | $m | any(.[]; . == $id))] as $ws
  | if $mode == "packages" then
      ([$pkgs[] | . as $n | select($ws | any(.[]; .name == $n) | not)]) as $missing
      | if ($missing | length) > 0 then error("not workspace members: \($missing | join(", "))") else . end
    else . end
  | [$ws[]
     | select(if $mode == "packages" then (.name as $n | $pkgs | any(.[]; . == $n)) else (.name as $n | $excl | any(.[]; . == $n) | not) end)]
  | .[].targets[]
  | select(any(.kind[]; . == "lib" or . == "rlib" or . == "dylib" or . == "proc-macro"))
  | .src_path' <<< "$meta" > "$srcs" \
  || { rc=$?; echo "has-doctests: package selection failed" >&2; exit $((rc == 5 ? 2 : rc)); }

pattern='^[[:space:]]*//[/!].*(```|~~~)|^[[:space:]]*//[/!] {5,}[^[:space:]]|/\*[*!]([^*/]|$)|doc *= *include_str!|#!?\[doc *= *"'
while IFS= read -r src; do
  rc=0
  grep -rqE --include='*.rs' -- "$pattern" "$(dirname "$src")" || rc=$?
  case $rc in
    0) echo true; exit 0 ;;
    1) ;;
    *) echo "has-doctests: grep failed ($rc) under $(dirname "$src")" >&2; exit "$rc" ;;
  esac
done < "$srcs"
echo false
