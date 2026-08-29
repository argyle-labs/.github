#!/usr/bin/env bash
# Bidirectional git sync between Gitea (canonical) and GitHub (mirror).
#
# For every repo present on BOTH remotes, reconciles every branch and tag in
# both directions with a loop-safe, data-preserving policy:
#   - one side ahead        -> fast-forward the behind side
#   - branch on one side     -> create it on the other
#   - diverged branches      -> attempt a clean merge; push the merge to BOTH.
#                               On merge conflict: DO NOTHING, notify, keep going.
#   - tag only on one side    -> push to the other
#   - tag differs both sides   -> notify (tags are immutable; never overwrite)
#
# Never force-pushes, never deletes. Branch/tag deletions are intentionally NOT
# propagated (deletion loops would destroy history) — remove on both sides by
# hand. Converges to a no-op steady state, so re-running is always safe.
#
# Repos present on only one remote are REPORTED, not auto-created (creation is a
# heavier decision left to a human). Env:
#   GITEA_HOST   e.g. gitea.scottkey.me
#   GITEA_ORG    e.g. argyle-labs
#   GITEA_TOKEN  Gitea token, write on the org
#   GH_ORG       GitHub org (defaults to GITEA_ORG)
#   GH_TOKEN     GitHub PAT, repo scope
#   NTFY_URL     optional; POSTed a line per conflict/error (fail-loud)
#   ONLY_REPO    optional; sync just this one repo (debugging)
set -uo pipefail

: "${GITEA_HOST:?}"; : "${GITEA_ORG:?}"; : "${GITEA_TOKEN:?}"; : "${GH_TOKEN:?}"
GH_ORG="${GH_ORG:-$GITEA_ORG}"
NTFY_URL="${NTFY_URL:-}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CONFLICTS=0

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
# fail-loud: surface every conflict to the workflow log AND ntfy, but keep the
# run going so one bad repo never blocks the other 49.
notify() {
  CONFLICTS=$((CONFLICTS+1))
  printf '::error::%s\n' "$*"
  [ -n "$NTFY_URL" ] && curl -fsS -m 10 -H 'Title: mirror-sync conflict' \
    -d "$*" "$NTFY_URL" >/dev/null 2>&1 || true
}

# --- enumerate repos on each remote (paginated) ---
list_gitea() {
  local page=1
  while :; do
    local out; out=$(curl -fsS -H "Authorization: token $GITEA_TOKEN" \
      "https://$GITEA_HOST/api/v1/orgs/$GITEA_ORG/repos?limit=50&page=$page" 2>/dev/null) || break
    local names; names=$(printf '%s' "$out" | jq -r '.[].name')
    [ -z "$names" ] && break
    printf '%s\n' "$names"; page=$((page+1))
  done
}
list_github() {
  local page=1
  while :; do
    local out; out=$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/orgs/$GH_ORG/repos?per_page=100&page=$page" 2>/dev/null) || break
    local names; names=$(printf '%s' "$out" | jq -r '.[].name')
    [ -z "$names" ] && break
    printf '%s\n' "$names"; page=$((page+1))
  done
}

sync_repo() {
  local repo="$1"
  log "=== $repo ==="
  local dir="$WORK/$repo"
  # Bare clone from Gitea (canonical), then add GitHub as a second remote.
  if ! git clone --quiet --bare \
      "https://oauth2:$GITEA_TOKEN@$GITEA_HOST/$GITEA_ORG/$repo.git" "$dir" 2>/dev/null; then
    notify "$repo: clone from Gitea failed"; return
  fi
  git -C "$dir" remote add github \
    "https://x-access-token:$GH_TOKEN@github.com/$GH_ORG/$repo.git"
  git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/gitea/*'
  git -C "$dir" config --add remote.github.fetch '+refs/heads/*:refs/remotes/github/*'
  git -C "$dir" fetch --quiet origin  '+refs/heads/*:refs/remotes/gitea/*'  'refs/tags/*:refs/tags/gitea/*'  2>/dev/null
  if ! git -C "$dir" fetch --quiet github '+refs/heads/*:refs/remotes/github/*' 'refs/tags/*:refs/tags/github/*' 2>/dev/null; then
    notify "$repo: fetch from GitHub failed (missing repo or auth)"; return
  fi

  # ---- branches ----
  local branches
  branches=$( { git -C "$dir" for-each-ref --format='%(refname:strip=3)' refs/remotes/gitea;
                git -C "$dir" for-each-ref --format='%(refname:strip=3)' refs/remotes/github; } \
              | sort -u )
  local b gt gh
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    gt=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/gitea/$b"  || true)
    gh=$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/github/$b" || true)
    if   [ -n "$gt" ] && [ -z "$gh" ]; then
      log "  + github:$b (new from gitea)"
      git -C "$dir" push --quiet github "refs/remotes/gitea/$b:refs/heads/$b" || notify "$repo:$b push→github failed"
    elif [ -z "$gt" ] && [ -n "$gh" ]; then
      log "  + gitea:$b (new from github)"
      git -C "$dir" push --quiet origin "refs/remotes/github/$b:refs/heads/$b" || notify "$repo:$b push→gitea failed"
    elif [ "$gt" = "$gh" ]; then
      : # in sync
    elif git -C "$dir" merge-base --is-ancestor "$gh" "$gt"; then
      log "  → github:$b fast-forward (gitea ahead)"
      git -C "$dir" push --quiet github "$gt:refs/heads/$b" || notify "$repo:$b FF→github failed"
    elif git -C "$dir" merge-base --is-ancestor "$gt" "$gh"; then
      log "  → gitea:$b fast-forward (github ahead)"
      git -C "$dir" push --quiet origin "$gh:refs/heads/$b" || notify "$repo:$b FF→gitea failed"
    else
      # diverged — attempt a clean merge in a scratch worktree
      local wt="$dir-wt-$b"; rm -rf "$wt"
      git -C "$dir" worktree add --quiet --detach "$wt" "$gt" 2>/dev/null
      if git -C "$wt" merge --quiet --no-edit \
           -m "mirror-sync: reconcile $b (gitea+github)" "$gh" 2>/dev/null; then
        local merged; merged=$(git -C "$wt" rev-parse HEAD)
        log "  ⇄ $b diverged → clean merge $merged, pushing both"
        git -C "$dir" push --quiet origin "$merged:refs/heads/$b" || notify "$repo:$b merge push→gitea failed"
        git -C "$dir" push --quiet github "$merged:refs/heads/$b" || notify "$repo:$b merge push→github failed"
      else
        notify "$repo:$b DIVERGED with merge conflict — manual reconcile needed (gitea=$gt github=$gh)"
      fi
      git -C "$dir" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    fi
  done <<< "$branches"

  # ---- tags (immutable: create-only, never overwrite) ----
  local tags t tt tg
  tags=$( { git -C "$dir" for-each-ref --format='%(refname:strip=3)' refs/tags/gitea;
            git -C "$dir" for-each-ref --format='%(refname:strip=3)' refs/tags/github; } \
          | sort -u )
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    tt=$(git -C "$dir" rev-parse --verify --quiet "refs/tags/gitea/$t"  || true)
    tg=$(git -C "$dir" rev-parse --verify --quiet "refs/tags/github/$t" || true)
    if   [ -n "$tt" ] && [ -z "$tg" ]; then
      git -C "$dir" push --quiet github "$tt:refs/tags/$t" || notify "$repo: tag $t push→github failed"
    elif [ -z "$tt" ] && [ -n "$tg" ]; then
      git -C "$dir" push --quiet origin "$tg:refs/tags/$t" || notify "$repo: tag $t push→gitea failed"
    elif [ "$tt" != "$tg" ]; then
      notify "$repo: tag $t DIFFERS (gitea=$tt github=$tg) — not overwriting an immutable tag"
    fi
  done <<< "$tags"
}

main() {
  local gitea github both only_gt only_gh
  gitea=$(list_gitea | sort -u)
  github=$(list_github | sort -u)
  [ -z "$gitea" ]  && { notify "could not list Gitea repos"; exit 1; }
  [ -z "$github" ] && { notify "could not list GitHub repos"; exit 1; }
  both=$(comm -12 <(printf '%s\n' "$gitea") <(printf '%s\n' "$github"))
  only_gt=$(comm -23 <(printf '%s\n' "$gitea") <(printf '%s\n' "$github"))
  only_gh=$(comm -13 <(printf '%s\n' "$gitea") <(printf '%s\n' "$github"))
  [ -n "$only_gt" ] && warn "Gitea-only repos (not synced — create on GitHub to include): $(echo $only_gt | tr '\n' ' ')"
  [ -n "$only_gh" ] && warn "GitHub-only repos (not synced — create on Gitea to include): $(echo $only_gh | tr '\n' ' ')"

  if [ -n "${ONLY_REPO:-}" ]; then sync_repo "$ONLY_REPO"; else
    while IFS= read -r r; do [ -n "$r" ] && sync_repo "$r"; done <<< "$both"
  fi

  log "done — $CONFLICTS conflict(s)/error(s)"
  # Non-zero exit fails the workflow (red run) so conflicts are impossible to miss.
  [ "$CONFLICTS" -eq 0 ]
}
main "$@"
