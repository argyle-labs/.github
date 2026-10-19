#!/bin/bash
normpath() {
  local part parts segs=()
  IFS=/ read -ra parts <<< "$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) if [ "${#segs[@]}" -gt 0 ] && [ "${segs[${#segs[@]}-1]}" != .. ]; then unset 'segs[${#segs[@]}-1]'; else segs+=(..); fi ;;
      *) segs+=("$part") ;;
    esac
  done
  if [ "${#segs[@]}" -eq 0 ]; then echo .; else (IFS=/; echo "${segs[*]}"); fi
}
