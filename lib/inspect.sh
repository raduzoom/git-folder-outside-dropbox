# Read-only facts about one project. Every function takes the project's absolute path.
# Nothing here writes to the project or its git data; git's stderr is silenced.

# Run git in a project without refreshing the index and without stderr.
gs__git() {
  local abs="$1"
  shift
  git -C "$abs" --no-optional-locks "$@" 2>/dev/null
}

repo_kind() {
  local abs="$1" id="$2" content expected
  [ -d "$abs" ] || { echo missing; return 0; }
  if [ -d "$abs/.git" ]; then
    echo folder
  elif [ -f "$abs/.git" ]; then
    expected="gitdir: $(gs_store_for "$id")" || return 1
    content="$(cat "$abs/.git" 2>/dev/null)"
    if [ "$content" = "$expected" ]; then echo pointer; else echo foreign; fi
  else
    echo none
  fi
}

repo_has_git() {
  local abs="$1" id="$2" kind store
  kind="$(repo_kind "$abs" "$id")" || return 1
  case "$kind" in
    folder) return 0 ;;
    pointer)
      store="$(gs_store_for "$id")" || return 1
      [ -d "$store" ]
      ;;
    *) return 1 ;;
  esac
}

repo_here() {
  local abs="$1" id="$2" kind refs
  kind="$(repo_kind "$abs" "$id")" || return 1
  case "$kind" in
    missing) echo "folder missing" ;;
    none) echo "needs sync" ;;
    foreign) echo "foreign .git" ;;
    pointer)
      if repo_has_git "$abs" "$id"; then echo ready; else echo "needs sync"; fi
      ;;
    folder)
      refs="$(gs__git "$abs" for-each-ref --count=1 --format='%(refname)' refs/remotes/origin/)"
      if gs__git "$abs" remote get-url origin >/dev/null && [ -n "$refs" ]; then
        echo "normal .git"
      else
        echo unprotected
      fi
      ;;
  esac
}

repo_branch() {
  local abs="$1" b
  b="$(gs__git "$abs" symbolic-ref --short -q HEAD)"
  if [ -n "$b" ]; then echo "$b"; else echo "(detached)"; fi
}

repo_head() {
  local abs="$1" h
  h="$(gs__git "$abs" rev-parse --verify -q HEAD)"
  [ -z "$h" ] || echo "$h"
  return 0
}

repo_uncommitted() {
  local abs="$1" out
  out="$(gs__git "$abs" status --porcelain)"
  printf '%s' "$out" | awk 'END { print NR }'
}

# Print the commit count of origin/<branch>..HEAD (ahead) or HEAD..origin/<branch> (behind), or "-".
gs__ahead_behind() {
  local abs="$1" mode="$2" b n
  b="$(repo_branch "$abs")" || return 1
  if [ "$b" = "(detached)" ] || ! gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null; then
    echo "-"
    return 0
  fi
  if [ "$mode" = ahead ]; then
    n="$(gs__git "$abs" rev-list --count "refs/remotes/origin/$b..HEAD")" || n=""
  else
    n="$(gs__git "$abs" rev-list --count "HEAD..refs/remotes/origin/$b")" || n=""
  fi
  if [ -n "$n" ]; then echo "$n"; else echo "-"; fi
}

repo_ahead() { gs__ahead_behind "$1" ahead; }
repo_behind() { gs__ahead_behind "$1" behind; }

repo_unpushed_branches() {
  local abs="$1" heads ref b n
  heads="$(gs__git "$abs" for-each-ref --format='%(refname)' refs/heads/)"
  [ -n "$heads" ] || return 0
  while IFS= read -r ref; do
    b="${ref#refs/heads/}"
    gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null || continue
    n="$(gs__git "$abs" rev-list --count "refs/remotes/origin/$b..$ref")" || continue
    [ -n "$n" ] && [ "$n" -gt 0 ] && printf '%s\t%s\n' "$b" "$n"
  done <<EOF2
$heads
EOF2
  return 0
}

repo_local_only_branches() {
  local abs="$1" heads ref b
  heads="$(gs__git "$abs" for-each-ref --format='%(refname)' refs/heads/)"
  [ -n "$heads" ] || return 0
  while IFS= read -r ref; do
    b="${ref#refs/heads/}"
    gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null || printf '%s\n' "$b"
  done <<EOF2
$heads
EOF2
  return 0
}

repo_stashes() {
  local abs="$1" out
  out="$(gs__git "$abs" stash list)"
  printf '%s' "$out" | awk 'END { print NR }'
}

repo_conflicted_copies() {
  local abs="$1" gd
  if [ -d "$abs/.git" ]; then
    gd="$abs/.git"
  elif [ -f "$abs/.git" ]; then
    gd="$(sed -n '1s/^gitdir: //p' "$abs/.git" 2>/dev/null)"
    case "$gd" in
      "") return 0 ;;
      /*) ;;
      *) gd="$abs/$gd" ;;
    esac
  else
    return 0
  fi
  [ -d "$gd" ] || return 0
  find "$gd" -name '*conflicted copy*' -print 2>/dev/null
  return 0
}

repo_commit_on_remote() {
  local abs="$1" sha="$2" out
  out="$(gs__git "$abs" for-each-ref --contains "$sha" --count=1 --format='%(refname)' refs/remotes/)" || return 1
  [ -n "$out" ]
}

# gs_fetch <remote name | --all> <git prefix...>: the one network fetch. Never prompts for a
# password; ssh gives up connecting after 10 s but may still ask for a passphrase or host key.
# On failure GS_FETCH_ERR holds the line of git's stderr that names the cause: the first line
# starting with ssh:, ERROR:, fatal: or error:, else the first non-empty line (empty when git
# said nothing). Git's closing "Please make sure ... and the repository exists." is never it.
GS_FETCH_ERR=""
gs_fetch() {
  local target="$1" err rc=0
  shift
  err="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=10}" "$@" fetch --quiet --prune "$target" 2>&1 >/dev/null)" || rc=$?
  GS_FETCH_ERR="$(printf '%s\n' "$err" | awk 'cause == "" && /^(ssh:|ERROR:|fatal:|error:)/ { cause = $0 } first == "" && NF { first = $0 } END { print (cause != "" ? cause : first) }')"
  return "$rc"
}

# gs__field <tab-separated line> <n>: print field n, keeping empty fields.
gs__field() {
  printf '%s' "$1" | awk -F'\t' -v n="$2" '{ print $n }'
}

# repo_other_mac_note <id> <abs> [fetched]: print "<Mac> has unpushed work on <branch> (<7-char id>)"
# when the latest record from another Mac names a branch or commit that is not on the remote. Local
# data only. A commit this repo does not know is "not fetched here", unless the caller has just
# fetched (second argument "fetched"): then it really is on no remote, so it is unpushed work.
repo_other_mac_note() {
  local id="$1" abs="$2" fetched="${3:-}" other name branch head
  other="$(state_latest_other "$id")" || return 1
  [ -n "$other" ] || return 0
  name="$(gs__field "$other" 1)"
  branch="$(gs__field "$other" 2)"
  head="$(gs__field "$other" 3)"
  [ -n "$branch" ] && [ -n "$head" ] || return 0
  if [ "$fetched" != fetched ] && ! gs__git "$abs" cat-file -e "$head^{commit}"; then
    printf '%s is on a commit not fetched here (%s); run: git-sync sync\n' "$name" "$(printf '%s' "$head" | cut -c1-7)"
    return 0
  fi
  if [ "$branch" = "(detached)" ]; then
    repo_commit_on_remote "$abs" "$head" && return 0
  elif gs__git "$abs" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null && repo_commit_on_remote "$abs" "$head"; then
    return 0
  fi
  printf '%s has unpushed work on %s (%s)\n' "$name" "$branch" "$(printf '%s' "$head" | cut -c1-7)"
  return 0
}
