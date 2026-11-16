# status and scan: build and print the project table.

# Make a table cell safe: no tabs or newlines, never empty.
status__cell() {
  local v="$1"
  v="${v//$'\t'/ }"
  v="${v//$'\n'/ }"
  [ -n "$v" ] || v="-"
  printf '%s' "$v"
}

# Print "name<TAB>url" for each remote of a project, sorted.
status__git_remotes() {
  local abs="$1" names n u
  names="$(gs__git "$abs" remote)"
  [ -n "$names" ] || return 0
  while IFS= read -r n; do
    u="$(gs__git "$abs" remote get-url "$n")" || u=""
    printf '%s\t%s\n' "$n" "$u"
  done <<EOF2
$names
EOF2
  return 0
}

# Return 0 when the repo's remotes differ from the database's for <id>, 1 when they match, 2 on error.
status__remotes_differ() {
  local abs="$1" id="$2" have want
  have="$(status__git_remotes "$abs" | LC_ALL=C sort)"
  want="$(db_remotes "$id")" || return 2
  want="$(printf '%s' "$want" | LC_ALL=C sort)"
  [ "$have" != "$want" ]
}

# status_row <rel> <id> <registered 0|1> [fetch_failed 0|1] [fetched 0|1]: print one tab-separated row.
status_row() {
  local rel="$1" id="$2" reg="$3" ff="${4:-0}" fd="${5:-0}" abs here kind branch unc ahead behind
  local notes="" n lines b cnt cur refs has_origin has_refs have want
  local tab
  tab="$(printf '\t')"
  abs="$(gs_abs_path "$rel")" || return 1
  kind="$(repo_kind "$abs" "$id")" || return 1
  here="$(repo_here "$abs" "$id")" || return 1
  if repo_has_git "$abs" "$id"; then
    branch="$(repo_branch "$abs")" || return 1
    unc="$(repo_uncommitted "$abs")" || return 1
    ahead="$(repo_ahead "$abs")" || return 1
    behind="$(repo_behind "$abs")" || return 1
    cur="$branch"
    has_origin=0
    gs__git "$abs" remote get-url origin >/dev/null && has_origin=1
    refs="$(gs__git "$abs" for-each-ref --count=1 --format='%(refname)' refs/remotes/origin/)"
    has_refs=0
    [ -n "$refs" ] && has_refs=1
    if [ "$kind" = folder ]; then
      if [ "$has_origin" = 0 ]; then
        notes="no remote"
      elif [ "$has_refs" = 0 ]; then
        notes="nothing pushed"
      fi
    fi
    lines="$(repo_conflicted_copies "$abs")" || return 1
    cnt=0
    [ -n "$lines" ] && cnt="$(printf '%s\n' "$lines" | awk 'END { print NR }')"
    [ "$cnt" -gt 0 ] && notes="${notes:+$notes; }$cnt conflicted copies"
    if [ "$has_refs" = 1 ]; then
      lines="$(repo_local_only_branches "$abs")" || return 1
      if [ -n "$lines" ]; then
        notes="${notes:+$notes; }local-only branch: $(printf '%s\n' "$lines" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
      fi
      lines="$(repo_unpushed_branches "$abs")" || return 1
      if [ -n "$lines" ]; then
        while IFS="$tab" read -r b n; do
          [ "$b" = "$cur" ] && continue
          notes="${notes:+$notes; }unpushed on $b: $n"
        done <<EOF2
$lines
EOF2
      fi
    fi
    n="$(repo_stashes "$abs")" || return 1
    [ "$n" -gt 0 ] && notes="${notes:+$notes; }$n stashes"
    if [ "$reg" = 1 ]; then
      status__remotes_differ "$abs" "$id"
      case "$?" in
        0) notes="${notes:+$notes; }remote differs from database" ;;
        2) return 1 ;;
      esac
    fi
  else
    branch="-"; unc="-"; ahead="-"; behind="-"
  fi
  [ "$ff" = 1 ] && notes="${notes:+$notes; }fetch failed"
  if [ "$reg" = 1 ] && [ "$kind" = pointer ] && repo_has_git "$abs" "$id"; then
    if [ "$fd" = 1 ]; then n="$(repo_other_mac_note "$id" "$abs" fetched)" || return 1; else n="$(repo_other_mac_note "$id" "$abs")" || return 1; fi
    [ -z "$n" ] || notes="${notes:+$notes; }$n"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(status__cell "$(gs_display "$rel")")" "$(status__cell "$here")" "$(status__cell "$branch")" "$(status__cell "$unc")" "$(status__cell "$ahead")" "$(status__cell "$behind")" "$(status__cell "$notes")"
}

# Read rows on stdin, prepend the header, align the columns.
status_print() {
  local tab
  tab="$(printf '\t')"
  { printf 'PROJECT\tHERE\tBRANCH\tUNCOMMITTED\tUNPUSHED\tBEHIND\tNOTES\n'; cat; } | column -t -s "$tab"
}

# Print the stores in this Mac's repos folder whose id is not in the database.
status__leftover_stores() {
  local ids dir name id found=0
  ids="$(db_ids)" || exit 1
  for dir in "$(gs_home)"/repos/*.git; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    case "$name" in .building-*) continue ;; esac
    id="${name%.git}"
    if [ -n "$ids" ] && printf '%s\n' "$ids" | grep -Fxq -- "$id"; then continue; fi
    if [ "$found" = 0 ]; then
      echo
      echo "Stores on this Mac that are no longer in the database:"
      found=1
    fi
    echo "$dir"
  done
  return 0
}

cmd_status() {
  local fetch=0 a rows="" row rel id reg ff fd abs i
  local paths=() rels=() ids=() regs=()
  db__check || exit 1
  for a in "$@"; do
    case "$a" in
      --fetch) fetch=1 ;;
      --*) gs_die "status: unknown option $a" ;;
      *) paths+=("$a") ;;
    esac
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    local all
    all="$(db_ids)" || exit 1
    if [ -n "$all" ]; then
      while IFS= read -r id; do
        rel="$(db_path "$id")" || exit 1
        [ -n "$rel" ] || continue
        rels+=("$rel"); ids+=("$id"); regs+=(1)
      done <<EOF2
$all
EOF2
    fi
  else
    for a in "${paths[@]}"; do
      rel="$(gs_rel_path "$a")" || exit 1
      if id="$(db_id_by_path "$rel")"; then
        reg=1
      else
        id="$(gs_id_for "$rel")" || exit 1
        reg=0
      fi
      rels+=("$rel"); ids+=("$id"); regs+=("$reg")
    done
  fi
  i=0
  while [ "$i" -lt "${#rels[@]}" ]; do
    rel="${rels[$i]}"; id="${ids[$i]}"; reg="${regs[$i]}"
    abs="$(gs_abs_path "$rel")" || exit 1
    ff=0
    fd=0
    if [ "$fetch" = 1 ] && repo_has_git "$abs" "$id"; then
      if gs_fetch --all git -C "$abs"; then fd=1; else ff=1; fi
    fi
    if [ "$reg" = 1 ] && [ "$(repo_kind "$abs" "$id")" = pointer ] && repo_has_git "$abs" "$id"; then
      local head branch
      head="$(repo_head "$abs")" || exit 1
      if [ -n "$head" ]; then
        branch="$(repo_branch "$abs")" || exit 1
        state_record "$id" "$branch" "$head" || exit 1
      fi
    fi
    row="$(status_row "$rel" "$id" "$reg" "$ff" "$fd")" || exit 1
    rows="$rows$row"$'\n'
    i=$((i + 1))
  done
  printf '%s' "$rows" | status_print
  if [ "${#paths[@]}" -eq 0 ]; then
    status__leftover_stores
  fi
}

cmd_scan() {
  local folder="${1:-}" root dir proj rel rows="" row found=0 gitpath
  if [ -z "$folder" ]; then
    root="$(gs_dropbox_root)" || exit 1
    folder="$root/$GS_PROJECTS_DIR"
  fi
  db__check || exit 1
  [ -d "$folder" ] || gs_die "folder not found: $folder"
  dir="$(cd "$folder" && pwd -P)" || gs_die "folder not found: $folder"
  while IFS= read -r -d '' gitpath; do
    proj="$(dirname "$gitpath")"
    rel="$(gs_rel_path "$proj")" || exit 1
    if db_id_by_path "$rel" >/dev/null; then continue; fi
    row="$(status_row "$rel" "$(gs_id_for "$rel")" 0)" || exit 1
    rows="$rows$row"$'\n'
    found=1
  done < <(find "$dir" -maxdepth 5 -name node_modules -prune -o -name .git -prune -print0 2>/dev/null)
  if [ "$found" = 0 ]; then
    echo "nothing new under $folder"
    return 0
  fi
  printf '%s' "$rows" | LC_ALL=C sort | status_print
}
