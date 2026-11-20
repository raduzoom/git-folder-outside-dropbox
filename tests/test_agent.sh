# Tests for git-sync-agent's run and plist steps. Install/uninstall touch launchd and are
# not run here.
AGENT="$(dirname "$SCRIPT")/git-sync-agent"

agent_setup() {
  export GIT_SYNC_AGENT_LOG="$T/logs/git-sync.log"
  cat > "$T/bin/fake-notify" <<'NOTIFY'
#!/bin/bash
printf '%s\n' "$*" >> "$(cd "$(dirname "$0")/.." && pwd -P)/notices"
NOTIFY
  chmod +x "$T/bin/fake-notify"
  export GIT_SYNC_AGENT_NOTIFY="$T/bin/fake-notify"
}
agent_run() { OUT="$("$AGENT" run 2>&1)"; RC=$?; }
notice_count() { [ -f "$T/notices" ] && wc -l < "$T/notices" | tr -d ' ' || echo 0; }

test_agent_run_logs_sync_all() {
  agent_setup; make_repo demo; gs add "$P/demo"; use_mac b
  agent_run; assert_rc 0
  assert_file "$GIT_SYNC_AGENT_LOG"
  log="$(cat "$GIT_SYNC_AGENT_LOG")"
  assert_contains "$log" "=== "
  assert_contains "$log" "demo: rebuilt on main"
  assert_contains "$log" "PROJECT"
  assert_eq "0" "$(notice_count)" "no notice for a clean run"
}

test_agent_notifies_once_per_problem() {
  agent_setup; make_repo demo; gs add "$P/demo"; use_mac b; gs sync "$P/demo"; use_mac a
  ( cd "$P/demo" && echo x >> a.txt && git commit -qam unpushed ); gs status
  use_mac b
  agent_run; assert_rc 0
  assert_eq "1" "$(notice_count)" "first run notifies"
  assert_contains "$(cat "$T/notices")" "WARNING: Mac A has unpushed work on main"
  agent_run
  assert_eq "1" "$(notice_count)" "same problem does not notify again"
}

test_agent_notifies_again_after_problem_cleared() {
  agent_setup; make_repo demo; gs add "$P/demo"; use_mac b; gs sync "$P/demo"; use_mac a
  ( cd "$P/demo" && echo x >> a.txt && git commit -qam unpushed ); gs status
  use_mac b; agent_run
  use_mac a; ( cd "$P/demo" && git push -q ); gs status
  use_mac b; agent_run; assert_rc 0
  assert_eq "1" "$(notice_count)" "clean run adds no notice"
  use_mac a; ( cd "$P/demo" && echo y >> a.txt && git commit -qam again ); gs status
  use_mac b; agent_run
  assert_eq "2" "$(notice_count)" "a new problem after a clean run notifies"
}

test_agent_notifies_on_failed_project() {
  agent_setup; make_repo demo; gs add "$P/demo"; use_mac b
  jq --arg u "$T/remotes/gone.git" '.repos[0].remotes.origin = $u' "$GIT_SYNC_DATA/repos.json" > "$T/r.json"; mv "$T/r.json" "$GIT_SYNC_DATA/repos.json"
  agent_run; assert_rc 1
  assert_contains "$(cat "$T/notices")" "1 projects failed"
}

test_agent_trims_log() {
  agent_setup; mkdir -p "$T/logs"
  awk 'BEGIN { for (i = 0; i < 40000; i++) print "old line " i " xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }' > "$GIT_SYNC_AGENT_LOG"
  agent_run; assert_rc 0
  size="$(wc -c < "$GIT_SYNC_AGENT_LOG" | tr -d ' ')"
  [ "$size" -lt 1048576 ] || fail "log not trimmed: $size bytes"
  assert_contains "$(tail -n 5 "$GIT_SYNC_AGENT_LOG")" "no projects in the database"
}

test_agent_plist_is_valid() {
  out="$("$AGENT" plist)"; RC=$?; assert_rc 0
  printf '%s\n' "$out" > "$T/agent.plist"
  plutil -lint -s "$T/agent.plist" || fail "plist does not lint"
  assert_contains "$out" "<string>com.git-sync.agent</string>"
  assert_contains "$out" "<string>$AGENT</string>"
  assert_contains "$out" "<key>StartInterval</key>"
  assert_contains "$out" "<integer>900</integer>"
  assert_contains "$out" "<key>RunAtLoad</key>"
}

test_agent_usage() {
  "$AGENT" nonsense >/dev/null 2>&1; RC=$?; assert_rc 1
  "$AGENT" >/dev/null 2>&1; RC=$?; assert_rc 1
}

test_agent_refuses_windows() {
  agent_setup
  OUT="$(GIT_SYNC_UNAME=MINGW64_NT-10.0 "$AGENT" run 2>&1)"; RC=$?
  assert_rc 1; assert_contains "$OUT" "macOS only"
  [ ! -f "$GIT_SYNC_AGENT_LOG" ] || fail "agent ran sync-all on Windows"
}
