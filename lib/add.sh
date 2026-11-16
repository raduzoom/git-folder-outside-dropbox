# add: register a project, run the safety gate, leave unprotected repos alone.

# Print this repo's remotes as a JSON object {name: url}.
add_remotes_json() {
  local abs="$1" obj='{}' lines n u tab
  tab="$(printf '\t')"
  lines="$(status__git_remotes "$abs")" || return 1
  if [ -n "$lines" ]; then
    while IFS="$tab" read -r n u; do
      obj="$(jq -n --argjson o "$obj" --arg k "$n" --arg v "$u" '$o + {($k): $v}')" || return 1
    done <<EOF2
$lines
EOF2
  fi
  printf '%s\n' "$obj"
}

# Print one reason per line; return 1 if there is any.
add_gate() {
  local abs="$1" lines b n found=0 tab
  tab="$(printf '\t')"
  lines="$(repo_unpushed_branches "$abs")" || return 1
  if [ -n "$lines" ]; then
    while IFS="$tab" read -r b n; do
      echo "unpushed commits on $b: $n"
      found=1
    done <<EOF2
$lines
EOF2
  fi
  lines="$(repo_local_only_branches "$abs")" || return 1
  if [ -n "$lines" ]; then
    while IFS= read -r b; do
      echo "branch not on the remote: $b"
      found=1
    done <<EOF2
$lines
EOF2
  fi
  n="$(repo_stashes "$abs")" || return 1
  if [ "$n" -gt 0 ]; then
    echo "$n stashes"
    found=1
  fi
  [ "$found" = 0 ]
}

# Quote a path for pasting into a shell: bare when safe, else single-quoted.
add__shquote() {
  case "$1" in
    *[!A-Za-z0-9_./-]*) printf "'%s'\n" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Trash every "conflicted copy" inside .git. Refuse (return 2, nothing removed) if a conflicted
# ref file holds a commit that is not on any remote: that is unpushed work from another Mac.
add_clear_conflicted() {
  local abs="$1" gd copies p rel sha bad=0
  gd="$abs/.git"
  copies="$(repo_conflicted_copies "$abs")" || return 1
  [ -n "$copies" ] || return 0
  while IFS= read -r p; do
    rel="${p#"$gd"/}"
    case "$rel" in
      refs/*)
        [ -f "$p" ] || continue
        sha="$(head -n 1 "$p" 2>/dev/null)"
        if printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40,64}$' && repo_commit_on_remote "$abs" "$sha"; then
          :
        else
          echo "$ADD__MSG: $p (${sha:0:7})"
          bad=1
        fi
        ;;
    esac
  done <<EOF2
$copies
EOF2
  [ "$bad" = 0 ] || return 2
  while IFS= read -r p; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    echo "removing conflicted copy: ${p#"$gd"/}"
    "$GIT_SYNC_TRASH" "$p" || return 1
  done <<EOF2
$copies
EOF2
  return 0
}

# Undo a conversion: pointer out, store back as <abs>/.git. Dies with both paths if that fails.
add__rollback() {
  local abs="$1" store="$2"
  if [ -e "$abs/.git" ] || [ -L "$abs/.git" ]; then
    "$GIT_SYNC_TRASH" "$abs/.git" || gs_die "rollback failed: first trash the pointer $(add__shquote "$abs/.git"), then run: mv $(add__shquote "$store") $(add__shquote "$abs/.git")"
  fi
  mv "$store" "$abs/.git" || gs_die "rollback failed: run: mv $(add__shquote "$store") $(add__shquote "$abs/.git")"
}

# Write the one-line pointer <abs>/.git -> store through a temp file and mv. <abs>/.git must not exist.
add__write_pointer() {
  local abs="$1" store="$2" tmp
  tmp="$abs/.git-sync-pointer.$$"
  if ! { printf 'gitdir: %s\n' "$store" > "$tmp" && mv "$tmp" "$abs/.git"; }; then
    [ ! -e "$tmp" ] || "$GIT_SYNC_TRASH" "$tmp" || true
    return 1
  fi
  return 0
}

# Move <abs>/.git to the store and write the pointer. On any failure after the move, roll back.
add_convert() {
  local abs="$1" id="$2" store head tmp now
  store="$(gs_store_for "$id")" || return 1
  head="$(repo_head "$abs")" || return 1
  if [ -e "$store" ] || [ -L "$store" ]; then
    echo "git-sync: store already exists: $store" >&2
    return 1
  fi
  mkdir -p "$(dirname "$store")" || return 1
  if ! mv "$abs/.git" "$store"; then
    # A cross-device move may have left a partial copy; the store did not exist before.
    if [ -d "$abs/.git" ]; then
      if [ -e "$store" ]; then "$GIT_SYNC_TRASH" "$store" || gs_die "move failed; partial copy left at $store (original intact at $abs/.git)"; fi
    elif [ -e "$store" ]; then
      mv "$store" "$abs/.git" || gs_die "rollback failed: run: mv $(add__shquote "$store") $(add__shquote "$abs/.git")"
    fi
    return 1
  fi
  if ! add__write_pointer "$abs" "$store"; then
    add__rollback "$abs" "$store"
    return 1
  fi
  now="$(repo_head "$abs")"
  if [ "$now" != "$head" ] || ! git -C "$abs" --no-optional-locks status >/dev/null 2>&1; then
    add__rollback "$abs" "$store"
    return 1
  fi
  return 0
}

# Conflicted copies of ref files can break git's fetch, and they may hold unpushed work. Before
# the fetch they are moved out of .git into $(gs_home)/tmp/add-<id>; afterwards they are either
# checked and trashed, or moved back. State lives in these globals so an EXIT trap can restore.
ADD__TMP=""
ADD__GD=""
ADD__LIST=""

# Move every ref-like conflicted copy (refs/..., packed-refs...) aside, keeping relative paths.
add__aside() {
  local abs="$1" id="$2" gd copies p rel dest
  gd="$abs/.git"
  copies="$(repo_conflicted_copies "$abs")" || return 1
  [ -n "$copies" ] || return 0
  ADD__TMP="$(gs_home)/tmp/add-$id"
  ADD__GD="$gd"
  ADD__LIST=""
  if [ -d "$ADD__TMP" ] && [ -n "$(find "$ADD__TMP" -mindepth 1 ! -type d 2>/dev/null | head -n 1)" ]; then
    echo "git-sync: leftover files from an interrupted add are in '$ADD__TMP'; move them back into '$gd' or trash them" >&2
    return 1
  fi
  while IFS= read -r p; do
    rel="${p#"$gd"/}"
    case "$rel" in
      refs/*|packed-refs*) ;;
      *) continue ;;
    esac
    [ -e "$p" ] || [ -L "$p" ] || continue
    dest="$ADD__TMP/$rel"
    if ! { mkdir -p "$(dirname "$dest")" && mv "$p" "$dest"; }; then
      add__restore
      return 1
    fi
    ADD__LIST="$ADD__LIST$rel
"
    trap add__restore EXIT
  done <<EOF2
$copies
EOF2
  return 0
}

# Move every aside copy back. Idempotent; dies naming both paths if a move fails.
add__restore() {
  local rel list="$ADD__LIST"
  trap - EXIT
  [ -n "$list" ] || return 0
  ADD__LIST=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! { mkdir -p "$(dirname "$ADD__GD/$rel")" && mv "$ADD__TMP/$rel" "$ADD__GD/$rel"; }; then
      gs_die "cannot move '$ADD__TMP/$rel' back to '$ADD__GD/$rel'; move it back by hand"
    fi
  done <<EOF2
$list
EOF2
  return 0
}

# The check applied to each commit id found in the aside copies; the stray-folder check swaps it.
ADD__SHA_OK=add__sha_on_remote
ADD__MSG="unpushed work from another Mac"
ADD__STORE=""

# Is $1 a commit id that this Mac's store ($ADD__STORE) holds?
add__sha_in_store() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40,64}$' && git --git-dir="$ADD__STORE" cat-file -e "$1^{commit}" 2>/dev/null
}

# Is $2 a commit id that the git dir $1 holds?
add__sha_in_store_of() {
  printf '%s' "$2" | grep -Eq '^[0-9a-f]{40,64}$' && git --git-dir="$1" cat-file -e "$2^{commit}" 2>/dev/null
}

# Is $1 a commit id that some remote-tracking ref contains?
add__sha_on_remote() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40,64}$' && repo_commit_on_remote "$2" "$1"
}

# Check the commits held by the aside copies. Print one line per unpushed one; return 2 if any.
add__check_aside() {
  local abs="$1" rel m sha line ref bad=0 list="$ADD__LIST"
  [ -n "$list" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    m="$ADD__TMP/$rel"
    case "$rel" in
      refs/remotes/*) continue ;;
    esac
    if [ -L "$m" ] || [ ! -f "$m" ]; then
      echo "$ADD__MSG: $ADD__GD/$rel (not a plain file)"
      bad=1
      continue
    fi
    case "$rel" in
      packed-refs*)
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            ""|"#"*|"^"*) continue ;;
          esac
          sha="${line%% *}"
          ref="${line#* }"
          case "$ref" in refs/remotes/*) continue ;; esac
          if ! "$ADD__SHA_OK" "$sha" "$abs"; then
            echo "$ADD__MSG: $ADD__GD/$rel (${sha:0:7})"
            bad=1
          fi
        done < "$m"
        ;;
      *)
        sha="$(head -n 1 "$m" 2>/dev/null)"
        if ! "$ADD__SHA_OK" "$sha" "$abs"; then
          echo "$ADD__MSG: $ADD__GD/$rel (${sha:0:7})"
          bad=1
        fi
        ;;
    esac
  done <<EOF2
$list
EOF2
  [ "$bad" = 0 ] || return 2
  return 0
}

# Trash every aside copy (they are all pushed, or only cache remote state).
add__trash_aside() {
  local rel list="$ADD__LIST"
  trap - EXIT
  [ -n "$list" ] || return 0
  ADD__LIST=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    echo "removing conflicted copy: $rel"
    "$GIT_SYNC_TRASH" "$ADD__TMP/$rel" || gs_die "cannot trash '$ADD__TMP/$rel'"
  done <<EOF2
$list
EOF2
  return 0
}

# Re-adding a converted project: publish this Mac's remotes and record where it stands.
add__readd_pointer() {
  local abs="$1" id="$2" rel="$3" remotes head branch existing
  existing="$(db_path "$id")" || exit 1
  [ -n "$existing" ] || existing="$rel"
  remotes="$(add_remotes_json "$abs")" || exit 1
  db_put "$id" "$existing" "$remotes" || exit 1
  head="$(repo_head "$abs")" || exit 1
  if [ -n "$head" ]; then
    branch="$(repo_branch "$abs")" || exit 1
    state_record "$id" "$branch" "$head" || exit 1
  fi
  echo "$(gs_display "$rel"): already converted; database updated"
}

# A .git folder next to this Mac's store is a leftover Dropbox brought back. Trash it and write
# the pointer, but only when the store has everything the folder holds. Fails closed: anything
# unreadable, or any ref or conflicted copy whose commit the store lacks, refuses (rc 2).
add__stray_folder() {
  local abs="$1" id="$2" rel="$3" existing="$4" store gd sha ref refs missing="" remotes head branch copies p crel list="" out rc headbad=""
  store="$(gs_store_for "$id")" || exit 1
  gd="$abs/.git"
  if ! git --git-dir="$gd" rev-parse --git-dir >/dev/null 2>&1; then
    echo "refused: the .git folder is not readable as a git repo; nothing changed"
    return 2
  fi
  if git --git-dir="$gd" symbolic-ref -q HEAD >/dev/null 2>&1 && ! git --git-dir="$gd" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    :
  else
    sha="$(git --git-dir="$gd" rev-parse --verify -q "HEAD^{commit}" 2>/dev/null)"
    if [ -z "$sha" ] || ! git --git-dir="$store" cat-file -e "$sha^{commit}" 2>/dev/null; then
      missing="HEAD"
    fi
  fi
  # git skips a broken ref with only a warning on stderr: merge stderr in and treat any line that
  # is not a ref name as a problem.
  if ! refs="$(git --git-dir="$gd" for-each-ref --format='%(refname)' 2>&1)"; then
    echo "refused: the .git folder has a broken ref: $(printf '%s' "$refs" | head -n 1); nothing changed"
    return 2
  fi
  if [ -n "$(printf '%s\n' "$refs" | grep -v '^refs/')" ]; then
    echo "refused: the .git folder has a broken ref: $(printf '%s\n' "$refs" | grep -v '^refs/' | head -n 1); nothing changed"
    return 2
  fi
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      case "$ref" in refs/remotes/*) continue ;; esac
      sha="$(git --git-dir="$gd" rev-parse --verify -q "$ref^{commit}" 2>/dev/null)"
      if [ -z "$sha" ] || ! git --git-dir="$store" cat-file -e "$sha^{commit}" 2>/dev/null; then
        if [ -n "$missing" ]; then missing="$missing, ${ref#refs/heads/}"; else missing="${ref#refs/heads/}"; fi
      fi
    done <<EOF2
$refs
EOF2
  fi
  # Conflicted copies of ref files: same parsing as the aside check, with "in this Mac's store".
  if ! copies="$(repo_conflicted_copies "$abs")"; then
    echo "refused: cannot look for conflicted copies; nothing changed"
    return 2
  fi
  if [ -n "$copies" ]; then
    while IFS= read -r p; do
      crel="${p#"$gd"/}"
      case "$crel" in
        refs/*|packed-refs*) list="$list$crel
" ;;
        HEAD*)
          sha="$(head -n 1 "$p" 2>/dev/null)"
          case "$sha" in
            "ref: "*) ;;
            *)
              if [ -f "$p" ] && [ ! -L "$p" ] && add__sha_in_store_of "$store" "$sha"; then
                :
              else
                headbad="$headbad
commit not in this Mac's store: $p (${sha:0:7})"
              fi
              ;;
          esac
          ;;
      esac
    done <<EOF2
$copies
EOF2
  fi
  if [ -n "$list" ]; then
    ADD__TMP="$gd"
    ADD__GD="$gd"
    ADD__LIST="$list"
    ADD__STORE="$store"
    ADD__SHA_OK=add__sha_in_store
    ADD__MSG="commit not in this Mac's store"
    rc=0
    out="$(add__check_aside "$abs")" || rc=$?
    ADD__LIST=""
    ADD__SHA_OK=add__sha_on_remote
    ADD__MSG="unpushed work from another Mac"
    if [ "$rc" != 0 ]; then
      echo "refused: the .git folder has commits this Mac's store does not: ${missing:-conflicted copies}"
      [ -z "$out" ] || printf '%s\n' "$out"
      return 2
    fi
  fi
  if [ -n "$headbad" ]; then
    echo "refused: the .git folder has commits this Mac's store does not: conflicted copies of HEAD"
    printf '%s\n' "$headbad" | sed '1d'
    return 2
  fi
  if [ -n "$missing" ]; then
    echo "refused: the .git folder has commits this Mac's store does not: $missing"
    return 2
  fi
  "$GIT_SYNC_TRASH" "$gd" || gs_die "cannot move $(add__shquote "$gd") to the Trash"
  if ! add__write_pointer "$abs" "$store"; then
    gs_die "the .git folder is in the Trash but the pointer could not be written; recover it from the Trash, or run: git-sync sync $(add__shquote "$abs")"
  fi
  if [ -z "$existing" ]; then
    remotes="$(add_remotes_json "$abs")" || exit 1
    db_put "$id" "$rel" "$remotes" || exit 1
  fi
  head="$(repo_head "$abs")" || exit 1
  if [ -n "$head" ]; then
    branch="$(repo_branch "$abs")" || exit 1
    state_record "$id" "$branch" "$head" || exit 1
  fi
  echo "$(gs_display "$rel"): stray .git folder moved to the Trash"
}

cmd_add() {
  local store force=0 path="" a rel id existing abs kind here remotes names url reasons was_new rc branch head
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      -*) gs_die "add: unknown option $a" ;;
      *)
        [ -z "$path" ] || gs_die "usage: git-sync add <path> [--force]"
        path="$a"
        ;;
    esac
  done
  [ -n "$path" ] || gs_die "usage: git-sync add <path> [--force]"
  db__check || exit 1
  rel="$(gs_rel_path "$path")" || exit 1
  if id="$(db_id_by_path "$rel")"; then
    :
  else
    id="$(gs_id_for "$rel")" || exit 1
  fi
  existing="$(db_path "$id")" || exit 1
  if [ -n "$existing" ] && [ "$existing" != "$rel" ]; then
    gs_die "id clash: $id"
  fi
  abs="$(gs_abs_path "$rel")" || exit 1
  kind="$(repo_kind "$abs" "$id")" || exit 1
  case "$kind" in
    missing|none) gs_die "no git repo at $path" ;;
    foreign) gs_die ".git points somewhere else: $path" ;;
  esac
  # A pointer or a stray folder next to this Mac's store is handled before the fetch and the gate.
  store="$(gs_store_for "$id")" || exit 1
  if [ "$kind" = pointer ]; then
    if [ -d "$store" ]; then
      add__readd_pointer "$abs" "$id" "$rel"
      return $?
    fi
    gs_die "git data is missing on this Mac; run: git-sync sync $(add__shquote "$abs")"
  fi
  # A store that is not a git repository falls through: add_convert refuses it ("store already exists").
  if [ "$kind" = folder ] && [ -d "$store" ] && git --git-dir="$store" rev-parse --git-dir >/dev/null 2>&1; then
    add__stray_folder "$abs" "$id" "$rel" "$existing"
    return $?
  fi

  add__aside "$abs" "$id" || exit 1
  names="$(gs__git "$abs" remote)"
  if [ -n "$names" ]; then
    if ! gs_fetch --all git -C "$abs"; then
      url="$(gs__git "$abs" remote get-url origin)"
      [ -n "$url" ] || url="$(gs__git "$abs" remote get-url "$(printf '%s\n' "$names" | head -n 1)")"
      gs_die "cannot reach the remote for $path: $url${GS_FETCH_ERR:+: $GS_FETCH_ERR}"
    fi
  fi
  here="$(repo_here "$abs" "$id")" || exit 1
  remotes="$(add_remotes_json "$abs")" || exit 1
  if [ "$here" = unprotected ]; then
    add__restore
    db_put "$id" "$rel" "$remotes" || exit 1
    echo "$(gs_display "$rel"): listed as unprotected (no pushed remote); left as a normal .git folder"
    return 0
  fi
  if reasons="$(add_gate "$abs")"; then
    :
  else
    if [ -z "$reasons" ]; then gs_die "safety check failed for $path"; fi
    if [ "$force" = 0 ]; then
      echo "refused: $(gs_display "$rel")"
      printf '%s\n' "$reasons"
      echo "push these first, or use --force"
      add__restore
      return 2
    fi
  fi
  rc=0
  add__check_aside "$abs" || rc=$?
  if [ "$rc" != 0 ]; then
    add__restore
    [ "$rc" = 2 ] || exit 1
    echo "push that work from the other Mac, then run add again; if you know a copy is stale, move it to the Trash by hand and run add again"
    return 2
  fi
  add__trash_aside
  rc=0
  add_clear_conflicted "$abs" || rc=$?
  if [ "$rc" = 2 ]; then
    echo "push that work from the other Mac, then run add again; if you know a copy is stale, move it to the Trash by hand and run add again"
    return 2
  fi
  [ "$rc" = 0 ] || exit 1
  was_new=0
  [ -n "$existing" ] || was_new=1
  db_put "$id" "$rel" "$remotes" || exit 1
  if ! add_convert "$abs" "$id"; then
    if [ "$was_new" = 1 ]; then db_delete "$id" || exit 1; fi
    gs_die "conversion failed; $(gs_display "$rel") is back as it was"
  fi
  head="$(repo_head "$abs")" || exit 1
  if [ -n "$head" ]; then
    branch="$(repo_branch "$abs")" || exit 1
    state_record "$id" "$branch" "$head" || exit 1
  fi
  echo "$(gs_display "$rel"): converted"
  add__other_macs_hint "$rel"
}

# Print the command to run on the other Macs. Paths are relative to the Dropbox folder, which
# can live elsewhere on another Mac (e.g. /Volumes/T7/Dropbox).
add__other_macs_hint() {
  local tool
  if tool="$(gs_rel_path "$GS_ROOT" 2>/dev/null)"; then
    tool="$(add__shquote "./$tool/git-sync")"
  else
    tool="git-sync"
  fi
  echo "on your other Macs, from the Dropbox folder, run: $tool sync $(add__shquote "$1")"
}

# Give a converted project its normal .git folder back and drop it from the database.
cmd_remove() {
  local path="" a rel id abs kind store head now pfix
  for a in "$@"; do
    case "$a" in
      -*) gs_die "usage: git-sync remove <path>" ;;
      *)
        [ -z "$path" ] || gs_die "usage: git-sync remove <path>"
        path="$a"
        ;;
    esac
  done
  [ -n "$path" ] || gs_die "usage: git-sync remove <path>"
  db__check || exit 1
  rel="$(gs_rel_path "$path")" || exit 1
  id="$(db_id_by_path "$rel")" || gs_die "not registered: $path"
  abs="$(gs_abs_path "$rel")" || exit 1
  kind="$(repo_kind "$abs" "$id")" || exit 1
  store="$(gs_store_for "$id")" || exit 1
  case "$kind" in
    missing|none) gs_die "no git repo at $path; nothing changed" ;;
    foreign) gs_die ".git points somewhere else: $path; nothing changed" ;;
    folder)
      if [ -d "$store" ]; then
        gs_die "$path has a .git folder and this Mac has a store; run first: git-sync add $(add__shquote "$abs")"
      fi
      db_delete "$id" || exit 1
      state_forget "$id" || exit 1
      echo "$(gs_display "$rel"): removed from the database; its .git folder is unchanged"
      return 0
      ;;
    pointer)
      [ -d "$store" ] || gs_die "git data is missing on this Mac; run sync first, then remove"
      ;;
  esac
  head="$(repo_head "$abs")" || exit 1
  "$GIT_SYNC_TRASH" "$abs/.git" || gs_die "cannot trash the pointer $(add__shquote "$abs/.git"); nothing changed"
  if ! mv "$store" "$abs/.git"; then
    pfix="to fix by hand: trash $(add__shquote "$abs/.git") if it exists, then run: printf 'gitdir: %s\\n' $(add__shquote "$store") > $(add__shquote "$abs/.git")"
    [ -d "$store" ] || gs_die "cannot move $(add__shquote "$store") to $(add__shquote "$abs/.git"); the store is not at its path any more and the pointer is not in place; look for it near $(add__shquote "$store")"
    if [ -e "$abs/.git" ] || [ -L "$abs/.git" ]; then
      "$GIT_SYNC_TRASH" "$abs/.git" || gs_die "cannot move $(add__shquote "$store") to $(add__shquote "$abs/.git"); the store is intact at $(add__shquote "$store") but the pointer is not in place; $pfix"
    fi
    add__write_pointer "$abs" "$store" || gs_die "cannot move $(add__shquote "$store") to $(add__shquote "$abs/.git"); the store is intact at $(add__shquote "$store") but the pointer is not in place; $pfix"
    if [ ! -f "$abs/.git" ] || [ -L "$abs/.git" ] || [ "$(cat "$abs/.git" 2>/dev/null)" != "gitdir: $store" ]; then
      gs_die "cannot move $(add__shquote "$store") to $(add__shquote "$abs/.git"); the store is intact at $(add__shquote "$store") but the pointer is not in place; $pfix"
    fi
    gs_die "cannot move $(add__shquote "$store") to $(add__shquote "$abs/.git"); the pointer is back and nothing else changed"
  fi
  now="$(repo_head "$abs")" || exit 1
  if [ "$now" != "$head" ] || ! git -C "$abs" --no-optional-locks status >/dev/null 2>&1; then
    gs_die "$(add__shquote "$abs/.git") is back as a folder but git cannot read it; the database entry was kept"
  fi
  db_delete "$id" || exit 1
  state_forget "$id" || exit 1
  echo "$(gs_display "$rel"): back to a normal .git folder; Dropbox will sync it to your other Macs again"
}
