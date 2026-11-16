ID=hosts--devsite--projects--demo
test_add_registers_clean_repo() {
  make_repo demo; gs add "$P/demo"; assert_rc 0
  gs _call db_path "$ID"; assert_eq "hosts/devsite/projects/demo" "$OUT"
  gs _call db_remotes "$ID"; assert_eq "origin	$T/remotes/demo.git" "$OUT"
  assert_file "$P/demo/.git"
}
test_add_refuses_unpushed_commits() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; git commit -qam two
  gs add "$P/demo"; assert_rc 2
  assert_contains "$OUT" "unpushed commits on main: 1"
  gs _call db_ids; assert_eq "" "$OUT"; assert_dir "$P/demo/.git"
}
test_add_refuses_local_only_branch_and_stash() {
  make_repo demo; cd "$P/demo"; git branch side; echo x >> a.txt; git stash -q
  gs add "$P/demo"; assert_rc 2
  assert_contains "$OUT" "branch not on the remote: side"; assert_contains "$OUT" "1 stashes"
}
test_add_force_overrides_gate() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; git commit -qam two
  gs add "$P/demo" --force; assert_rc 0; gs _call db_ids; assert_eq "$ID" "$OUT"
  assert_file "$P/demo/.git"
}
test_add_unprotected_is_listed_not_converted() {
  make_repo demo --no-remote; gs add "$P/demo" --force; assert_rc 0
  assert_contains "$OUT" "unprotected"; assert_dir "$P/demo/.git"
  gs _call db_ids; assert_eq "$ID" "$OUT"
  mkdir "$P/empty"; git -C "$P/empty" init -q; gs add "$P/empty"; assert_rc 0
  assert_contains "$OUT" "unprotected"
}
test_add_unreachable_remote_changes_nothing() {
  make_repo demo; git -C "$P/demo" remote set-url origin "$T/remotes/missing.git"
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "cannot reach the remote"
  gs _call db_ids; assert_eq "" "$OUT"; assert_dir "$P/demo/.git"
}
test_add_not_a_repo_and_foreign() {
  mkdir "$P/plain"; gs add "$P/plain"; assert_rc 1; assert_contains "$OUT" "no git repo at"
  mkdir "$P/sub"; printf 'gitdir: /elsewhere\n' > "$P/sub/.git"
  gs add "$P/sub"; assert_rc 1; assert_contains "$OUT" "points somewhere else"
  make_repo demo; mkdir "$P/demo/inner"
  gs add "$P/demo/inner"; assert_rc 1; assert_contains "$OUT" "no git repo at"
}
test_add_unprotected_even_when_gate_would_fail() {
  make_repo demo --no-remote; git -C "$P/demo" branch side
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "unprotected"
}
test_add_force_before_path_and_unknown_option() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; git commit -qam two
  gs add --force "$P/demo"; assert_rc 0
  gs add --bogus "$P/demo"; assert_rc 1; assert_contains "$OUT" "unknown option"
  gs add; assert_rc 1
}
test_add_id_clash() {
  make_repo demo
  gs _call db_put "$ID" "hosts/devsite/projects/other" '{}'
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "id clash: $ID"
}
test_add_remotes_json_special_chars() {
  make_repo demo; git -C "$P/demo" remote add "o2" "$T/remotes/it's \"x\".git"
  gs _call add_remotes_json "$P/demo"; assert_rc 0
  assert_eq "$T/remotes/it's \"x\".git" "$(printf '%s' "$OUT" | jq -r '.o2')"
}
test_add_bad_repos_json_stops() {
  make_repo demo; echo '{bad' > "$GIT_SYNC_DATA/repos.json"
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "not valid JSON"
  assert_eq '{bad' "$(cat "$GIT_SYNC_DATA/repos.json")"
}
test_add_converts_to_pointer() {
  make_repo demo; cd "$P/demo"; head="$(git rev-parse HEAD)"; echo x >> a.txt
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "converted"
  assert_file "$P/demo/.git"
  assert_eq "gitdir: $GIT_SYNC_HOME/repos/$ID.git" "$(cat "$P/demo/.git")"
  assert_dir "$GIT_SYNC_HOME/repos/$ID.git"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
  assert_eq " M a.txt" "$(git -C "$P/demo" status --porcelain)"
  gs status; assert_contains "$OUT" "ready"
}
test_add_prints_command_for_other_macs() {
  make_repo demo; gs add "$P/demo"; assert_rc 0
  assert_contains "$OUT" "on your other Macs, from the Dropbox folder, run: git-sync sync hosts/devsite/projects/demo"
  assert_not_contains "$OUT" "$P"
  make_repo "my project's"; gs add "$P/my project's"; assert_rc 0
  assert_contains "$OUT" "git-sync sync 'hosts/devsite/projects/my project'\\''s'"
}
test_add_records_state_for_this_mac() {
  make_repo demo; gs add "$P/demo"; assert_rc 0
  gs _call state_own "$ID"; assert_contains "$OUT" "main"
}
test_add_trashes_conflicted_copies_with_odd_names() {
  make_repo "my project's"; g="$P/my project's/.git"
  cp "$g/index" "$g/index (Radu’s MacBook Pro's conflicted copy 2026-10-14)"
  gs add "$P/my project's"; assert_rc 0
  assert_eq "1" "$(ls "$T/trash" | grep -c 'conflicted copy')"
  assert_eq "0" "$(find "$GIT_SYNC_HOME/repos" -name '*conflicted copy*' | wc -l | tr -d ' ')"
}
test_add_refuses_conflicted_ref_with_unpushed_commit() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; git commit -qam two; lost="$(git rev-parse HEAD)"
  git reset -q --hard origin/main
  printf '%s\n' "$lost" > ".git/refs/heads/main (conflicted copy)"
  gs add "$P/demo" --force; assert_rc 2
  assert_contains "$OUT" "unpushed work from another Mac"
  assert_contains "$OUT" "push that work from the other Mac, then run add again; if you know a copy is stale, move it to the Trash by hand and run add again"
  assert_file "$P/demo/.git/refs/heads/main (conflicted copy)"; assert_dir "$P/demo/.git"
  gs _call db_ids; assert_eq "" "$OUT"
}
test_add_refuses_garbage_ref_copy_and_trashes_nothing() {
  make_repo demo; g="$P/demo/.git"
  cp "$g/index" "$g/index (conflicted copy)"
  : > "$g/refs/heads/x (conflicted copy)"
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "unpushed work from another Mac"
  assert_file "$g/index (conflicted copy)"; assert_file "$g/refs/heads/x (conflicted copy)"
  assert_eq "0" "$(ls "$T/trash" | wc -l | tr -d ' ')"
}
test_add_trashes_conflicted_ref_already_on_remote() {
  make_repo demo; cd "$P/demo"
  git rev-parse HEAD > ".git/refs/heads/main (conflicted copy)"
  gs add "$P/demo"; assert_rc 0; assert_file "$P/demo/.git"
  assert_eq "1" "$(ls "$T/trash" | grep -c 'conflicted copy')"
}
test_add_rolls_back_failed_conversion() {
  make_repo demo; mkdir -p "$GIT_SYNC_HOME"; : > "$GIT_SYNC_HOME/repos"
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "back as it was"
  assert_dir "$P/demo/.git"; gs _call db_ids; assert_eq "" "$OUT"
  assert_eq "" "$(git -C "$P/demo" status --porcelain)"
}
test_add_rolls_back_when_verification_fails() {
  make_repo demo; cd "$P/demo"; head="$(git rev-parse HEAD)"
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = status ] && exit 1; done\nexec /usr/bin/git "$@"\n' > "$T/bin/git"; chmod +x "$T/bin/git"
  PATH="$T/bin:$PATH" gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "back as it was"
  assert_dir "$P/demo/.git"; assert_missing "$GIT_SYNC_HOME/repos/$ID.git"
  assert_eq "$head" "$(/usr/bin/git -C "$P/demo" rev-parse HEAD)"
  gs _call db_ids; assert_eq "" "$OUT"
  assert_eq "0" "$(ls -A "$P/demo" | grep -c 'pointer')"
}
test_add_refuses_when_store_exists() {
  make_repo demo; mkdir -p "$GIT_SYNC_HOME/repos/$ID.git"; echo keep > "$GIT_SYNC_HOME/repos/$ID.git/f"
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "back as it was"
  assert_dir "$P/demo/.git"; assert_eq keep "$(cat "$GIT_SYNC_HOME/repos/$ID.git/f")"
}
test_add_keeps_existing_entry_when_conversion_fails() {
  make_repo demo; gs _call db_put "$ID" "hosts/devsite/projects/demo" '{}'
  mkdir -p "$GIT_SYNC_HOME"; : > "$GIT_SYNC_HOME/repos"
  gs add "$P/demo"; assert_rc 1
  gs _call db_ids; assert_eq "$ID" "$OUT"
}
test_add_rewound_remote_with_ref_copy_refuses() {
  make_repo demo; cd "$P/demo"; first="$(git rev-parse HEAD)"; echo x >> a.txt; git commit -qam two
  git push -q origin main >/dev/null 2>&1; git -C "$T/remotes/demo.git" update-ref refs/heads/main "$first"
  printf '%s\n' "$first" > ".git/refs/heads/z (conflicted copy)"
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "unpushed commits on main: 1"
  assert_dir "$P/demo/.git"; assert_file "$P/demo/.git/refs/heads/z (conflicted copy)"
  gs _call db_ids; assert_eq "" "$OUT"
  assert_eq "0" "$(ls "$T/trash" | wc -l | tr -d ' ')"
}
test_add_force_pushed_branch_with_ref_copy_refuses() {
  make_repo demo; cd "$P/demo"; first="$(git rev-parse HEAD)"; git checkout -q -b feature; echo x >> a.txt; git commit -qam x
  lost="$(git rev-parse HEAD)"; git push -q -u origin feature >/dev/null 2>&1; git checkout -q main; git branch -q -D feature
  git -C "$T/remotes/demo.git" update-ref refs/heads/feature "$first"
  printf '%s\n' "$lost" > ".git/refs/heads/feature (conflicted copy)"
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "unpushed work from another Mac"
  assert_dir "$P/demo/.git"; assert_file "$P/demo/.git/refs/heads/feature (conflicted copy)"
  gs _call db_ids; assert_eq "" "$OUT"
}
test_add_failed_fetch_with_ref_copy_puts_copy_back() {
  make_repo demo; git -C "$P/demo" remote set-url origin "$T/remotes/missing.git"
  git -C "$P/demo" rev-parse HEAD > "$P/demo/.git/refs/heads/main (conflicted copy)"
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "cannot reach the remote"
  assert_file "$P/demo/.git/refs/heads/main (conflicted copy)"; assert_dir "$P/demo/.git"
  assert_eq "0" "$(ls "$T/trash" | wc -l | tr -d ' ')"
  gs _call db_ids; assert_eq "" "$OUT"
}
test_add_packed_refs_copy() {
  make_repo demo; cd "$P/demo"; ok="$(git rev-parse HEAD)"; echo x >> a.txt; git commit -qam two; lost="$(git rev-parse HEAD)"
  git reset -q --hard origin/main
  printf '# pack-refs with: peeled\n%s refs/heads/main\n^%s\n' "$lost" "$ok" > ".git/packed-refs (conflicted copy)"
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "unpushed work from another Mac"
  assert_file "$P/demo/.git/packed-refs (conflicted copy)"; assert_dir "$P/demo/.git"
  printf '# pack-refs with: peeled\n%s refs/heads/main\n%s refs/remotes/origin/gone\n' "$ok" "$lost" > ".git/packed-refs (conflicted copy)"
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "converted"
  assert_eq "1" "$(ls "$T/trash" | grep -c 'packed-refs')"
}
test_add_remote_tracking_ref_copy_is_trashed() {
  make_repo demo; mkdir -p "$P/demo/.git/refs/remotes/origin"
  printf 'ref: refs/remotes/origin/main\n' > "$P/demo/.git/refs/remotes/origin/HEAD (conflicted copy)"
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "converted"
  assert_eq "1" "$(ls "$T/trash" | grep -c 'HEAD (conflicted copy)')"
}
test_add_can_retry_after_refused_ref_copy() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; git commit -qam two; lost="$(git rev-parse HEAD)"
  git reset -q --hard origin/main
  printf '%s\n' "$lost" > ".git/refs/heads/main (conflicted copy)"
  gs add "$P/demo"; assert_rc 2
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "unpushed work from another Mac"
}
test_readd_publishes_changed_remote() {
  make_repo demo; gs add "$P/demo"
  git -C "$P/demo" remote set-url origin "git@example.invalid:u/new.git"
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "database updated"
  gs _call db_remotes "$ID"; assert_eq "origin	git@example.invalid:u/new.git" "$OUT"
}
test_readd_converts_unprotected_once_pushed() {
  make_repo demo --no-remote; gs add "$P/demo"; assert_dir "$P/demo/.git"
  git init -q --bare "$T/remotes/demo.git"
  ( cd "$P/demo" && git remote add origin "$T/remotes/demo.git" && git push -q -u origin main )
  gs add "$P/demo"; assert_rc 0; assert_file "$P/demo/.git"
}
test_readd_trashes_stray_folder_when_store_has_everything() {
  make_repo demo; cp -R "$P/demo/.git" "$T/stray"; gs add "$P/demo"
  "$GIT_SYNC_TRASH" "$P/demo/.git"; cp -R "$T/stray" "$P/demo/.git"
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "moved to the Trash"
  assert_file "$P/demo/.git"
  assert_eq "gitdir: $GIT_SYNC_HOME/repos/$ID.git" "$(cat "$P/demo/.git")"
  assert_eq "$(git -C "$T/remotes/demo.git" rev-parse main)" "$(git -C "$P/demo" rev-parse HEAD)"
}
test_readd_refuses_stray_folder_with_extra_commits() {
  make_repo demo; gs add "$P/demo"; "$GIT_SYNC_TRASH" "$P/demo/.git"
  git clone -q "$T/remotes/demo.git" "$T/c"; ( cd "$T/c" && echo q >> a.txt && git commit -qam extra )
  cp -R "$T/c/.git" "$P/demo/.git"
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "does not"; assert_contains "$OUT" "main"; assert_dir "$P/demo/.git"
}
test_readd_pointer_without_store() {
  make_repo demo; gs add "$P/demo"; use_mac b
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "git-sync sync"
}
test_readd_stray_with_unreachable_remote_never_hits_gate() {
  make_repo demo; cp -R "$P/demo/.git" "$T/stray"; gs add "$P/demo"
  "$GIT_SYNC_TRASH" "$P/demo/.git"; cp -R "$T/stray" "$P/demo/.git"
  git -C "$P/demo" remote set-url origin "$T/remotes/missing.git"
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "moved to the Trash"; assert_file "$P/demo/.git"
}
test_readd_stray_in_read_only_folder_is_left_untouched() {
  make_repo demo; cp -R "$P/demo/.git" "$T/stray"; gs add "$P/demo"
  "$GIT_SYNC_TRASH" "$P/demo/.git"; cp -R "$T/stray" "$P/demo/.git"
  chmod a-w "$P/demo"; gs add "$P/demo"; chmod u+w "$P/demo"
  # With a read-only folder the trash fails first: the .git folder must be untouched.
  assert_rc 1; assert_dir "$P/demo/.git"
}
test_remove_restores_normal_git_folder() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; head="$(git rev-parse HEAD)"
  gs add "$P/demo"; gs remove "$P/demo"; assert_rc 0
  assert_contains "$OUT" "back to a normal .git folder"
  assert_dir "$P/demo/.git"; assert_missing "$GIT_SYNC_HOME/repos/$ID.git"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
  assert_eq " M a.txt" "$(git -C "$P/demo" status --porcelain)"
  gs _call db_ids; assert_eq "" "$OUT"; gs _call state_own "$ID"; assert_eq "" "$OUT"
}
test_remove_unregistered() { make_repo demo; gs remove "$P/demo"; assert_rc 1; assert_contains "$OUT" "not registered"; }
test_remove_unprotected_folder_only_forgets() {
  make_repo demo --no-remote; gs add "$P/demo"; gs remove "$P/demo"; assert_rc 0
  assert_dir "$P/demo/.git"; gs _call db_ids; assert_eq "" "$OUT"
}
test_remove_pointer_without_store() {
  make_repo demo; gs add "$P/demo"; use_mac b
  gs remove "$P/demo"; assert_rc 1; assert_contains "$OUT" "run sync first"
  assert_file "$P/demo/.git"; gs _call db_ids; assert_eq "$ID" "$OUT"
}
test_remove_rejects_extra_args() {
  make_repo demo; gs add "$P/demo"; gs remove "$P/demo" --force; assert_rc 1; assert_contains "$OUT" "usage"
  assert_file "$P/demo/.git"
}
test_remove_foreign_or_none_changes_nothing() {
  make_repo demo; gs add "$P/demo"; printf 'gitdir: /elsewhere\n' > "$P/demo/.git"
  gs remove "$P/demo"; assert_rc 1; assert_eq "gitdir: /elsewhere" "$(cat "$P/demo/.git")"
  gs _call db_ids; assert_eq "$ID" "$OUT"
}
test_remove_path_with_space_and_apostrophe() {
  make_repo "it's a demo"; gs add "$P/it's a demo"; assert_rc 0
  gs remove "$P/it's a demo"; assert_rc 0; assert_dir "$P/it's a demo/.git"
  assert_eq "first" "$(git -C "$P/it's a demo" log -1 --format=%s)"
}
stray_setup() {
  make_repo demo; cp -R "$P/demo/.git" "$T/stray"; gs add "$P/demo"
  "$GIT_SYNC_TRASH" "$P/demo/.git"; cp -R "$T/stray" "$P/demo/.git"
}
assert_stray_refused() {
  assert_rc 2; assert_contains "$OUT" "refused"; assert_dir "$P/demo/.git"
  assert_eq "1" "$(ls -A "$T/trash" | wc -l | tr -d ' ')"
}
test_readd_refuses_stray_with_stash() {
  stray_setup; ( cd "$P/demo" && echo s >> a.txt && git stash -q )
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "refs/stash"
}
test_readd_refuses_stray_with_conflicted_ref_copy() {
  stray_setup; ( cd "$P/demo" && echo z >> a.txt && git commit -qam lost ); lost="$(git -C "$P/demo" rev-parse HEAD)"
  git -C "$P/demo" reset -q --hard HEAD~1
  printf '%s\n' "$lost" > "$P/demo/.git/refs/heads/main (conflicted copy)"
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "conflicted copy"
}
test_readd_refuses_stray_with_garbage_conflicted_copy() {
  stray_setup; printf 'garbage\n' > "$P/demo/.git/refs/heads/main (conflicted copy)"
  gs add "$P/demo"; assert_stray_refused
}
test_readd_refuses_unreadable_stray() {
  stray_setup; ( cd "$P/demo" && echo u >> a.txt && git commit -qam extra )
  mv "$P/demo/.git/HEAD" "$P/demo/.git/HEAD (conflicted copy)"
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "not readable"
}
test_readd_refuses_stray_with_local_tag() {
  stray_setup
  ( cd "$P/demo" && git checkout -q -b tmp && echo t >> a.txt && git commit -qam tagged && git tag keep && git checkout -q main && git branch -q -D tmp && git checkout -q -- . )
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "keep"
}
test_readd_refuses_stray_with_packed_only_branch() {
  stray_setup; ( cd "$P/demo" && git checkout -q -b tmp && echo t >> a.txt && git commit -qam packed && git checkout -q main && git pack-refs --all && git checkout -q -- . )
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "tmp"
}
test_readd_trashes_stray_with_only_stored_work() {
  stray_setup; git -C "$P/demo" tag stored
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "moved to the Trash"; assert_file "$P/demo/.git"
}
test_remove_failed_mv_with_partial_folder_restores_pointer() {
  make_repo demo; gs add "$P/demo"
  mkdir -p "$T/fakebin"; cat > "$T/fakebin/mv" <<'MV'
#!/bin/bash
last="${@: -1}"; first="${@: -2:1}"
case "$first" in */repos/*.git) mkdir -p "$last"; cp "$first/HEAD" "$last/"; exit 1 ;; esac
exec /bin/mv "$@"
MV
  chmod +x "$T/fakebin/mv"
  OUT="$(PATH="$T/fakebin:$PATH" "$SCRIPT" remove "$P/demo" 2>&1)"; RC=$?
  assert_rc 1; assert_contains "$OUT" "pointer is back"
  assert_file "$P/demo/.git"; assert_eq "gitdir: $GIT_SYNC_HOME/repos/$ID.git" "$(cat "$P/demo/.git")"
  assert_dir "$GIT_SYNC_HOME/repos/$ID.git"; gs _call db_ids; assert_eq "$ID" "$OUT"
}
stray_extra_branch() {
  stray_setup; ( cd "$P/demo" && echo e >> a.txt && git commit -qam extra && git branch feature && git reset -q --hard HEAD~1 )
}
test_readd_refuses_stray_with_truncated_branch_file() {
  stray_extra_branch; sha="$(cat "$P/demo/.git/refs/heads/feature")"
  printf '%s' "${sha:0:20}" > "$P/demo/.git/refs/heads/feature"
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "broken ref"
}
test_readd_refuses_stray_with_zero_byte_branch_file() {
  stray_extra_branch; : > "$P/demo/.git/refs/heads/feature"
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "broken ref"
}
test_readd_refuses_stray_with_garbage_branch_file() {
  stray_extra_branch; printf 'not a sha\n' > "$P/demo/.git/refs/heads/feature"
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "broken ref"
}
test_readd_refuses_stray_with_head_copy_holding_missing_commit() {
  stray_setup; ( cd "$P/demo" && echo z >> a.txt && git commit -qam lost ); lost="$(git -C "$P/demo" rev-parse HEAD)"
  git -C "$P/demo" reset -q --hard HEAD~1
  printf '%s\n' "$lost" > "$P/demo/.git/HEAD (conflicted copy)"
  gs add "$P/demo"; assert_stray_refused; assert_contains "$OUT" "not in this Mac's store"
}
test_readd_trashes_stray_with_symbolic_head_copy() {
  stray_setup; printf 'ref: refs/heads/main\n' > "$P/demo/.git/HEAD (conflicted copy)"
  gs add "$P/demo"; assert_rc 0; assert_contains "$OUT" "moved to the Trash"; assert_file "$P/demo/.git"
}
test_readd_refuses_stray_with_garbage_head_copy() {
  stray_setup; printf 'garbage\n' > "$P/demo/.git/HEAD (conflicted copy)"
  gs add "$P/demo"; assert_stray_refused
}
