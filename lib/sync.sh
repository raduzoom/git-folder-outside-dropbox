# sync: make this Mac's git data right for one project (rebuild a missing store).

# Print "<project>: <message>" for a registered project.
sync__say() {
  local id="$1" rel
  shift
  rel="$(db_path "$id")" || exit 1
  echo "$(gs_display "$rel"): $*"
}

# Trash the half-built folder, then print the failure message and return 1.
sync__fail_build() {
  local id="$1" build="$2"
  shift 2
  if [ -e "$build" ]; then
    "$GIT_SYNC_TRASH" "$build" || gs_die "cannot move $build to the Trash; remove it by hand"
  fi
  sync__say "$id" "$*"
  return 1
}

# Print the unpushed-work warning for another Mac's record, if there is one.
sync__warn_other() {
  local id="$1" abs="$2" note
  note="$(repo_other_mac_note "$id" "$abs" fetched)" || exit 1
  [ -z "$note" ] || sync__say "$id" "WARNING: $note. Push from there before committing here."
  return 0
}

# sync__fetch_remotes <remotes text> <git prefix...>: fetch origin (required), then the other remotes.
# Sets SYNC_ORIGIN (origin url), SYNC_ERR (git's last stderr line when origin fails) and SYNC_WARN
# ("; could not reach <name> (<url>)" per failed secondary, with git's last line when there is one).
sync__fetch_remotes() {
  local remotes="$1" name url tab
  shift
  tab="$(printf '\t')"
  SYNC_ORIGIN=""
  SYNC_WARN=""
  SYNC_ERR=""
  while IFS="$tab" read -r name url; do
    [ "$name" = origin ] && SYNC_ORIGIN="$url"
  done <<EOF2
$remotes
EOF2
  if ! gs_fetch origin "$@"; then
    SYNC_ERR="$GS_FETCH_ERR"
    [ -n "$SYNC_ORIGIN" ] || SYNC_ORIGIN="the remote"
    return 1
  fi
  while IFS="$tab" read -r name url; do
    { [ -n "$name" ] && [ "$name" != origin ]; } || continue
    if ! gs_fetch "$name" "$@"; then
      SYNC_WARN="$SYNC_WARN; could not reach $name ($url)${GS_FETCH_ERR:+: $GS_FETCH_ERR}"
    fi
  done <<EOF2
$remotes
EOF2
  return 0
}

# Rebuild the store for <id> from the remotes in the database. No working file is touched.
sync_rebuild() {
  local id="$1" abs="$2" store build remotes line name url origin="" tab branch="" other ref warn="" now_branch now_head tree
  tab="$(printf '\t')"
  store="$(gs_store_for "$id")" || return 1
  build="$(gs_home)/repos/.building-$id.git"
  remotes="$(db_remotes "$id")" || exit 1
  while IFS="$tab" read -r name url; do
    [ "$name" = origin ] && origin="$url"
  done <<EOF2
$remotes
EOF2
  if [ -z "$origin" ]; then
    sync__say "$id" "nothing to rebuild from: no remote in the database"
    return 1
  fi
  mkdir -p "$(gs_home)/repos" || gs_die "cannot create $(gs_home)/repos"
  if [ -e "$build" ]; then
    "$GIT_SYNC_TRASH" "$build" || gs_die "cannot move the leftover $build to the Trash"
  fi
  if ! { git init -q --bare "$build" >/dev/null 2>&1 && git --git-dir="$build" config core.bare false; }; then
    sync__fail_build "$id" "$build" "cannot create the store"
    return 1
  fi
  while IFS="$tab" read -r name url; do
    [ -n "$name" ] || continue
    if ! git --git-dir="$build" remote add "$name" "$url" >/dev/null 2>&1; then
      sync__fail_build "$id" "$build" "cannot add remote $name"
      return 1
    fi
  done <<EOF2
$remotes
EOF2
  sync__say "$id" "fetching $origin…" >&2
  if ! sync__fetch_remotes "$remotes" git --git-dir="$build"; then
    sync__fail_build "$id" "$build" "cannot reach $origin${SYNC_ERR:+: $SYNC_ERR}"
    return 1
  fi
  warn="$SYNC_WARN"
  other="$(state_latest_other "$id")" || exit 1
  if [ -n "$other" ]; then
    branch="$(gs__field "$other" 2)"
    if [ -n "$branch" ] && ! git --git-dir="$build" show-ref --verify -q "refs/remotes/origin/$branch"; then
      branch=""
    fi
  fi
  if [ -z "$branch" ]; then
    git --git-dir="$build" remote set-head origin --auto >/dev/null 2>&1
    ref="$(git --git-dir="$build" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"
    branch="${ref#refs/remotes/origin/}"
    [ "$branch" != "$ref" ] || branch=""
  fi
  if [ -z "$branch" ] && git --git-dir="$build" show-ref --verify -q refs/remotes/origin/main; then
    branch=main
  fi
  if [ -z "$branch" ] || ! git --git-dir="$build" show-ref --verify -q "refs/remotes/origin/$branch"; then
    sync__fail_build "$id" "$build" "nothing to rebuild from: the remote has no branches"
    return 1
  fi
  if ! { git --git-dir="$build" update-ref "refs/heads/$branch" "refs/remotes/origin/$branch" && git --git-dir="$build" symbolic-ref HEAD "refs/heads/$branch"; }; then
    sync__fail_build "$id" "$build" "cannot point $branch at origin/$branch"
    return 1
  fi
  # Index and upstream are made in the build folder, so nothing can fail after the mv except the pointer.
  if ! git --git-dir="$build" --work-tree="$abs" reset -q >/dev/null 2>&1; then
    sync__fail_build "$id" "$build" "cannot read the project files into the new store"
    return 1
  fi
  tree="$(git --git-dir="$build" ls-tree -r --name-only HEAD 2>/dev/null | head -n 1)"
  if [ -n "$tree" ] && [ -z "$(git --git-dir="$build" ls-files 2>/dev/null | head -n 1)" ]; then
    sync__fail_build "$id" "$build" "the new store has no index"
    return 1
  fi
  if ! { git --git-dir="$build" config "branch.$branch.remote" origin && git --git-dir="$build" config "branch.$branch.merge" "refs/heads/$branch"; }; then
    sync__fail_build "$id" "$build" "cannot set the upstream of $branch"
    return 1
  fi
  if ! mv "$build" "$store"; then
    sync__fail_build "$id" "$build" "cannot move the new store into place"
    return 1
  fi
  if [ ! -e "$abs/.git" ] && [ ! -L "$abs/.git" ]; then
    if ! add__write_pointer "$abs" "$store"; then
      "$GIT_SYNC_TRASH" "$store" || true
      sync__say "$id" "cannot write the .git pointer; nothing was changed"
      return 1
    fi
  fi
  now_branch="$(repo_branch "$abs")"
  now_head="$(repo_head "$abs")"
  sync__warn_other "$id" "$abs"
  if ! (state_record "$id" "$now_branch" "$now_head"); then
    sync__say "$id" "rebuilt on $branch$warn"
    sync__say "$id" "could not write this Mac's state file"
    return 1
  fi
  sync__say "$id" "rebuilt on $branch$warn"
  return 0
}

# Move refs/heads/<b> from <old> to <new>; an empty <old> means the branch must not exist yet.
sync__move_ref() {
  local abs="$1" b="$2" new="$3" old="$4"
  [ -n "$old" ] || old="$(printf '%040d' 0)"
  git -C "$abs" --no-optional-locks update-ref "refs/heads/$b" "$new" "$old" >/dev/null 2>&1
}

# Follow the other Mac's branch when it is safe. Prints the message part (if any) on stdout; return 1 on failure.
# sync__follow <abs> <branch> <Mac name>
sync__follow() {
  local abs="$1" ob="$2" oname="$3" new old
  new="$(gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$ob")" || return 1
  old="$(gs__git "$abs" rev-parse --verify -q "refs/heads/$ob")"
  if [ -n "$old" ] && ! gs__git "$abs" merge-base --is-ancestor "$old" "$new"; then
    echo "not switching to $ob: local $ob has commits not on the remote"
    return 0
  fi
  sync__move_ref "$abs" "$ob" "$new" "$old" || return 1
  if git -C "$abs" symbolic-ref HEAD "refs/heads/$ob" >/dev/null 2>&1 \
    && git -C "$abs" reset -q >/dev/null 2>&1 \
    && git -C "$abs" branch --set-upstream-to="origin/$ob" "$ob" >/dev/null 2>&1; then
    echo "switched to $ob (as on $oname)"
    return 0
  fi
  return 1
}

# Catch this Mac's branch up with the remote without touching a working file.
sync_catch_up() {
  local id="$1" abs="$2" remotes store msg="" b other own oat oname obranch ohead nat ahead behind part new old rc head
  store="$(gs_store_for "$id")" || return 1
  if [ ! -e "$abs/.git" ] && [ ! -L "$abs/.git" ]; then
    if ! add__write_pointer "$abs" "$store"; then
      sync__say "$id" "cannot write the .git pointer; nothing was changed"
      return 1
    fi
  fi
  remotes="$(db_remotes "$id")" || exit 1
  if ! sync__fetch_remotes "$remotes" git -C "$abs"; then
    sync__say "$id" "cannot reach $SYNC_ORIGIN${SYNC_ERR:+: $SYNC_ERR}"
    return 1
  fi
  msg="${SYNC_WARN#; }"
  status__remotes_differ "$abs" "$id"
  rc=$?
  if [ "$rc" = 2 ]; then
    sync__say "$id" "cannot read the remotes from the database"
    return 1
  elif [ "$rc" = 0 ]; then
    msg="${msg:+$msg; }remote differs from database"
  fi
  sync__warn_other "$id" "$abs"
  b="$(repo_branch "$abs")" || return 1
  if [ "$b" = "(detached)" ]; then
    sync__say "$id" "${msg:+$msg; }detached HEAD; nothing changed"
    return 0
  fi
  other="$(state_latest_other "$id")" || exit 1
  if [ -n "$other" ]; then
    oname="$(gs__field "$other" 1)"
    obranch="$(gs__field "$other" 2)"
    ohead="$(gs__field "$other" 3)"
    oat="$(gs__field "$other" 4)"
    own="$(state_own "$id")" || exit 1
    nat=""
    [ -z "$own" ] || nat="$(gs__field "$own" 3)"
    if [ -n "$obranch" ] && [ "$obranch" != "(detached)" ] && [ "$obranch" != "$b" ] && [ -n "$ohead" ] \
      && { [ -z "$nat" ] || [[ "$oat" > "$nat" ]]; } \
      && gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$obranch" >/dev/null \
      && repo_commit_on_remote "$abs" "$ohead" && [ "$(repo_ahead "$abs")" = 0 ]; then
      if ! part="$(sync__follow "$abs" "$obranch" "$oname")"; then
        sync__say "$id" "${msg:+$msg; }cannot switch to $obranch"
        return 1
      fi
      msg="${msg:+$msg; }$part"
      case "$part" in switched*) b="$obranch" ;; esac
    fi
  fi
  if ! gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null; then
    msg="${msg:+$msg; }branch $b is not on the remote"
  else
    ahead="$(repo_ahead "$abs")" || return 1
    behind="$(repo_behind "$abs")" || return 1
    if [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then
      msg="${msg:+$msg; }up to date"
    elif [ "$ahead" = 0 ]; then
      new="$(gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$b")" || return 1
      old="$(repo_head "$abs")"
      if sync__move_ref "$abs" "$b" "$new" "$old" && git -C "$abs" reset -q >/dev/null 2>&1; then
        msg="${msg:+$msg; }moved forward $behind commits"
      else
        sync__say "$id" "${msg:+$msg; }cannot move $b forward"
        return 1
      fi
    elif [ "$behind" = 0 ]; then
      msg="${msg:+$msg; }$ahead unpushed commits"
    else
      msg="${msg:+$msg; }diverged: $ahead ahead, $behind behind; nothing changed"
    fi
  fi
  head="$(repo_head "$abs")"
  if [ -n "$head" ] && ! state_record "$id" "$(repo_branch "$abs")" "$head"; then
    sync__say "$id" "${msg:+$msg; }could not write this Mac's state file"
    return 1
  fi
  sync__say "$id" "$msg"
  return 0
}

sync_one() {
  local id="$1" rel abs kind store
  rel="$(db_path "$id")" || exit 1
  [ -n "$rel" ] || gs_die "not registered: $id"
  abs="$(gs_abs_path "$rel")" || exit 1
  kind="$(repo_kind "$abs" "$id")" || exit 1
  store="$(gs_store_for "$id")" || exit 1
  case "$kind" in
    missing)
      sync__say "$id" "skipped: folder is not on this Mac"
      return 0
      ;;
    foreign)
      sync__say "$id" ".git points somewhere else"
      return 1
      ;;
    folder)
      if [ "$(repo_here "$abs" "$id")" = unprotected ]; then
        sync__say "$id" "unprotected (no pushed remote); nothing to sync"
        return 0
      fi
      sync__say "$id" "still a normal .git folder on this Mac; run: git-sync add $(add__shquote "$abs")"
      return 0
      ;;
  esac
  if [ ! -d "$store" ]; then
    sync_rebuild "$id" "$abs"
    return $?
  fi
  sync_catch_up "$id" "$abs"
}

cmd_sync() {
  local rel id
  [ "$#" = 1 ] || gs_die "usage: git-sync sync <path>"
  db__check || exit 1
  rel="$(gs_rel_path "$1")" || exit 1
  if ! id="$(db_id_by_path "$rel")"; then
    gs_die "not registered; run: git-sync add $(add__shquote "$1")"
  fi
  sync_one "$id"
}

# Print the absolute path of a registered project that is still a normal .git folder with a
# pushed remote on this Mac (the ones sync_one tells to run `git-sync add`); print nothing otherwise.
sync__needs_add() {
  local id="$1" rel abs kind here
  rel="$(db_path "$id")" || exit 1
  [ -n "$rel" ] || return 0
  abs="$(gs_abs_path "$rel")" || exit 1
  kind="$(repo_kind "$abs" "$id")" || exit 1
  [ "$kind" = folder ] || return 0
  here="$(repo_here "$abs" "$id")" || exit 1
  [ "$here" = unprotected ] && return 0
  echo "$abs"
}

cmd_sync_all() {
  local ids id failed=0 path to_add=""
  [ "$#" = 0 ] || gs_die "usage: git-sync sync-all"
  db__check || exit 1
  ids="$(db_ids)" || exit 1
  if [ -z "$ids" ]; then
    echo "no projects in the database"
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      (sync_one "$id") || failed=$((failed + 1))
      path="$(sync__needs_add "$id")" || path=""
      [ -n "$path" ] && to_add="$to_add$GS_ROOT/git-sync add $(add__shquote "$path")
"
    done <<EOF2
$ids
EOF2
  fi
  echo
  (cmd_status) || failed=$((failed + 1))
  if [ -n "$to_add" ]; then
    echo
    echo "Still a normal .git folder on this Mac; to convert, run:"
    printf '%s' "$to_add"
  fi
  if [ "$failed" -gt 0 ]; then
    echo "$failed projects failed"
    return 1
  fi
  return 0
}
