test_rel_path_forms() {
  mkdir -p "$P/demo/sub"
  gs _call gs_rel_path "$P/demo";   assert_eq "hosts/devsite/projects/demo" "$OUT"
  gs _call gs_rel_path "$P/demo/";  assert_eq "hosts/devsite/projects/demo" "$OUT"
  cd "$P/demo"; gs _call gs_rel_path .; assert_eq "hosts/devsite/projects/demo" "$OUT"
  ln -s "$P/demo" "$T/link"
  gs _call gs_rel_path "$T/link";   assert_eq "hosts/devsite/projects/demo" "$OUT"
  gs _call gs_rel_path "$P/demo/sub"; assert_eq "hosts/devsite/projects/demo/sub" "$OUT"
}
test_rel_path_outside_dropbox() {
  gs _call gs_rel_path "$T/home"; assert_rc 1; assert_contains "$OUT" "not inside Dropbox"
}
test_id_and_store() {
  gs _call gs_id_for "hosts/devsite/projects/feather-note/apple"
  assert_eq "hosts--devsite--projects--feather-note--apple" "$OUT"
  gs _call gs_id_for "hosts/my project's"; assert_eq "hosts--my_project_s" "$OUT"
  gs _call gs_store_for "x--y"; assert_eq "$GIT_SYNC_HOME/repos/x--y.git" "$OUT"
}
test_mac_id_is_stable() {
  gs _call gs_mac_id; first="$OUT"; gs _call gs_mac_id
  assert_eq "$first" "$OUT"; assert_file "$GIT_SYNC_HOME/mac-id"
}
test_mac_id_differs_per_mac() {
  gs _call gs_mac_id; a="$OUT"; use_mac b; gs _call gs_mac_id
  [ "$a" != "$OUT" ] || fail "two Macs share an id"
}
test_display_strips_projects_prefix() {
  gs _call gs_display "hosts/devsite/projects/feather-note/apple"; assert_eq "feather-note/apple" "$OUT"
  gs _call gs_display "hosts/other/x"; assert_eq "hosts/other/x" "$OUT"
}
test_unknown_command() { gs nonsense; assert_rc 1; assert_contains "$OUT" "usage"; }
test_runs_through_symlink() {
  mkdir -p "$T/bin2"; ln -s "$SCRIPT" "$T/bin2/git-sync"
  OUT="$("$T/bin2/git-sync" _call gs_data_dir 2>&1)"; assert_eq "$GIT_SYNC_DATA" "$OUT"
}
test_trash_defaults_to_trash_command() {
  make_repo demo; gs add "$P/demo"; assert_rc 0
  cp "$T/bin/fake-trash" "$T/bin/trash"; unset GIT_SYNC_TRASH
  PATH="$T/bin:$PATH" gs remove "$P/demo"; assert_rc 0
  assert_dir "$P/demo/.git"; assert_file "$T/trash/.git"
}
