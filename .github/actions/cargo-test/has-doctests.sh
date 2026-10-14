#!/usr/bin/env bash
# Prints `true` when the cargo package selection in "$@" has a library target
# (rustdoc needs one), `false` when it is binary-only or empty. Exit 2 when a
# -p name is not a workspace member; any other nonzero exit = error.
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

meta=$(cargo metadata --locked --format-version 1 --no-deps)
jq -r --arg mode "$mode" \
      --argjson pkgs "$(jq -nc '$ARGS.positional' --args "${pkgs[@]}")" \
      --argjson excl "$(jq -nc '$ARGS.positional' --args "${excludes[@]}")" '
  (if $mode == "default" then (.workspace_default_members // .workspace_members) else .workspace_members end) as $m
  | [.packages[]
     | select(.id as $id | $m | any(.[]; . == $id))] as $ws
  | if $mode == "packages" then
      ([$pkgs[] | . as $n | select($ws | any(.[]; .name == $n) | not)]) as $missing
      | if ($missing | length) > 0 then error("not workspace members: \($missing | join(", "))") else . end
    else . end
  | [$ws[]
     | select(if $mode == "packages" then (.name as $n | $pkgs | any(.[]; . == $n)) else (.name as $n | $excl | any(.[]; . == $n) | not) end)]
  | any(.[].targets[].kind[]; . == "lib" or . == "rlib" or . == "dylib" or . == "proc-macro")' <<< "$meta" \
  || { rc=$?; echo "has-doctests: package selection failed" >&2; exit $((rc == 5 ? 2 : rc)); }
