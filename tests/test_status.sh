test_status_empty_db() { gs status; assert_rc 0; assert_contains "$OUT" "PROJECT"; }
test_status_path_unregistered_repo() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; git commit -qam two; echo y >> a.txt
  gs status "$P/demo"
  row="$(printf '%s\n' "$OUT" | grep '^demo')"
  assert_contains "$row" "normal .git"; assert_contains "$row" "main"
  assert_eq "1 1 0" "$(printf '%s\n' "$row" | awk '{print $(NF-3), $(NF-2), $(NF-1)}')"
  assert_missing "$GIT_SYNC_DATA/state"
}
test_status_notes() {
  make_repo demo; cd "$P/demo"; git branch side; echo x >> a.txt; git stash -q
  cp .git/index ".git/index (conflicted copy)"
  gs status "$P/demo"
  assert_contains "$OUT" "1 conflicted copies; local-only branch: side; 1 stashes"
  make_repo local --no-remote; gs status "$P/local"
  assert_contains "$OUT" "unprotected"; assert_contains "$OUT" "no remote"
}
test_status_registered_records_state() {
  make_repo demo; gs add "$P/demo"
  gs status
  assert_contains "$OUT" "demo"
  assert_eq "main" "$(jq -r '.repos["hosts--devsite--projects--demo"].branch' "$GIT_SYNC_DATA"/state/*.json)"
}
test_status_folder_missing_and_empty_repo_and_detached() {
  gs _call db_put "hosts--devsite--projects--gone" "hosts/devsite/projects/gone" '{}'
  gs status; assert_contains "$OUT" "folder missing"
  mkdir "$P/empty"; git -C "$P/empty" init -q; gs status "$P/empty"; assert_rc 0
  assert_contains "$OUT" "unprotected"; assert_contains "$OUT" "no remote"
  make_repo demo; git -C "$P/demo" checkout -q --detach; gs status "$P/demo"
  assert_contains "$OUT" "(detached)"
}
test_status_fetch_updates_behind() {
  make_repo demo; git clone -q "$T/remotes/demo.git" "$T/other"
  ( cd "$T/other" && echo z >> a.txt && git commit -qam remote && git push -q )
  gs status "$P/demo";         assert_eq "0" "$(printf '%s\n' "$OUT" | grep '^demo' | awk '{print $(NF-1)}')"
  gs status "$P/demo" --fetch; assert_eq "1" "$(printf '%s\n' "$OUT" | grep '^demo' | awk '{print $(NF-1)}')"
}
test_scan_lists_only_unregistered_including_nested() {
  make_repo one; make_repo two; mkdir -p "$P/group"; make_repo group/inner
  mkdir -p "$P/one/node_modules/dep"; git -C "$P/one/node_modules/dep" init -q
  gs _call db_put "hosts--devsite--projects--two" "hosts/devsite/projects/two" '{}'
  gs scan
  assert_contains "$OUT" "one"; assert_contains "$OUT" "group/inner"
  assert_not_contains "$OUT" "two"; assert_not_contains "$OUT" "node_modules"
  assert_missing "$GIT_SYNC_DATA/state"
}
test_status_fetch_before_path_and_failure_note() {
  make_repo demo; git -C "$P/demo" remote set-url origin "$T/remotes/nope.git"
  gs status --fetch "$P/demo"; assert_rc 0
  assert_contains "$OUT" "fetch failed"
}
test_status_nothing_pushed_and_unpushed_branch() {
  make_repo demo; git -C "$P/demo" checkout -q -b side; echo q >> "$P/demo/a.txt"; git -C "$P/demo" commit -qam s
  git -C "$P/demo" push -q origin side; echo r >> "$P/demo/a.txt"; git -C "$P/demo" commit -qam s2
  git -C "$P/demo" checkout -q main
  gs status "$P/demo"; assert_contains "$OUT" "unpushed on side: 1"
  mkdir "$P/np"; git -C "$P/np" init -q; git init -q --bare "$T/remotes/np.git"; git -C "$P/np" remote add origin "$T/remotes/np.git"
  gs status "$P/np"; assert_contains "$OUT" "nothing pushed"
}
test_status_remote_differs_registered_only() {
  make_repo demo
  gs _call db_put "hosts--devsite--projects--demo" "hosts/devsite/projects/demo" '{"origin":"git@example.com:x/y.git"}'
  gs status; assert_contains "$OUT" "remote differs from database"
  make_repo other; gs status "$P/other"; assert_not_contains "$OUT" "remote differs"
}
test_status_spaces_and_scan_spaces() {
  make_repo "my proj"; gs status "$P/my proj"; assert_contains "$OUT" "my proj"
  gs scan; assert_contains "$OUT" "my proj"
}
test_scan_empty() {
  gs scan; assert_rc 0; assert_contains "$OUT" "nothing new under"
}
test_status_and_scan_stop_on_corrupt_db() {
  make_repo demo; printf '{ broken' > "$GIT_SYNC_DATA/repos.json"
  gs status "$P/demo"; assert_rc 1; assert_contains "$OUT" "not valid JSON"; assert_not_contains "$OUT" "PROJECT"; assert_not_contains "$OUT" "normal .git"
  gs status; assert_rc 1; assert_contains "$OUT" "not valid JSON"
  gs scan; assert_rc 1; assert_contains "$OUT" "not valid JSON"; assert_not_contains "$OUT" "normal .git"
}
test_status_does_not_record_state_for_folder_kinds() {
  make_repo demo
  gs _call db_put "hosts--devsite--projects--demo" "hosts/devsite/projects/demo" '{}'
  gs status; assert_eq "0" "$(ls "$GIT_SYNC_DATA"/state/*.json 2>/dev/null | wc -l | tr -d ' ')"
}
