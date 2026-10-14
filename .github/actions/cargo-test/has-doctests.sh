#!/usr/bin/env bash
# Prints `true` when the cargo package selection in "$@" has a library target
# (rustdoc needs one), `false` when it is binary-only. Nonzero exit = error.
set -euo pipefail

args=("$@")
pkgs=()
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -p|--package) pkgs+=("${args[i+1]}") ;;
    --package=*) pkgs+=("${args[i]#--package=}") ;;
  esac
done
meta=$(cargo metadata --locked --format-version 1 --no-deps)
jq -r --args '(if $ARGS.positional == [] then null else $ARGS.positional end) as $sel
      | [.workspace_members as $m | .packages[]
         | select(.id as $id | $m | index($id))
         | select($sel == null or (.name as $n | $sel | index($n)))]
      | length == 0 or any(.[].targets[].kind[]; . == "lib" or . == "rlib" or . == "dylib" or . == "proc-macro")' "${pkgs[@]}" <<< "$meta"
