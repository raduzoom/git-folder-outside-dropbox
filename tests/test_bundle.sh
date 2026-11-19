ID=hosts--devsite--projects--demo
ready_ab() { make_repo demo; gs add "$P/demo"; use_mac b; gs sync "$P/demo"; use_mac a; }
mac_id() { cat "$GIT_SYNC_HOME/mac-id"; }
bundle_of() { echo "$GIT_SYNC_DATA/state/bundles/$1/$ID.bundle"; }
# On Mac A: commit an unpushed change and record it. Sets A_ID and A_HEAD.
a_commits() {
  ( cd "$P/demo" && echo "${1:-x}" >> a.txt && git commit -qam "${1:-x}" )
  sleep 1; gs status; A_ID="$(mac_id)"; A_HEAD="$(git -C "$P/demo" rev-parse HEAD)"
}

test_bundle_written_for_unpushed_commit() {
  ready_ab; a_commits
  f="$(bundle_of "$A_ID")"; assert_file "$f"
  assert_eq "$A_HEAD" "$(git bundle list-heads "$f" refs/heads/main | awk '{print $1}')"
  assert_missing "$f.partial"
}
test_bundle_trashed_once_pushed() {
  ready_ab; a_commits; f="$(bundle_of "$A_ID")"
  git -C "$P/demo" push -q; gs status
  assert_missing "$f"; assert_file "$T/trash/$ID.bundle"
}
test_bundle_skipped_over_cap_and_disabled_by_zero() {
  ready_ab; ( cd "$P/demo" && echo x >> a.txt && git commit -qam x )
  GIT_SYNC_BUNDLE_MAX=10 gs status; assert_missing "$(bundle_of "$(mac_id)")"
  GIT_SYNC_BUNDLE_MAX=0 gs status; assert_missing "$(bundle_of "$(mac_id)")"
}
test_sync_fetches_bundle_and_offers_adopt() {
  ready_ab; a_commits; use_mac b
  gs sync "$P/demo"; assert_rc 0
  assert_contains "$OUT" "WARNING: Mac A has unpushed work on main (${A_HEAD:0:7}); its commits are here: run git-sync adopt $P/demo, then push."
  assert_eq "$A_HEAD" "$(git -C "$P/demo" rev-parse "refs/git-sync/$A_ID/main")"
  assert_eq "" "$(git -C "$P/demo" for-each-ref --contains "$A_HEAD" refs/remotes/)"
  gs status; assert_contains "$OUT" "Mac A has unpushed work on main (${A_HEAD:0:7}), adoptable here"
}
test_rebuild_fetches_bundle_too() {
  make_repo demo; gs add "$P/demo"; a_commits; use_mac b
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "rebuilt on main"
  assert_contains "$OUT" "its commits are here"
}
test_adopt_moves_branch_and_leaves_files() {
  ready_ab; a_commits; use_mac b; gs sync "$P/demo"; echo n > "$P/demo/new.txt"
  sum="$(cat "$P/demo/a.txt" "$P/demo/new.txt" | shasum)"
  gs adopt "$P/demo"; assert_rc 0; assert_contains "$OUT" "demo: adopted 1 commits from Mac A (${A_HEAD:0:7}); push when ready"
  assert_eq "$A_HEAD" "$(git -C "$P/demo" rev-parse HEAD)"
  assert_eq "?? new.txt" "$(git -C "$P/demo" status --porcelain)"
  assert_eq "$sum" "$(cat "$P/demo/a.txt" "$P/demo/new.txt" | shasum)"
  gs sync "$P/demo"; assert_not_contains "$OUT" "WARNING"; assert_contains "$OUT" "1 unpushed commits"
  gs status; assert_contains "$OUT" "${A_HEAD:0:7} adopted from Mac A, not pushed yet"
  git -C "$P/demo" push -q; gs sync "$P/demo"
  assert_eq "" "$(git -C "$P/demo" for-each-ref refs/git-sync/)"
  use_mac a; gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "up to date"; assert_not_contains "$OUT" "WARNING"
}
test_adopt_refuses_when_files_differ_and_force_goes_ahead() {
  ready_ab; a_commits; use_mac b; gs sync "$P/demo"; echo later >> "$P/demo/a.txt"
  gs adopt "$P/demo"; assert_rc 1; assert_contains "$OUT" "1 files here differ from Mac A's ${A_HEAD:0:7}; nothing changed"
  assert_contains "$OUT" "  a.txt"; assert_not_contains "$OUT" "adopted"
  assert_eq "$(git -C "$P/demo" rev-parse origin/main)" "$(git -C "$P/demo" rev-parse HEAD)"
  gs adopt "$P/demo" --force; assert_rc 0; assert_contains "$OUT" "adopted 1 commits"
  assert_eq " M a.txt" "$(git -C "$P/demo" status --porcelain)"
}
test_adopt_files_check_handles_new_and_deleted_files() {
  ready_ab
  ( cd "$P/demo" && echo n > new.txt && git add new.txt && git rm -q a.txt && git commit -qm swap ); sleep 1; gs status
  use_mac b; gs sync "$P/demo"
  gs adopt "$P/demo"; assert_rc 0; assert_eq "" "$(git -C "$P/demo" status --porcelain)"
}
test_adopt_refuses_before_sync() {
  ready_ab; a_commits; use_mac b
  gs adopt "$P/demo"; assert_rc 1; assert_contains "$OUT" "not on this Mac yet; run: git-sync sync"
}
test_adopt_refuses_when_this_mac_has_its_own_commits() {
  ready_ab; use_mac b; ( cd "$P/demo" && git commit -q --allow-empty -m mine ); use_mac a; a_commits; use_mac b
  gs sync "$P/demo"; assert_not_contains "$OUT" "its commits are here"
  head="$(git -C "$P/demo" rev-parse HEAD)"
  gs adopt "$P/demo"; assert_rc 1; assert_contains "$OUT" "this Mac's main has commits Mac A's ${A_HEAD:0:7} doesn't; nothing changed"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
}
test_adopt_refuses_other_branch() {
  ready_ab; git -C "$P/demo" checkout -q -b feat; a_commits; use_mac b
  gs sync "$P/demo"; assert_eq "$A_HEAD" "$(git -C "$P/demo" rev-parse "refs/git-sync/$A_ID/feat")"
  gs adopt "$P/demo"; assert_rc 1; assert_contains "$OUT" "Mac A is on feat, this Mac is on main; nothing changed"
}
test_adopt_nothing_to_adopt() {
  ready_ab; use_mac b; gs adopt "$P/demo"; assert_rc 1; assert_contains "$OUT" "nothing to adopt"
  gs adopt; assert_rc 1; assert_contains "$OUT" "usage"
  gs adopt "$P/demo" --bogus; assert_rc 1; assert_contains "$OUT" "unknown option"
}
test_bundle_not_matching_record_is_skipped() {
  ready_ab; a_commits one; f="$(bundle_of "$A_ID")"; cp "$f" "$T/old.bundle"
  ( cd "$P/demo" && echo two >> a.txt && git commit -qam two ); sleep 1; gs status
  cp "$T/old.bundle" "$f"; use_mac b
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "WARNING: Mac A has unpushed work on main"
  assert_not_contains "$OUT" "its commits are here"; assert_eq "" "$(git -C "$P/demo" for-each-ref refs/git-sync/)"
  use_mac a; echo junk > "$f"; use_mac b
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "Push from there"
}
test_recommitted_work_is_recognised_on_both_macs() {
  ready_ab; a_commits; use_mac b; gs sync "$P/demo"
  ( cd "$P/demo" && git commit -qam "same change, committed on B" && git push -q ); sleep 1
  gs sync "$P/demo"; assert_not_contains "$OUT" "WARNING"
  assert_contains "$OUT" "Mac A's ${A_HEAD:0:7} is already on the remote under another commit"
  gs status; assert_contains "$OUT" "Mac A's ${A_HEAD:0:7} is on the remote under another commit"
  use_mac a; gs sync "$P/demo"; assert_rc 0
  assert_contains "$OUT" "diverged, but the remote already has these changes: git reset origin/main drops the local commits, files untouched"
  assert_eq "$A_HEAD" "$(git -C "$P/demo" rev-parse HEAD)"
}
test_diverged_with_different_changes_keeps_old_message() {
  ready_ab; ( cd "$P/demo" && echo b > b.txt && git add b.txt && git commit -qm b && git push -q ); use_mac b
  ( cd "$P/demo" && echo c > c.txt && git add c.txt && git commit -qm c )
  gs sync "$P/demo"; assert_contains "$OUT" "diverged: 1 ahead, 1 behind; nothing changed"
}
