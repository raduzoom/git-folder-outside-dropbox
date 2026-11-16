# Test helpers: sandbox, repo fixtures, two-Mac switch, assertions.
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/git-sync"

fail() {
  echo "  FAIL: $*" >&2
  exit 1
}

sandbox_setup() {
  T="$(mktemp -d)"
  T="$(cd "$T" && pwd -P)"
  P="$T/dropbox/hosts/devsite/projects"
  mkdir -p "$P" "$T/home/.git-sync" "$T/data" "$T/remotes" "$T/trash" "$T/parked" "$T/bin"
  cat > "$T/bin/fake-trash" <<'TRASH'
#!/bin/bash
dir="$(cd "$(dirname "$0")/.." && pwd -P)/trash"
for src in "$@"; do
  base="$(basename "$src")"
  dest="$dir/$base"
  n=1
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    dest="$dir/$base.$n"
    n=$((n + 1))
  done
  mv "$src" "$dest"
done
TRASH
  chmod +x "$T/bin/fake-trash"
  cat > "$T/gitconfig" <<'CFG'
[init]
	defaultBranch = main
[user]
	name = Test User
	email = test@example.com
CFG
  export GIT_CONFIG_GLOBAL="$T/gitconfig"
  export GIT_SYNC_DROPBOX="$T/dropbox"
  export GIT_SYNC_HOME="$T/home/.git-sync"
  export GIT_SYNC_DATA="$T/data"
  export GIT_SYNC_MAC_NAME="Mac A"
  export GIT_SYNC_TRASH="$T/bin/fake-trash"
  CURRENT_MAC=a
}

make_repo() {
  local name="$1" remote=1
  [ "${2:-}" = "--no-remote" ] && remote=0
  git init -q "$P/$name" || fail "make_repo: git init"
  echo "a" > "$P/$name/a.txt"
  git -C "$P/$name" add a.txt || fail "make_repo: add"
  git -C "$P/$name" commit -q -m "first" || fail "make_repo: commit"
  if [ "$remote" = 1 ]; then
    git init -q --bare "$T/remotes/$name.git" || fail "make_repo: bare init"
    git -C "$P/$name" remote add origin "$T/remotes/$name.git" || fail "make_repo: remote add"
    git -C "$P/$name" push -q -u origin main >/dev/null 2>&1 || fail "make_repo: push"
  fi
  return 0
}

use_mac() {
  local new="$1"
  [ "$new" = a ] || [ "$new" = b ] || fail "use_mac: expected a or b, got $new"
  if [ "$new" != "$CURRENT_MAC" ]; then
    mv "$T/home/.git-sync" "$T/parked/$CURRENT_MAC" || fail "use_mac: park"
    if [ -d "$T/parked/$new" ]; then
      mv "$T/parked/$new" "$T/home/.git-sync" || fail "use_mac: restore"
    else
      mkdir -p "$T/home/.git-sync"
    fi
    CURRENT_MAC="$new"
  fi
  if [ "$new" = a ]; then GIT_SYNC_MAC_NAME="Mac A"; else GIT_SYNC_MAC_NAME="Mac B"; fi
  export GIT_SYNC_MAC_NAME
}

gs() {
  OUT="$("$SCRIPT" "$@" 2>&1)"
  RC=$?
}

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$1] got [$2]"
}
assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "assert_contains: [$1] does not contain [$2]" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "assert_not_contains: [$1] contains [$2]" ;; esac
}
assert_rc() {
  [ "$RC" = "$1" ] || fail "assert_rc: expected $1 got $RC (output: $OUT)"
}
assert_file() { [ -f "$1" ] || fail "assert_file: missing file $1"; }
assert_dir() { [ -d "$1" ] || fail "assert_dir: missing dir $1"; }
assert_missing() {
  { [ -e "$1" ] || [ -L "$1" ]; } && fail "assert_missing: $1 exists"
  return 0
}
