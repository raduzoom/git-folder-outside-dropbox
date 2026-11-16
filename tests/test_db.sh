test_db_put_get_delete() {
  gs _call db_ids; assert_eq "" "$OUT"
  gs _call db_put "p--one" "p/one" '{"origin":"git@h:u/one.git"}'
  gs _call db_put "p--two" "p/two" '{}'
  gs _call db_ids; assert_eq "p--one
p--two" "$OUT"
  gs _call db_path "p--one"; assert_eq "p/one" "$OUT"
  gs _call db_remotes "p--one"; assert_eq "origin	git@h:u/one.git" "$OUT"
  gs _call db_id_by_path "p/two"; assert_eq "p--two" "$OUT"
  gs _call db_id_by_path "p/none"; assert_rc 1
  gs _call db_put "p--one" "p/one" '{"origin":"git@h:u/renamed.git"}'
  gs _call db_remotes "p--one"; assert_eq "origin	git@h:u/renamed.git" "$OUT"
  gs _call db_delete "p--one"; gs _call db_ids; assert_eq "p--two" "$OUT"
  assert_eq "1" "$(jq -r .version "$GIT_SYNC_DATA/repos.json")"
}
test_db_malformed_is_never_overwritten() {
  printf '{ broken' > "$GIT_SYNC_DATA/repos.json"
  gs _call db_ids; assert_rc 1; assert_contains "$OUT" "not valid JSON"
  gs _call db_put "x" "x" '{}'; assert_rc 1
  assert_eq '{ broken' "$(cat "$GIT_SYNC_DATA/repos.json")"
  gs _call db_delete "x"; assert_rc 1
  assert_eq '{ broken' "$(cat "$GIT_SYNC_DATA/repos.json")"
}
test_state_record_only_on_change() {
  gs _call state_record "x" "main" "aaa"; f="$(ls "$GIT_SYNC_DATA/state/"*.json)"
  first="$(jq -r '.repos.x.at' "$f")"; sleep 1
  gs _call state_record "x" "main" "aaa"; assert_eq "$first" "$(jq -r '.repos.x.at' "$f")"
  gs _call state_record "x" "feat" "bbb"
  gs _call state_own "x"; assert_contains "$OUT" "feat	bbb"
  assert_eq "Mac A" "$(jq -r .name "$f")"
}
test_state_latest_other_excludes_self_and_bad_files() {
  gs _call state_record "x" "main" "aaa"
  gs _call state_latest_other "x"; assert_eq "" "$OUT"
  use_mac b; sleep 1; gs _call state_record "x" "feat" "bbb"; use_mac a
  printf 'junk' > "$GIT_SYNC_DATA/state/conflicted copy.json"
  gs _call state_latest_other "x"; assert_contains "$OUT" "Mac B	feat	bbb"
}
test_state_forget() {
  gs _call state_record "x" "main" "aaa"; gs _call state_forget "x"
  gs _call state_own "x"; assert_eq "" "$OUT"
}
test_state_reads_do_not_create_dir() {
  gs _call state_own "x"; gs _call state_latest_other "x"
  assert_missing "$GIT_SYNC_DATA/state"
}
test_state_record_fails_when_mac_id_cannot_be_made() {
  : > "$T/notadir"; export GIT_SYNC_HOME="$T/notadir/home"
  gs _call state_record "x" "main" "aaa"; [ "$RC" != 0 ] || fail "state_record should fail"
  assert_missing "$GIT_SYNC_DATA/state/.json"
  assert_missing "$GIT_SYNC_DATA/state"
}
