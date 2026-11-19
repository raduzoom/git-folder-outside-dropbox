# Carry a Mac's unpushed commits to the other Macs as git bundles in Dropbox, and adopt them.
# Each Mac writes only state/bundles/<its mac-id>/<project id>.bundle. A bundle is trusted only
# when its tip is the commit that Mac's state file records, so a stale or half-synced file is
# skipped. Fetched commits go under refs/git-sync/<mac-id>/, never refs/remotes/.

bundle_max() { echo "${GIT_SYNC_BUNDLE_MAX:-26214400}"; }

bundle_file() { echo "$(gs_data_dir)/state/bundles/$1/$2.bundle"; }

# bundle__tip <file> <ref>: print the commit the bundle has for <ref>, or nothing.
bundle__tip() {
  [ -f "$1" ] || return 0
  git bundle list-heads "$1" "$2" 2>/dev/null | awk 'NR == 1 { print $1 }'
  return 0
}

# bundle_publish <id> <branch> <head>: called whenever this Mac records its state. Writes this
# Mac's bundle when <head> is on a branch and on no remote; trashes it otherwise. Never fails the
# caller: a bundle that cannot be written is reported on stderr and skipped.
bundle_publish() {
  local id="$1" branch="$2" head="$3" rel abs file dir tmp size max
  file="$(bundle_file "$(gs_mac_id)" "$id")" || return 0
  rel="$(db_path "$id")" || return 0
  [ -n "$rel" ] || return 0
  abs="$(gs_abs_path "$rel")" || return 0
  max="$(bundle_max)"
  if [ -z "$head" ] || [ "$branch" = "(detached)" ] || [ "$max" = 0 ] || repo_commit_on_remote "$abs" "$head"; then
    bundle__drop "$file"
    return 0
  fi
  [ "$(bundle__tip "$file" "refs/heads/$branch")" = "$head" ] && return 0
  mkdir -p "$(gs_home)/tmp" || return 0
  tmp="$(mktemp "$(gs_home)/tmp/bundle.XXXXXX")" || return 0
  if ! git -C "$abs" bundle create -q "$tmp" "refs/heads/$branch" --not --remotes >/dev/null 2>&1 \
    || ! git -C "$abs" bundle verify -q "$tmp" >/dev/null 2>&1; then
    "$GIT_SYNC_TRASH" "$tmp" >/dev/null 2>&1
    echo "git-sync: $(gs_display "$rel"): could not write the bundle of unpushed commits" >&2
    return 0
  fi
  size="$(stat -f %z "$tmp" 2>/dev/null)" || size=0
  if [ "$size" -gt "$max" ]; then
    "$GIT_SYNC_TRASH" "$tmp" >/dev/null 2>&1
    bundle__drop "$file"
    return 0
  fi
  dir="$(dirname "$file")"
  # The move into Dropbox may be a copy (another volume); the last rename stays in one folder.
  if ! { mkdir -p "$dir" && mv "$tmp" "$file.partial" && mv "$file.partial" "$file"; }; then
    echo "git-sync: $(gs_display "$rel"): could not publish the bundle of unpushed commits" >&2
  fi
  return 0
}

bundle__drop() {
  [ -f "$1" ] || return 0
  "$GIT_SYNC_TRASH" "$1" >/dev/null 2>&1 || echo "git-sync: cannot move $1 to the Trash" >&2
  return 0
}

# bundle_fetch_other <id> <abs>: after a fetch, bring the latest other Mac's unpushed commits in
# from its bundle when the bundle matches its record. Also drops refs/git-sync/ refs whose commit
# reached the remote. Quiet; never fails the caller.
bundle_fetch_other() {
  local id="$1" abs="$2" other branch head mac ref refs file
  refs="$(gs__git "$abs" for-each-ref --format='%(refname)' refs/git-sync/)"
  if [ -n "$refs" ]; then
    while IFS= read -r ref; do
      repo_commit_on_remote "$abs" "$ref" && git -C "$abs" update-ref -d "$ref" >/dev/null 2>&1
    done <<EOF2
$refs
EOF2
  fi
  other="$(state_latest_other "$id")" || return 0
  [ -n "$other" ] || return 0
  branch="$(gs__field "$other" 2)"
  head="$(gs__field "$other" 3)"
  mac="$(gs__field "$other" 5)"
  { [ -n "$branch" ] && [ "$branch" != "(detached)" ] && [ -n "$head" ] && [ -n "$mac" ]; } || return 0
  repo_commit_on_remote "$abs" "$head" && return 0
  ref="refs/git-sync/$mac/$branch"
  [ "$(gs__git "$abs" rev-parse --verify -q "$ref")" = "$head" ] && return 0
  file="$(bundle_file "$mac" "$id")"
  [ "$(bundle__tip "$file" "refs/heads/$branch")" = "$head" ] || return 0
  git -C "$abs" fetch -q --no-write-fetch-head "$file" "+refs/heads/$branch:$ref" >/dev/null 2>&1
  return 0
}

# repo_changes_on <abs> <commit> <target>: true when <target> has every file <commit> changed since
# the two split, with the same content (so <commit>'s work is already in <target>).
repo_changes_on() {
  local abs="$1" c="$2" t="$3" base mine theirs
  base="$(gs__git "$abs" merge-base "$c" "$t")" || return 1
  mine="$(gs__git "$abs" diff --name-only --no-renames "$base" "$c")" || return 1
  [ -n "$mine" ] || return 1
  theirs="$(gs__git "$abs" diff --name-only --no-renames "$c" "$t")" || return 1
  [ -z "$theirs" ] && return 0
  [ -z "$(printf '%s\n%s\n' "$(printf '%s\n' "$mine" | LC_ALL=C sort -u)" "$(printf '%s\n' "$theirs" | LC_ALL=C sort -u)" | LC_ALL=C sort | uniq -d)" ]
}

# adopt__differing <abs> <from> <to>: print the files <from>..<to> changes whose working copy is not
# the one in <to>.
adopt__differing() {
  local abs="$1" from="$2" to="$3" p want have
  while IFS= read -r -d '' p; do
    want="$(gs__git "$abs" rev-parse -q --verify "$to:$p")" || want=""
    if [ -z "$want" ]; then
      { [ -e "$abs/$p" ] || [ -L "$abs/$p" ]; } && printf '%s\n' "$p"
    elif [ -L "$abs/$p" ]; then
      have="$(readlink "$abs/$p" | tr -d '\n' | git hash-object --stdin 2>/dev/null)"
      [ "$have" = "$want" ] || printf '%s\n' "$p"
    elif [ -f "$abs/$p" ]; then
      have="$(git -C "$abs" hash-object -- "$p" 2>/dev/null)"
      [ "$have" = "$want" ] || printf '%s\n' "$p"
    else
      printf '%s\n' "$p"
    fi
  done < <(gs__git "$abs" diff -z --name-only --no-renames "$from" "$to")
  return 0
}

cmd_adopt() {
  local force=0 path="" a rel id abs other oname obranch ohead short b cur n staged list cnt
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      --*) gs_die "adopt: unknown option $a" ;;
      *) [ -z "$path" ] || gs_die "usage: git-sync adopt <path> [--force]"; path="$a" ;;
    esac
  done
  [ -n "$path" ] || gs_die "usage: git-sync adopt <path> [--force]"
  db__check || exit 1
  rel="$(gs_rel_path "$path")" || exit 1
  id="$(db_id_by_path "$rel")" || gs_die "not registered; run: git-sync add $(add__shquote "$path")"
  abs="$(gs_abs_path "$rel")" || exit 1
  [ "$(repo_kind "$abs" "$id")" = pointer ] && repo_has_git "$abs" "$id" || gs_die "$(gs_display "$rel") is not ready on this Mac; run: git-sync sync $(add__shquote "$path")"
  other="$(state_latest_other "$id")" || exit 1
  oname="$(gs__field "$other" 1)"
  obranch="$(gs__field "$other" 2)"
  ohead="$(gs__field "$other" 3)"
  { [ -n "$other" ] && [ -n "$obranch" ] && [ "$obranch" != "(detached)" ] && [ -n "$ohead" ]; } || gs_die "nothing to adopt: no other Mac has recorded a branch for $(gs_display "$rel")"
  short="$(printf '%s' "$ohead" | cut -c1-7)"
  repo_commit_on_remote "$abs" "$ohead" && gs_die "nothing to adopt: $oname's $short is already on the remote; run: git-sync sync $(add__shquote "$path")"
  gs__git "$abs" cat-file -e "$ohead^{commit}" || gs_die "$oname's $short is not on this Mac yet; run: git-sync sync $(add__shquote "$path") (if it is still missing, run git-sync status on $oname)"
  b="$(repo_branch "$abs")" || exit 1
  [ "$b" = "$obranch" ] || gs_die "$oname is on $obranch, this Mac is on $b; nothing changed"
  cur="$(repo_head "$abs")"
  [ "$cur" != "$ohead" ] && ! gs__git "$abs" merge-base --is-ancestor "$ohead" "$cur" || gs_die "nothing to adopt: this Mac already has $oname's $short"
  gs__git "$abs" merge-base --is-ancestor "$cur" "$ohead" || gs_die "this Mac's $b has commits $oname's $short doesn't; nothing changed"
  if [ "$force" = 0 ]; then
    list="$(adopt__differing "$abs" "$cur" "$ohead")"
    if [ -n "$list" ]; then
      cnt="$(printf '%s\n' "$list" | awk 'END { print NR }')"
      {
        echo "git-sync: $cnt files here differ from $oname's $short; nothing changed:"
        printf '%s\n' "$list" | head -n 10 | sed 's/^/  /'
        [ "$cnt" -le 10 ] || echo "  … and $((cnt - 10)) more"
        echo "Dropbox may still be delivering them, or they were edited here since."
        echo "Run again when they match, or add --force to adopt anyway (files are never touched)."
      } >&2
      exit 1
    fi
  fi
  n="$(gs__git "$abs" rev-list --count "$cur..$ohead")" || n="?"
  staged=0
  gs__git "$abs" diff --cached --quiet || staged=1
  sync__move_ref "$abs" "$b" "$ohead" "$cur" || gs_die "cannot move $b; nothing changed"
  git -C "$abs" reset -q >/dev/null 2>&1 || gs_die "$b now points at $short, but git's file list could not be refreshed; run: git -C $(add__shquote "$abs") reset"
  state_record "$id" "$b" "$ohead" || exit 1
  echo "$(gs_display "$rel"): adopted $n commits from $oname ($short); push when ready"
  [ "$staged" = 0 ] || echo "$(gs_display "$rel"): staged changes were unstaged (files untouched)"
  return 0
}
