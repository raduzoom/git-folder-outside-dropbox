test_kind_and_here() {
  make_repo demo; id="hosts--devsite--projects--demo"
  gs _call repo_kind "$P/demo" "$id"; assert_eq "folder" "$OUT"
  gs _call repo_here "$P/demo" "$id"; assert_eq "normal .git" "$OUT"
  gs _call repo_kind "$P/nope" "$id"; assert_eq "missing" "$OUT"
  gs _call repo_here "$P/nope" "$id"; assert_eq "folder missing" "$OUT"
  mkdir "$P/plain"; gs _call repo_kind "$P/plain" "x"; assert_eq "none" "$OUT"
  gs _call repo_here "$P/plain" "x"; assert_eq "needs sync" "$OUT"
  make_repo local --no-remote
  gs _call repo_here "$P/local" "hosts--devsite--projects--local"; assert_eq "unprotected" "$OUT"
  mkdir "$P/sub"; printf 'gitdir: /elsewhere\n' > "$P/sub/.git"
  gs _call repo_kind "$P/sub" "x"; assert_eq "foreign" "$OUT"
  gs _call repo_here "$P/sub" "x"; assert_eq "foreign .git" "$OUT"
}
test_pointer_kind() {
  mkdir "$P/ptr"; store="$GIT_SYNC_HOME/repos/pid.git"
  printf 'gitdir: %s\n' "$store" > "$P/ptr/.git"
  gs _call repo_kind "$P/ptr" "pid"; assert_eq "pointer" "$OUT"
  gs _call repo_here "$P/ptr" "pid"; assert_eq "needs sync" "$OUT"
  gs _call repo_has_git "$P/ptr" "pid"; assert_rc 1
  mkdir -p "$GIT_SYNC_HOME/repos"; git init -q --bare "$store"
  gs _call repo_here "$P/ptr" "pid"; assert_eq "ready" "$OUT"
  gs _call repo_has_git "$P/ptr" "pid"; assert_rc 0
}
test_unprotected_without_remote_refs() {
  mkdir "$P/e"; git -C "$P/e" init -q
  gs _call repo_here "$P/e" "x"; assert_eq "unprotected" "$OUT"
  git -C "$P/e" remote add origin "$T/remotes/none.git"
  gs _call repo_here "$P/e" "x"; assert_eq "unprotected" "$OUT"
}
test_counts() {
  make_repo demo; cd "$P/demo"
  echo x >> a.txt; echo n > new.txt
  gs _call repo_uncommitted "$P/demo"; assert_eq "2" "$OUT"
  git commit -qam two
  gs _call repo_ahead "$P/demo"; assert_eq "1" "$OUT"
  gs _call repo_behind "$P/demo"; assert_eq "0" "$OUT"
  git branch side; git stash -u -q
  gs _call repo_local_only_branches "$P/demo"; assert_eq "side" "$OUT"
  gs _call repo_unpushed_branches "$P/demo"; assert_eq "main	1" "$OUT"
  gs _call repo_stashes "$P/demo"; assert_eq "1" "$OUT"
}
test_conflicted_copies_with_odd_names() {
  make_repo "my project's"; g="$P/my project's/.git"
  cp "$g/index" "$g/index (Radu’s MacBook Pro's conflicted copy 2026-10-14)"
  gs _call repo_conflicted_copies "$P/my project's"
  assert_contains "$OUT" "conflicted copy 2026-10-14)"
  assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
}
test_conflicted_ref_copy_keeps_output_clean() {
  make_repo demo; g="$P/demo/.git"
  cp "$g/refs/heads/main" "$g/refs/heads/main (Mac conflicted copy)"
  gs _call repo_unpushed_branches "$P/demo"; assert_eq "" "$OUT"
  gs _call repo_local_only_branches "$P/demo"; assert_eq "" "$OUT"
  gs _call repo_branch "$P/demo"; assert_eq "main" "$OUT"
  gs _call repo_conflicted_copies "$P/demo"
  assert_eq "$g/refs/heads/main (Mac conflicted copy)" "$OUT"
}
test_conflicted_copies_in_pointer_store() {
  make_repo demo; id="x"; store="$(git -C "$P/demo" rev-parse --absolute-git-dir)"
  mkdir -p "$GIT_SYNC_HOME/repos"; dest="$GIT_SYNC_HOME/repos/$id.git"
  mv "$store" "$dest"; printf 'gitdir: %s\n' "$dest" > "$P/demo/.git"
  cp "$dest/HEAD" "$dest/HEAD (conflicted copy)"
  gs _call repo_conflicted_copies "$P/demo"
  assert_eq "$dest/HEAD (conflicted copy)" "$OUT"
}
test_detached_and_empty() {
  make_repo demo; git -C "$P/demo" checkout -q --detach
  gs _call repo_branch "$P/demo"; assert_eq "(detached)" "$OUT"
  mkdir "$P/empty"; git -C "$P/empty" init -q
  gs _call repo_head "$P/empty"; assert_eq "" "$OUT"
  gs _call repo_ahead "$P/empty"; assert_eq "-" "$OUT"
  gs _call repo_behind "$P/empty"; assert_eq "-" "$OUT"
}
test_commit_on_remote() {
  make_repo demo; cd "$P/demo"; pushed="$(git rev-parse HEAD)"
  echo x >> a.txt; git commit -qam two; local_only="$(git rev-parse HEAD)"
  gs _call repo_commit_on_remote "$P/demo" "$pushed"; assert_rc 0
  gs _call repo_commit_on_remote "$P/demo" "$local_only"; assert_rc 1
}
