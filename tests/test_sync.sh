ID=hosts--devsite--projects--demo
second_mac_ready() { make_repo demo; gs add "$P/demo"; use_mac b; }   # pointer present, no store
test_sync_unregistered() { make_repo demo; gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" "git-sync add"; }
test_sync_rebuilds_without_touching_files() {
  second_mac_ready; cd "$P/demo"; echo local >> a.txt; echo n > new.txt
  before="$(cat a.txt new.txt | shasum)"
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "rebuilt on main"
  assert_eq "$before" "$(cat a.txt new.txt | shasum)"
  assert_eq " M a.txt
?? new.txt" "$(git status --porcelain)"
  assert_eq "origin/main" "$(git rev-parse --abbrev-ref '@{u}')"
  assert_eq "0	0" "$(git rev-list --left-right --count main...origin/main)"
  assert_eq "a.txt" "$(git ls-files)"
}
test_sync_rebuild_writes_missing_pointer() {
  second_mac_ready; "$GIT_SYNC_TRASH" "$P/demo/.git"
  gs sync "$P/demo"; assert_rc 0
  assert_eq "gitdir: $GIT_SYNC_HOME/repos/$ID.git" "$(cat "$P/demo/.git")"
}
test_sync_rebuild_uses_other_macs_branch() {
  make_repo demo; cd "$P/demo"; git checkout -q -b feat; echo f > f.txt; git add f.txt
  git commit -qm feat; git push -q -u origin feat
  gs add "$P/demo"; use_mac b
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "rebuilt on feat"
  assert_eq "" "$(git -C "$P/demo" status --porcelain)"
}
test_sync_rebuild_unreachable_remote_leaves_nothing() {
  second_mac_ready
  jq '.repos[0].remotes.origin = "/nowhere/missing.git"' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"
  mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" "cannot reach"
  assert_missing "$GIT_SYNC_HOME/repos/$ID.git"
  assert_eq "0" "$(ls -A "$GIT_SYNC_HOME/repos" 2>/dev/null | wc -l | tr -d ' ')"
}
test_sync_skips_missing_folder_and_reports_normal_git() {
  gs _call db_put "hosts--devsite--projects--gone" "hosts/devsite/projects/gone" '{"origin":"x"}'
  gs _call sync_one "hosts--devsite--projects--gone"; assert_rc 0; assert_contains "$OUT" "skipped"
  make_repo other; gs _call db_put "hosts--devsite--projects--other" "hosts/devsite/projects/other" '{}'
  gs sync "$P/other"; assert_rc 0; assert_contains "$OUT" "still a normal .git folder"
  assert_dir "$P/other/.git"
}
test_sync_foreign_pointer_and_no_origin_and_leftover_build() {
  second_mac_ready; echo "gitdir: /elsewhere" > "$P/demo/.git"
  gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" ".git points somewhere else"
  echo "gitdir: $GIT_SYNC_HOME/repos/$ID.git" > "$P/demo/.git"
  mkdir -p "$GIT_SYNC_HOME/repos/.building-$ID.git"; echo junk > "$GIT_SYNC_HOME/repos/.building-$ID.git/x"
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "rebuilt on main"
  assert_missing "$GIT_SYNC_HOME/repos/.building-$ID.git"
  assert_dir "$T/trash/.building-$ID.git"
  jq '.repos[0].remotes = {}' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  "$GIT_SYNC_TRASH" "$GIT_SYNC_HOME/repos/$ID.git"
  gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" "no remote in the database"
  assert_eq "0" "$(ls -A "$GIT_SYNC_HOME/repos" | wc -l | tr -d ' ')"
}
test_sync_usage_and_store_present() {
  gs sync; assert_rc 1; gs sync a b; assert_rc 1
  make_repo demo; gs add "$P/demo"; gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "up to date"
}
test_sync_empty_remote_fails_and_cleans() {
  make_repo demo; git init -q --bare "$T/remotes/empty.git"
  gs add "$P/demo"; use_mac b
  jq --arg u "$T/remotes/empty.git" '.repos[0].remotes.origin = $u' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" "nothing to rebuild from"
  assert_eq "0" "$(ls -A "$GIT_SYNC_HOME/repos" | wc -l | tr -d ' ')"
}
test_sync_reset_failure_leaves_nothing() {
  second_mac_ready; cd "$P/demo"; echo local >> a.txt; before="$(cat a.txt | shasum)"
  mkdir -p "$T/gitbin"
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = reset ] && exit 1; done\nexec /usr/bin/git "$@"\n' > "$T/gitbin/git"; chmod +x "$T/gitbin/git"
  PATH="$T/gitbin:$PATH" gs sync "$P/demo"; assert_rc 1
  assert_missing "$GIT_SYNC_HOME/repos/$ID.git"
  assert_eq "0" "$(ls -A "$GIT_SYNC_HOME/repos" | wc -l | tr -d ' ')"
  assert_eq "$before" "$(cat a.txt | shasum)"
}
test_sync_second_remote_unreachable_does_not_block() {
  second_mac_ready
  jq '.repos[0].remotes.backup = "/nowhere/backup.git"' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  gs sync "$P/demo"; assert_rc 0
  assert_contains "$OUT" "rebuilt on main; could not reach backup (/nowhere/backup.git)"
  assert_eq "origin/main" "$(git -C "$P/demo" rev-parse --abbrev-ref '@{u}')"
}
both_macs_ready() { make_repo demo; gs add "$P/demo"; use_mac b; gs sync "$P/demo"; use_mac a; }
commit_push() { ( cd "$P/demo" && echo "$1" >> a.txt && git commit -qam "$1" && git push -q ); }
test_catch_up_moves_forward_without_touching_files() {
  both_macs_ready; commit_push two; sum="$(shasum < "$P/demo/a.txt")"; use_mac b
  assert_eq " M a.txt" "$(git -C "$P/demo" status --porcelain)"
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "moved forward 1 commits"
  assert_eq "" "$(git -C "$P/demo" status --porcelain)"; assert_eq "$sum" "$(shasum < "$P/demo/a.txt")"
}
test_catch_up_up_to_date_and_ahead() {
  both_macs_ready; gs sync "$P/demo"; assert_contains "$OUT" "up to date"
  ( cd "$P/demo" && echo x >> a.txt && git commit -qam local ); head="$(git -C "$P/demo" rev-parse HEAD)"
  gs sync "$P/demo"; assert_contains "$OUT" "1 unpushed commits"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
}
test_catch_up_diverged_changes_nothing() {
  both_macs_ready; commit_push two; use_mac b
  ( cd "$P/demo" && git commit -q --allow-empty -m mine ); head="$(git -C "$P/demo" rev-parse HEAD)"
  gs sync "$P/demo"; assert_contains "$OUT" "diverged: 1 ahead, 1 behind"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
}
test_follows_other_macs_branch() {
  both_macs_ready; sleep 1
  ( cd "$P/demo" && git checkout -q -b feat && echo f > f.txt && git add f.txt && git commit -qm f && git push -q -u origin feat )
  gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "switched to feat (as on Mac A)"
  assert_eq "feat" "$(git -C "$P/demo" symbolic-ref --short HEAD)"
  assert_eq "" "$(git -C "$P/demo" status --porcelain)"
}
test_own_newer_record_wins() {
  both_macs_ready; sleep 1
  ( cd "$P/demo" && git checkout -q -b feat && git push -q -u origin feat ); gs status
  use_mac b; gs sync "$P/demo"; sleep 1
  git -C "$P/demo" checkout -q main; gs sync "$P/demo"
  assert_eq "main" "$(git -C "$P/demo" symbolic-ref --short HEAD)"; assert_not_contains "$OUT" "switched"
}
test_does_not_follow_when_local_has_unpushed() {
  both_macs_ready; use_mac b; ( cd "$P/demo" && git commit -q --allow-empty -m mine ); use_mac a; sleep 1
  ( cd "$P/demo" && git checkout -q -b feat && git push -q -u origin feat ); gs status; use_mac b
  gs sync "$P/demo"; assert_not_contains "$OUT" "switched"
}
test_warns_when_other_mac_has_unpushed_commit() {
  both_macs_ready; ( cd "$P/demo" && echo x >> a.txt && git commit -qam unpushed ); gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "WARNING: Mac A has unpushed work on main"
  gs status; assert_contains "$OUT" "Mac A is on a commit not fetched here"
}
test_warns_when_other_macs_branch_is_not_on_remote() {
  both_macs_ready; sleep 1; ( cd "$P/demo" && git checkout -q -b secret ); gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "Mac A has unpushed work on secret"
  assert_eq "main" "$(git -C "$P/demo" symbolic-ref --short HEAD)"
}
test_detached_head_changes_nothing() {
  both_macs_ready; git -C "$P/demo" checkout -q --detach; head="$(git -C "$P/demo" rev-parse HEAD)"
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "detached HEAD"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
}
test_interrupted_add_gets_its_pointer_back() {
  make_repo demo; gs add "$P/demo"; "$GIT_SYNC_TRASH" "$P/demo/.git"
  gs sync "$P/demo"; assert_rc 0; assert_file "$P/demo/.git"; assert_contains "$OUT" "up to date"
}
test_remote_mismatch_is_reported_not_changed() {
  both_macs_ready; cp -R "$T/remotes/demo.git" "$T/remotes/copy.git"
  git -C "$P/demo" remote set-url origin "$T/remotes/copy.git"
  gs sync "$P/demo"; assert_contains "$OUT" "remote differs from database"
  assert_eq "$T/remotes/copy.git" "$(git -C "$P/demo" remote get-url origin)"
}
test_rebuild_warns_about_other_macs_unpushed_commit() {
  make_repo demo; gs add "$P/demo"; ( cd "$P/demo" && echo x >> a.txt && git commit -qam unpushed ); gs status
  use_mac b; gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "rebuilt on main"
  assert_contains "$OUT" "WARNING: Mac A has unpushed work on main"
  assert_eq "main" "$(git -C "$P/demo" symbolic-ref --short HEAD)"
}
test_not_switching_when_local_branch_has_commits_not_on_remote() {
  both_macs_ready; use_mac b
  ( cd "$P/demo" && git branch feat && git update-ref refs/heads/feat HEAD && git symbolic-ref HEAD refs/heads/feat && git commit -q --allow-empty -m mine && git symbolic-ref HEAD refs/heads/main && git reset -q ); use_mac a; sleep 1
  ( cd "$P/demo" && git checkout -q -b feat && git push -q -u origin feat ); gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "not switching to feat: local feat has commits not on the remote"
  assert_eq "main" "$(git -C "$P/demo" symbolic-ref --short HEAD)"
}
test_pointer_missing_with_store_present_is_restored() {
  both_macs_ready; use_mac b; "$GIT_SYNC_TRASH" "$P/demo/.git"
  gs sync "$P/demo"; assert_rc 0; assert_file "$P/demo/.git"; assert_contains "$OUT" "up to date"
}
test_does_not_follow_branch_with_other_macs_unpushed_commit() {
  both_macs_ready; sleep 1
  ( cd "$P/demo" && git checkout -q -b feat && git push -q -u origin feat && echo y >> a.txt && git commit -qam more ); gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "WARNING: Mac A has unpushed work on feat"
  assert_not_contains "$OUT" "switched"; assert_eq "main" "$(git -C "$P/demo" symbolic-ref --short HEAD)"
}
test_detached_record_on_other_mac_warns_only_when_unpushed() {
  both_macs_ready; git -C "$P/demo" checkout -q --detach; gs status; use_mac b
  gs sync "$P/demo"; assert_not_contains "$OUT" "WARNING"; gs status; assert_not_contains "$OUT" "unpushed work"
  use_mac a; ( cd "$P/demo" && git commit -q --allow-empty -m loose ); sleep 1; gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "WARNING: Mac A has unpushed work on (detached)"
  assert_eq "main" "$(git -C "$P/demo" symbolic-ref --short HEAD)"
}
test_empty_head_record_gives_no_garbage_warning() {
  both_macs_ready; gs _call state_record "$ID" topic ""; use_mac b
  gs sync "$P/demo"; assert_rc 0; assert_not_contains "$OUT" "WARNING"; assert_contains "$OUT" "up to date"
  gs status; assert_not_contains "$OUT" "unpushed work"
}
test_dead_secondary_remote_does_not_block_catch_up() {
  both_macs_ready
  jq '.repos[0].remotes.backup = "/nowhere/backup.git"' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  git -C "$P/demo" remote add backup /nowhere/backup.git
  gs sync "$P/demo"; assert_rc 0; assert_contains "$OUT" "could not reach backup (/nowhere/backup.git)"; assert_contains "$OUT" "up to date"
}
test_catch_up_unreachable_origin_names_it() {
  both_macs_ready
  jq --arg u "$T/remotes/gone.git" '.repos[0].remotes.origin = $u' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  git -C "$P/demo" remote set-url origin "$T/remotes/gone.git"
  gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" "cannot reach $T/remotes/gone.git"
}
test_sync_all_rebuilds_everything_and_prints_table() {
  make_repo one; make_repo two; gs add "$P/one"; gs add "$P/two"; use_mac b
  gs sync-all; assert_rc 0
  assert_contains "$OUT" "one: rebuilt on main"; assert_contains "$OUT" "two: rebuilt on main"
  assert_contains "$OUT" "PROJECT"; assert_eq "2" "$(printf '%s\n' "$OUT" | grep -c ' ready ')"
}
test_sync_all_reports_failures_and_continues() {
  make_repo one; make_repo two; gs add "$P/one"; gs add "$P/two"; use_mac b
  jq '(.repos[] | select(.path|endswith("one")) | .remotes.origin) = "/nowhere.git"' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"
  mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  gs sync-all; assert_rc 1
  assert_contains "$OUT" "two: rebuilt on main"; assert_contains "$OUT" "1 projects failed"
  assert_eq "1 projects failed" "$(printf '%s\n' "$OUT" | tail -n 1)"
}
test_status_lists_leftover_stores() {
  make_repo demo; gs add "$P/demo"; use_mac b; gs sync "$P/demo"; use_mac a
  gs remove "$P/demo"; use_mac b
  gs status; assert_contains "$OUT" "no longer in the database"
  assert_contains "$OUT" "hosts--devsite--projects--demo.git"
}
test_sync_all_lists_projects_to_add_at_the_end() {
  make_repo one; make_repo two; gs add "$P/one"
  gs _call db_put "hosts--devsite--projects--two" "hosts/devsite/projects/two" '{}'
  gs sync-all; assert_rc 0
  assert_contains "$OUT" "to convert, run:"
  assert_eq "$(cd "$(dirname "$SCRIPT")" && pwd -P)/git-sync add $P/two" "$(printf '%s\n' "$OUT" | tail -n 1)"
  assert_not_contains "$OUT" "git-sync add $P/one"
}
test_sync_all_no_add_summary_when_all_converted() {
  make_repo one; gs add "$P/one"
  gs sync-all; assert_rc 0; assert_not_contains "$OUT" "to convert, run:"
}
test_sync_all_rejects_arguments() {
  gs sync-all extra; assert_rc 1; assert_contains "$OUT" "usage"
}
test_sync_all_empty_database() {
  gs sync-all; assert_rc 0; assert_contains "$OUT" "no projects in the database"; assert_contains "$OUT" "PROJECT"
}
test_leftover_skips_building_files_and_registered_and_status_with_path() {
  make_repo demo; gs add "$P/demo"
  mkdir -p "$GIT_SYNC_HOME/repos/.building-x.git" "$GIT_SYNC_HOME/repos/stray.git"; : > "$GIT_SYNC_HOME/repos/file.git"
  gs status; assert_contains "$OUT" "no longer in the database"
  assert_contains "$OUT" "$GIT_SYNC_HOME/repos/stray.git"
  assert_not_contains "$OUT" ".building-x"; assert_not_contains "$OUT" "file.git"; assert_not_contains "$OUT" "hosts--devsite--projects--demo.git"
  gs status "$P/demo"; assert_not_contains "$OUT" "no longer in the database"
}
test_no_leftover_section_when_none() {
  make_repo demo; gs add "$P/demo"; gs status; assert_not_contains "$OUT" "no longer in the database"
}
test_warning_line_has_project_prefix() {
  make_repo demo; gs add "$P/demo"; gs status; use_mac b; gs sync "$P/demo"; gs status; use_mac a
  ( cd "$P/demo" && git commit -q --allow-empty -m loose ); sleep 1; gs status; use_mac b
  gs sync "$P/demo"; assert_contains "$OUT" "demo: WARNING: Mac A has unpushed work on main"
}
test_status_before_fetch_says_not_fetched_not_unpushed() {
  both_macs_ready; ( cd "$P/demo" && echo x >> a.txt && git commit -qam two && git push -q origin main ); gs status; use_mac b
  gs status; assert_contains "$OUT" "not fetched here"; assert_contains "$OUT" "run: git-sync sync"; assert_not_contains "$OUT" "unpushed work"
  gs sync "$P/demo"; assert_rc 0; assert_not_contains "$OUT" "WARNING"
  gs status; assert_not_contains "$OUT" "not fetched"; assert_not_contains "$OUT" "unpushed work"
}
test_unprotected_sync_says_nothing_to_sync() {
  make_repo local --no-remote; gs add "$P/local"; assert_rc 0
  gs sync "$P/local"; assert_rc 0; assert_contains "$OUT" "local: unprotected (no pushed remote); nothing to sync"; assert_not_contains "$OUT" "git-sync add"
}
test_unprotected_repo_gives_no_other_mac_warning_and_no_state() {
  make_repo local --no-remote; gs add "$P/local"; gs status; gs status "$P/local"
  assert_eq "0" "$(ls "$GIT_SYNC_DATA"/state/*.json 2>/dev/null | wc -l | tr -d ' ')"
  use_mac b; gs status; assert_contains "$OUT" "unprotected"; assert_not_contains "$OUT" "unpushed work"
  gs sync "$P/local"; assert_not_contains "$OUT" "WARNING"
}
test_failing_fetch_message_includes_git_error() {
  both_macs_ready; use_mac b
  jq --arg u "$T/remotes/gone.git" '.repos[0].remotes.origin = $u' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  git -C "$P/demo" remote set-url origin "$T/remotes/gone.git"
  gs sync "$P/demo"; assert_rc 1; assert_contains "$OUT" "cannot reach $T/remotes/gone.git: fatal: '$T/remotes/gone.git' does not appear to be a git repository"
  assert_not_contains "$OUT" "and the repository exists"
}
test_rebuild_prints_fetching_progress_to_stderr() {
  make_repo demo; gs add "$P/demo"; use_mac b
  out="$("$SCRIPT" sync "$P/demo" 2>&1 >/dev/null)"; assert_contains "$out" "demo: fetching $T/remotes/demo.git"
}
