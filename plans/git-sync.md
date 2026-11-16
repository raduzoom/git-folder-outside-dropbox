# git-sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A shell tool that keeps each Dropbox project's git data per Mac, outside Dropbox, and rebuilds or catches it up from a shared database of remotes.

**Architecture:** Each registered project's `.git` is a one-line pointer file (synced by Dropbox) to a store in `~/.git-sync/repos/` (local to each Mac). `repos.json` lists projects and remotes; each Mac writes its own `state/<mac-id>.json` with the branch and commit it last saw. The script is a small entry file that sources one library per responsibility.

**Tech Stack:** `/bin/bash` 3.2, `/usr/bin/git`, `/usr/bin/jq`, plus `column`, `uuidgen`, `scutil`, `trash` (all shipped with macOS). Tests are plain bash.

**Spec:** `plans/git-sync-design.md`. Read it first; this plan does not repeat its reasoning.

## Global Constraints

- Bash 3.2 only: no associative arrays, no `mapfile`, no `${var,,}`.
- Never change, restore or delete a working file. The only project file the tool writes is `.git`.
- Never use `rm`, `rmdir`, `unlink`, `find -delete` or `git clean`, in code or in tests. Removals call `$GIT_SYNC_TRASH` (default `trash`).
- Never commit, pull, merge or push on the user's behalf.
- Quote every path. Project and file names contain spaces and apostrophes.
- Shell commands in docs and messages are single-line, no `\` continuation.
- **No commit steps.** This project is not a git repo yet, and the user's rule is "never commit unless asked". Each task ends with the test run instead.
- Phases 4 and 5 touch real repos. Stop and get the user's go-ahead before each conversion.
- Messages go to stdout; errors to stderr as `git-sync: <message>`.
- Exit codes: `0` done, `1` error, `2` refused by the safety gate.

## Review Focus

Inputs the spec implies but does not spell out. Each has a test in the task named.

1. Paths with spaces or apostrophes, in project names and in conflicted-copy file names. Expected: handled like any other path. (Tasks 3, 6)
2. The remote cannot be reached (offline, missing SSH alias). Expected: a message naming the remote, and nothing changed: no half-built store, no pointer written. (Tasks 5, 8)
3. A repo with no commits, or on a detached HEAD. Expected: `status` prints a row; `add` lists a no-commit repo as unprotected; `sync` reports a detached HEAD and changes nothing. (Tasks 4, 5, 9)
4. `repos.json` or a state file is not valid JSON (for instance a Dropbox conflicted copy). Expected: a bad `repos.json` stops the tool with a clear message and is never overwritten; a bad state file is skipped. (Task 2)
5. The path is given as `.`, relative, with a trailing slash, or through a symlink. Expected: it resolves to the same project. A path inside a project is not the project. (Tasks 1, 5)

---

## File Structure

| File | Responsibility |
|---|---|
| `git-sync` | Entry point: find its own folder through symlinks, source `lib/*.sh`, dispatch the command, print usage |
| `lib/env.sh` | Where things are: Dropbox folder, local home, data folder, Mac id and name, path ↔ id |
| `lib/db.sh` | Read and write `repos.json` and the state files |
| `lib/inspect.sh` | Read-only facts about one project |
| `lib/status.sh` | `status` and `scan`: build and print the table |
| `lib/add.sh` | `add`, `add --all`, `remove` |
| `lib/sync.sh` | `sync`, `sync-all` |
| `tests/run.sh` | Runs every `test_*` function in `tests/test_*.sh`, each in a fresh sandbox |
| `tests/helpers.sh` | Sandbox, repo fixtures, two-Mac switch, assertions |
| `tests/test_*.sh` | One file per library |
| `skill/SKILL.md` | The Claude skill |
| `AGENTS.md`, `CLAUDE.md` | Project notes; `CLAUDE.md` is a symlink to `AGENTS.md` |

Environment overrides, used by tests and read in `lib/env.sh` only:

| Variable | Default | Meaning |
|---|---|---|
| `GIT_SYNC_DROPBOX` | `personal.path` from `~/.dropbox/info.json` | Dropbox folder |
| `GIT_SYNC_HOME` | `$HOME/.git-sync` | Local folder for stores and `mac-id` |
| `GIT_SYNC_DATA` | the script's own folder | Holds `repos.json` and `state/` |
| `GIT_SYNC_MAC_NAME` | `scutil --get ComputerName` | Readable Mac name |
| `GIT_SYNC_TRASH` | `trash` | Command that removes a path |

Constant in `lib/env.sh`: `GS_PROJECTS_DIR="hosts/devsite/projects"`, the default for `scan` and the prefix stripped from the PROJECT column.

---

# Phase 1: Foundation (no repo is changed)

### Task 1: Test harness, entry point, `lib/env.sh`

**Files:**
- Create: `git-sync`, `lib/env.sh`, `tests/run.sh`, `tests/helpers.sh`, `tests/test_env.sh`

**Interfaces:**
- Produces, `tests/helpers.sh`:
  - `SCRIPT` is the absolute path of `git-sync`. `fail <message>` fails the current test.
  - `sandbox_setup` makes `$T` (via `mktemp -d`, then resolved with `pwd -P`) with `$T/dropbox/hosts/devsite/projects`, `$T/home/.git-sync`, `$T/data`, `$T/remotes`, `$T/trash`, `$T/parked`; exports the five `GIT_SYNC_*` variables to match (`GIT_SYNC_MAC_NAME="Mac A"`, `GIT_SYNC_TRASH="$T/bin/fake-trash"`, a script that moves its arguments into `$T/trash/`, adding a counter to a name that is already there); exports `GIT_CONFIG_GLOBAL="$T/gitconfig"` with `init.defaultBranch=main`, `user.name`, `user.email`; sets `P="$T/dropbox/hosts/devsite/projects"`.
  - `make_repo <name> [--no-remote]` creates `$P/<name>` with a normal `.git` folder, one commit of `a.txt`, pushed to bare `$T/remotes/<name>.git` as `origin` with upstream set. Prints nothing.
  - `use_mac <a|b>` parks the current `$T/home/.git-sync` under `$T/parked/<current>` and brings in the other; sets `GIT_SYNC_MAC_NAME` to `Mac A` or `Mac B`. Starts as `a`.
  - `gs <args...>` runs the script; sets `OUT` (stdout and stderr together) and `RC`.
  - `assert_eq <expected> <actual> [label]`, `assert_contains <text> <needle>`, `assert_not_contains <text> <needle>`, `assert_rc <code>`, `assert_file <path>`, `assert_dir <path>`, `assert_missing <path>`. A failed assertion prints the label and both values and fails the test.
- Produces, `tests/run.sh [filter]`: runs each `test_*` function in a subshell after `sandbox_setup`; prints `PASS name` or `FAIL name`; exits `1` if any failed. Sandboxes are left in place (no deletion).
- Produces, `lib/env.sh`:
  - `gs_die <message>` prints `git-sync: <message>` to stderr, exits `1`
  - `gs_dropbox_root` prints the Dropbox folder, symlinks resolved, no trailing slash; dies if it cannot be found
  - `gs_home`, `gs_data_dir` print their folders
  - `gs_mac_id` prints the id in `$(gs_home)/mac-id`; on first call creates it from `uuidgen`, lowercased
  - `gs_mac_name`
  - `gs_rel_path <path>` prints the path relative to the Dropbox folder, symlinks resolved; dies with `not inside Dropbox: <path>` otherwise
  - `gs_abs_path <rel>`
  - `gs_id_for <rel>` replaces `/` with `--`, then every character outside `A-Za-z0-9._-` with `_`
  - `gs_store_for <id>` prints `$(gs_home)/repos/<id>.git`
  - `gs_display <rel>` strips a leading `$GS_PROJECTS_DIR/`
- Produces, `git-sync`: resolves its real folder with a `readlink` loop (so a symlink on `PATH` works), sources `lib/*.sh`, dispatches `status|scan|add|remove|sync|sync-all` to `cmd_<name>` (`sync-all` → `cmd_sync_all`); unknown or missing command prints usage and exits `1`. A hidden command `git-sync _call <function> [args...]` calls one library function, for tests.

- [ ] **Step 1: Write `tests/helpers.sh` and `tests/run.sh`** as specified above.

- [ ] **Step 2: Write the failing tests in `tests/test_env.sh`**

```bash
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
```

- [ ] **Step 3: Run** `bash tests/run.sh`. Expected: every test FAILs (script missing).
- [ ] **Step 4: Implement `git-sync` and `lib/env.sh`** to the interfaces above.
- [ ] **Step 5: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 2: `lib/db.sh`, the database and state files

**Files:**
- Create: `lib/db.sh`, `tests/test_db.sh`

**Interfaces:**
- Consumes: `gs_data_dir`, `gs_mac_id`, `gs_mac_name`, `gs_die`.
- Produces:
  - `db_file` prints `$(gs_data_dir)/repos.json`
  - `db_ids` prints ids, one per line; nothing if the file is missing; dies with `repos.json is not valid JSON; fix it by hand` if it is malformed
  - `db_path <id>` prints the relative path
  - `db_remotes <id>` prints `name<TAB>url` lines
  - `db_id_by_path <rel>` prints the id; returns `1` if absent
  - `db_put <id> <rel> <remotes-json>` inserts or replaces the entry; creates the file with `"version": 1`; writes to a temp file then `mv`
  - `db_delete <id>`
  - `state_file` prints `$(gs_data_dir)/state/$(gs_mac_id).json`
  - `state_record <id> <branch> <head>` writes `{name, repos: {<id>: {branch, head, at}}}`; `at` is UTC `YYYY-MM-DDTHH:MM:SSZ`; rewrites the file only if branch or head differs from what is stored
  - `state_forget <id>` removes the id from this Mac's state file
  - `state_own <id>` prints `branch<TAB>head<TAB>at`, or nothing
  - `state_latest_other <id>` prints `name<TAB>branch<TAB>head<TAB>at` for the newest `at` among every `state/*.json` except this Mac's; nothing if none; files that are not valid JSON are skipped

`repos.json` shape is in the spec, section "The database".

- [ ] **Step 1: Write the failing tests in `tests/test_db.sh`**

```bash
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
```

- [ ] **Step 2: Run** `bash tests/run.sh db`. Expected: FAIL.
- [ ] **Step 3: Implement `lib/db.sh`** with `jq`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 3: `lib/inspect.sh`, facts about one project

**Files:**
- Create: `lib/inspect.sh`, `tests/test_inspect.sh`

**Interfaces:**
- Consumes: `gs_store_for`.
- Produces (every function is read-only, takes the project's absolute path, and silences git's stderr):
  - `repo_kind <abs> <id>` prints `missing` (no such folder), `none` (no `.git`), `folder`, `pointer` (`.git` is a file whose content is exactly `gitdir: $(gs_store_for <id>)`), or `foreign` (any other `.git` file)
  - `repo_here <abs> <id>` prints the HERE value: `folder missing`; `ready` (pointer, store exists); `needs sync` (pointer without store, or kind `none`); `foreign .git`; for a folder, `unprotected` when there is no `origin` remote or no ref under `refs/remotes/origin/`, else `normal .git`
  - `repo_has_git <abs> <id>` returns `0` when git commands can run there (kind `folder`, or `pointer` with its store)
  - `repo_branch <abs>` prints the branch, or `(detached)`
  - `repo_head <abs>` prints the commit id, or nothing for a repo with no commits
  - `repo_uncommitted <abs>` prints the count of `git status --porcelain` lines
  - `repo_ahead <abs>`, `repo_behind <abs>` print counts against `origin/<current branch>`, or `-` when that ref does not exist
  - `repo_unpushed_branches <abs>` prints `branch<TAB>count` for each local branch ahead of its `origin/` namesake
  - `repo_local_only_branches <abs>` prints local branches with no `origin/` namesake
  - `repo_stashes <abs>` prints the count
  - `repo_conflicted_copies <abs>` prints full paths of files inside the git folder whose name contains `conflicted copy`
  - `repo_commit_on_remote <abs> <sha>` returns `0` when some remote branch contains the commit

- [ ] **Step 1: Write the failing tests in `tests/test_inspect.sh`**

```bash
test_kind_and_here() {
  make_repo demo; id="hosts--devsite--projects--demo"
  gs _call repo_kind "$P/demo" "$id"; assert_eq "folder" "$OUT"
  gs _call repo_here "$P/demo" "$id"; assert_eq "normal .git" "$OUT"
  gs _call repo_kind "$P/nope" "$id"; assert_eq "missing" "$OUT"
  mkdir "$P/plain"; gs _call repo_kind "$P/plain" "x"; assert_eq "none" "$OUT"
  make_repo local --no-remote
  gs _call repo_here "$P/local" "hosts--devsite--projects--local"; assert_eq "unprotected" "$OUT"
  mkdir "$P/sub"; printf 'gitdir: /elsewhere\n' > "$P/sub/.git"
  gs _call repo_kind "$P/sub" "x"; assert_eq "foreign" "$OUT"
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
test_detached_and_empty() {
  make_repo demo; git -C "$P/demo" checkout -q --detach
  gs _call repo_branch "$P/demo"; assert_eq "(detached)" "$OUT"
  mkdir "$P/empty"; git -C "$P/empty" init -q
  gs _call repo_head "$P/empty"; assert_eq "" "$OUT"
  gs _call repo_ahead "$P/empty"; assert_eq "-" "$OUT"
}
test_commit_on_remote() {
  make_repo demo; cd "$P/demo"; pushed="$(git rev-parse HEAD)"
  echo x >> a.txt; git commit -qam two; local_only="$(git rev-parse HEAD)"
  gs _call repo_commit_on_remote "$P/demo" "$pushed"; assert_rc 0
  gs _call repo_commit_on_remote "$P/demo" "$local_only"; assert_rc 1
}
```

- [ ] **Step 2: Run** `bash tests/run.sh inspect`. Expected: FAIL.
- [ ] **Step 3: Implement `lib/inspect.sh`.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 4: `status` and `scan`

**Files:**
- Create: `lib/status.sh`, `tests/test_status.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces:
  - `cmd_status [path...] [--fetch]`. No paths: one row per database entry. With paths: those projects, registered or not (id from the database, else from `gs_id_for`). `--fetch` runs `git fetch --quiet --all --prune` first on rows where `repo_has_git`; a failure adds the note `fetch failed`. Calls `state_record` for every registered row that has git and a commit.
  - `cmd_scan [folder]`. Default folder `$(gs_dropbox_root)/$GS_PROJECTS_DIR`. Finds `.git` entries up to five levels deep, does not descend into `.git` or `node_modules`, and prints the same table for projects not in the database. Prints `nothing new under <folder>` when empty. Writes nothing.
  - `status_row <rel> <id> <registered 0|1>` prints one tab-separated row.
  - `status_print` reads rows on stdin, prepends the header, pipes through `column -t -s "$(printf '\t')"`.

Columns, in order: `PROJECT` (`gs_display`), `HERE`, `BRANCH`, `UNCOMMITTED`, `UNPUSHED`, `BEHIND`, `NOTES`. A cell with no value is `-`. Rows without usable git show `-` in the last five columns except NOTES.

NOTES, joined with `; `, in this order: `no remote` | `nothing pushed` (folder kind only); `N conflicted copies`; `local-only branch: a, b`; `unpushed on <branch>: N` for each non-current branch from `repo_unpushed_branches`; `N stashes`; `remote differs from database`; `fetch failed`. Task 9 adds one more. `no remote` means there is no `origin`; `nothing pushed` means `origin` exists but has no branches.

- [ ] **Step 1: Write the failing tests in `tests/test_status.sh`**

```bash
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
  make_repo demo
  gs _call db_put "hosts--devsite--projects--demo" "hosts/devsite/projects/demo" '{}'
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
```

The `awk` checks assume the NOTES cell is `-`; keep that when adjusting fixtures.

- [ ] **Step 2: Run** `bash tests/run.sh status`. Expected: FAIL.
- [ ] **Step 3: Implement `lib/status.sh`.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Phase 1 check

- [ ] Run `./git-sync scan` in this project. Expected: at least the 22 repos from the survey (17 top-level, `feather-note/{apple,universal,website,server}`, `cws/hbg-petrochemicals`); `influencer-prompts` shows `10 conflicted copies` and 3 unpushed; `feather-note/universal` 2, `feather-note/server` 2, `feather-note/website` 1; `graphics-creator` is `unprotected` with `no remote`; `influencer-generator-tool` notes `captions-tab` if it is not on the remote.
- [ ] Confirm nothing in Dropbox was written: no `repos.json`, no `state/`, `git status` unchanged in two sample repos.
- [ ] Report to the user. They can run `./git-sync scan` on the other Mac now.

---

# Phase 2: add and remove

### Task 5: `add`: registration, the gate, unprotected repos

**Files:**
- Create: `lib/add.sh`, `tests/test_add.sh`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `cmd_add <path> [--force]` (and `--all`, Task 12)
  - `add_remotes_json <abs>` prints this repo's remotes as a JSON object `{name: url}`
  - `add_gate <abs>` prints one reason per line and returns `1` if any: `unpushed commits on <branch>: N`, `branch not on the remote: <branch>`, `N stashes`
  - `add_convert <abs> <id>` is Task 6. In this task `cmd_add` stops after the database write with `registered; not converted yet` so the tests below can pass; Task 6 replaces that line.

Flow of `cmd_add` for a `.git` **folder** with no store on this Mac (other cases are Task 7):

1. `gs_rel_path`; id from `db_id_by_path`, else `gs_id_for`. If that id is already in the database under a different path, die with `id clash: <id>`.
2. `repo_kind`: `missing` or `none` → die `no git repo at <path>`; `foreign` → die `.git points somewhere else: <path>`.
3. If the repo has any remote: `git fetch --quiet --all --prune`. On failure die `cannot reach the remote for <path>: <url>`. Nothing has been written at this point.
4. If `repo_here` is `unprotected`: `db_put`, print `<project>: listed as unprotected (no pushed remote); left as a normal .git folder`, return `0`. `--force` does not change this.
5. `add_gate`. If it has reasons and `--force` was not given: print `refused: <project>`, the reasons, and `push these first, or use --force`; return `2`. Nothing is written.
6. `db_put`, then conversion.

- [ ] **Step 1: Write the failing tests in `tests/test_add.sh`**

```bash
ID=hosts--devsite--projects--demo
test_add_registers_clean_repo() {
  make_repo demo; gs add "$P/demo"; assert_rc 0
  gs _call db_path "$ID"; assert_eq "hosts/devsite/projects/demo" "$OUT"
  gs _call db_remotes "$ID"; assert_eq "origin	$T/remotes/demo.git" "$OUT"
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
```

- [ ] **Step 2: Run** `bash tests/run.sh add`. Expected: FAIL.
- [ ] **Step 3: Implement** `cmd_add`, `add_remotes_json`, `add_gate` in `lib/add.sh`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 6: `add`: conflicted copies and conversion with rollback

**Files:**
- Modify: `lib/add.sh`, `tests/test_add.sh`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  - `add_clear_conflicted <abs>`: for each path from `repo_conflicted_copies`, print it, then remove it with `$GIT_SYNC_TRASH`. Before removing anything, check every copy whose path is under `refs/`: its content is a commit id; if `repo_commit_on_remote` fails for it, print `unpushed work from another Mac: <path> (<short id>)` and return `2` with nothing removed. `--force` does not override this.
  - `add_convert <abs> <id>`: remember `repo_head`; `mkdir -p` the store's parent; `mv "<abs>/.git" "<store>"`; write the pointer (`gitdir: <store>` and a newline); verify `git -C <abs> status` succeeds and `repo_head` is unchanged. If the `mkdir` or the `mv` fails, return `1`; the folder has not moved. On a failed check: remove the pointer with `$GIT_SYNC_TRASH`, `mv` the store back, return `1`.
  - `cmd_add` now runs, after the gate: `add_clear_conflicted`, `db_put`, `add_convert`, `state_record`, then prints `<project>: converted` and `on your other Macs run: git-sync sync <path>`. If `add_convert` fails and the entry was new, `db_delete` it and die `conversion failed; <project> is back as it was`.

- [ ] **Step 1: Add the failing tests**

```bash
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
  assert_file "$P/demo/.git/refs/heads/main (conflicted copy)"; assert_dir "$P/demo/.git"
}
test_add_trashes_conflicted_ref_already_on_remote() {
  make_repo demo; cd "$P/demo"
  git rev-parse HEAD > ".git/refs/heads/main (conflicted copy)"
  gs add "$P/demo"; assert_rc 0; assert_file "$P/demo/.git"
}
test_add_rolls_back_failed_conversion() {
  make_repo demo; mkdir -p "$GIT_SYNC_HOME"; : > "$GIT_SYNC_HOME/repos"
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "back as it was"
  assert_dir "$P/demo/.git"; gs _call db_ids; assert_eq "" "$OUT"
  assert_eq "" "$(git -C "$P/demo" status --porcelain)"
}
```

Update the Task 5 tests that expected the folder to remain after a successful `add`: `test_add_registers_clean_repo` and `test_add_force_overrides_gate` now also `assert_file "$P/demo/.git"`.

- [ ] **Step 2: Run** `bash tests/run.sh add`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** `add_clear_conflicted`, `add_convert`, and the rest of `cmd_add`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 7: Re-running `add`, and `remove`

**Files:**
- Modify: `lib/add.sh`, `tests/test_add.sh`

**Interfaces:**
- Produces, further `cmd_add` cases (decided by `repo_kind` and whether the store exists):
  - `pointer`, store present → `db_put` with this Mac's remotes; `state_record`; print `<project>: already converted; database updated`.
  - `pointer`, store missing → die `git data is missing on this Mac; run: git-sync sync <path>`.
  - `folder`, registered, was unprotected, now has a pushed remote → the normal flow from Task 5 step 3 (it converts).
  - `folder`, store **present** (a leftover Dropbox brought back) → for `HEAD` and every local branch tip in the folder, check `git --git-dir=<store> cat-file -e <sha>^{commit}`. All present: remove the folder with `$GIT_SYNC_TRASH`, write the pointer, print `<project>: stray .git folder moved to the Trash`. Any missing: print `refused: the .git folder has commits this Mac's store does not: <branches>`, return `2`.
- Produces `cmd_remove <path>`:
  - Not in the database → die `not registered: <path>`.
  - Kind `folder` (unprotected entry) → `db_delete`, `state_forget`.
  - Kind `pointer` with store → remove the pointer with `$GIT_SYNC_TRASH`, `mv` the store to `<abs>/.git`, `db_delete`, `state_forget`; print `<project>: back to a normal .git folder; Dropbox will sync it to your other Macs again`.
  - Pointer without store → die `git data is missing on this Mac; run sync first, then remove`.

- [ ] **Step 1: Add the failing tests**

```bash
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
}
test_readd_refuses_stray_folder_with_extra_commits() {
  make_repo demo; gs add "$P/demo"; "$GIT_SYNC_TRASH" "$P/demo/.git"
  git clone -q "$T/remotes/demo.git" "$T/c"; ( cd "$T/c" && echo q >> a.txt && git commit -qam extra )
  cp -R "$T/c/.git" "$P/demo/.git"
  gs add "$P/demo"; assert_rc 2; assert_contains "$OUT" "does not"; assert_dir "$P/demo/.git"
}
test_readd_pointer_without_store() {
  make_repo demo; gs add "$P/demo"; use_mac b
  gs add "$P/demo"; assert_rc 1; assert_contains "$OUT" "git-sync sync"
}
test_remove_restores_normal_git_folder() {
  make_repo demo; cd "$P/demo"; echo x >> a.txt; head="$(git rev-parse HEAD)"
  gs add "$P/demo"; gs remove "$P/demo"; assert_rc 0
  assert_dir "$P/demo/.git"; assert_missing "$GIT_SYNC_HOME/repos/$ID.git"
  assert_eq "$head" "$(git -C "$P/demo" rev-parse HEAD)"
  assert_eq " M a.txt" "$(git -C "$P/demo" status --porcelain)"
  gs _call db_ids; assert_eq "" "$OUT"; gs _call state_own "$ID"; assert_eq "" "$OUT"
}
test_remove_unregistered() { make_repo demo; gs remove "$P/demo"; assert_rc 1; assert_contains "$OUT" "not registered"; }
```

- [ ] **Step 2: Run** `bash tests/run.sh add`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the cases and `cmd_remove`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

---

# Phase 3: sync and sync-all

### Task 8: `sync`: rebuild a missing store

**Files:**
- Create: `lib/sync.sh`, `tests/test_sync.sh`

**Interfaces:**
- Consumes: Tasks 1–3; `use_mac` to play the second Mac.
- Produces:
  - `cmd_sync <path>`: `gs_rel_path`, `db_id_by_path` (absent → die `not registered; run: git-sync add <path>`), then `sync_one <id>`.
  - `sync_one <id>` prints one line `<project>: <message>` and returns `0` (done or nothing to do) or `1` (failed). Dispatch:
    - folder not on this Mac → `skipped: folder is not on this Mac`
    - kind `foreign` → `.git points somewhere else` (return `1`)
    - kind `folder` → `still a normal .git folder on this Mac; run: git-sync add <path>`
    - store missing → `sync_rebuild`
    - store present → `sync_catch_up` (Task 9); in this task print `ready`
  - `sync_rebuild <id> <abs>`:
    1. Build in `$(gs_home)/repos/.building-<id>.git`; if a leftover exists from an interrupted run, remove it with `$GIT_SYNC_TRASH` first. `git init -q --bare`, then `core.bare false`.
    2. Add each remote from `db_remotes`. No `origin` in the database → `nothing to rebuild from: no remote in the database` (return `1`).
    3. `git fetch --quiet --all`. On failure remove the build folder, print `cannot reach <url>`, return `1`.
    4. Choose the branch: the branch from `state_latest_other`, if `refs/remotes/origin/<branch>` exists; else the remote's default (`git remote set-head origin --auto`, then read `refs/remotes/origin/HEAD`); else `main`.
    5. Point `refs/heads/<branch>` at `refs/remotes/origin/<branch>` and `HEAD` at the branch.
    6. `mv` the build folder to the store. Write the pointer if `.git` is absent.
    7. In the project: `git reset -q` (refreshes git's file list, touches no file), then set the branch's upstream to `origin/<branch>`.
    8. `state_record`; print `rebuilt on <branch>`.

- [ ] **Step 1: Write the failing tests in `tests/test_sync.sh`**

```bash
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
  gs sync "$P/demo"; assert_contains "$OUT" "rebuilt on feat"
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
```

- [ ] **Step 2: Run** `bash tests/run.sh sync`. Expected: FAIL.
- [ ] **Step 3: Implement** `cmd_sync`, `sync_one`, `sync_rebuild`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 9: `sync`: catch up, follow the other Mac's branch, warn on unpushed work

**Files:**
- Modify: `lib/sync.sh`, `lib/inspect.sh`, `tests/test_sync.sh`

**Interfaces:**
- Produces, in `lib/inspect.sh`: `repo_other_mac_note <id> <abs>` prints `<Mac name> has unpushed work on <branch> (<7-char id>)`, or nothing. It prints when `state_latest_other` returns a record and either `refs/remotes/origin/<branch>` does not exist or `repo_commit_on_remote <abs> <head>` fails. Uses local data only.
- Produces, in `lib/sync.sh`: `sync_catch_up <id> <abs>`:
  1. Write the pointer if `.git` is absent (an interrupted `add`).
  2. `git fetch --quiet --all --prune`. On failure print `cannot reach the remote`, return `1`.
  3. If any remote URL differs from `db_remotes`, add `remote differs from database` to the message. Change nothing.
  4. If `repo_other_mac_note` prints, print `WARNING: <note>. Push from there before committing here.` on its own line.
  5. `(detached)` → message `detached HEAD; nothing changed`; stop.
  6. Follow the branch, when all hold: the other Mac's record names a different branch; this Mac has no own record or the other's `at` is later; `refs/remotes/origin/<their branch>` exists; `repo_ahead` for the current branch is `0`. Then: create the local branch at `origin/<branch>` if it does not exist, point `HEAD` at it, `git reset -q`, set upstream. Message part: `switched to <branch> (as on <Mac name>)`.
  7. Compare the current branch with `origin/<branch>`: ref missing → `branch <b> is not on the remote`; behind only → `git reset -q refs/remotes/origin/<b>` and `moved forward N commits`; ahead only → `N unpushed commits`; both → `diverged: N ahead, M behind; nothing changed`; neither → `up to date`.
  8. `state_record`.

Message parts are joined with `; `.

- [ ] **Step 1: Add the failing tests**

```bash
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
  gs status; assert_contains "$OUT" "Mac A has unpushed work on main"
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
```

The status assertion in `test_warns_when_other_mac_has_unpushed_commit` needs the note from Task 10; add it to `status_row` in this task, right after `fetch failed`.

- [ ] **Step 2: Run** `bash tests/run.sh sync`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** `repo_other_mac_note`, `sync_catch_up`, and the status note.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 10: `sync-all` and leftover stores

**Files:**
- Modify: `lib/sync.sh`, `lib/status.sh`, `tests/test_sync.sh`

**Interfaces:**
- Produces:
  - `cmd_sync_all`: `sync_one` for every id in `db_ids`, then a blank line and the `status` table. Returns `1` if any `sync_one` failed, and prints `N projects failed` last.
  - `cmd_status`, when run with no paths: after the table, list every `$(gs_home)/repos/*.git` whose id is not in the database, under the line `Stores on this Mac that are no longer in the database:`. Nothing is printed when there are none. Names starting with `.building-` are skipped.

- [ ] **Step 1: Add the failing tests**

```bash
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
}
test_status_lists_leftover_stores() {
  make_repo demo; gs add "$P/demo"; use_mac b; gs sync "$P/demo"; use_mac a
  gs remove "$P/demo"; use_mac b
  gs status; assert_contains "$OUT" "no longer in the database"
  assert_contains "$OUT" "hosts--devsite--projects--demo.git"
}
```

- [ ] **Step 2: Run** `bash tests/run.sh sync`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

---

# Phase 4: Pilot (real repos; the user's go-ahead before each step)

### Task 11: Prove the Dropbox behaviour, then convert two repos

No code. Every step that changes something waits for the user.

- [ ] **Step 1: Throwaway proof.** Create `~/Dropbox/hosts/devsite/projects/git-sync-throwaway` with one file and `git init`. Do not add a remote. Ask the user to confirm the folder and its `.git` folder have arrived on the other Mac.
- [ ] **Step 2:** On this Mac, move its `.git` folder to `~/.git-sync/throwaway.git` and write a pointer file in its place. Ask the user what the other Mac shows: expected, the `.git` folder is gone and a `.git` file is there. If Dropbox does anything else (keeps the folder, makes a conflicted copy), **stop**: the spec's "Not yet tested" assumption is wrong and the design needs another look before any real repo is converted.
- [ ] **Step 3:** Move the throwaway project and `~/.git-sync/throwaway.git` to the Trash.
- [ ] **Step 4: Other Mac first.** The user runs, on the other Mac: `~/Dropbox/hosts/devsite/projects/git-sync/git-sync status ~/Dropbox/hosts/devsite/projects/gpt-image-2-seedance-storyboard-skill ~/Dropbox/hosts/devsite/projects/promo-builder --fetch`. Both rows must show `0` unpushed and no local-only branches or stashes. If not, they push there first.
- [ ] **Step 5:** With the other Mac idle and Dropbox up to date on both, run here: `./git-sync add ~/Dropbox/hosts/devsite/projects/promo-builder`. Expected: `converted`. Then `git -C ~/Dropbox/hosts/devsite/projects/promo-builder status` works.
- [ ] **Step 6:** The user runs on the other Mac: `~/Dropbox/hosts/devsite/projects/git-sync/git-sync sync ~/Dropbox/hosts/devsite/projects/promo-builder`. Expected: `rebuilt on main`, and `git status` there is clean.
- [ ] **Step 7: Round trip.** Commit and push a small change on one Mac; on the other run `sync`. Expected: `moved forward 1 commits` and a clean `git status`. Repeat in the other direction.
- [ ] **Step 8:** Repeat steps 5–7 for `gpt-image-2-seedance-storyboard-skill` (it has one uncommitted file; it must still be uncommitted and unchanged afterwards).
- [ ] **Step 9:** After a day of normal use, run `./git-sync status` on both Macs. Expected: both `ready`, and `find` shows no `conflicted copy` files in either project or in this project's `state/`.
- [ ] **Step 10:** Report to the user and get the go-ahead for Phase 5. If anything looked wrong, `./git-sync remove <path>` puts a pilot repo back.

---

# Phase 5: Rollout

### Task 12: `add --all`

**Files:**
- Modify: `lib/add.sh`, `lib/status.sh`, `tests/test_add.sh`

**Interfaces:**
- Consumes: the repo-finding part of `cmd_scan`. Extract it as `scan_find <folder>`, printing the absolute path of each unregistered project, and have `cmd_scan` use it.
- Produces: `cmd_add --all <folder> [--force]` runs the single-project `add` on each path from `scan_find`, each in a subshell so one failure does not stop the rest. It tells the three outcomes apart by exit code and, for exit `0`, by the `listed as unprotected` line. Ends with three lines: `converted: N`, `unprotected: N`, `refused or failed: N`, then the refused projects by name. Returns `0` if none were refused or failed, else `2`.

- [ ] **Step 1: Add the failing test**

```bash
test_add_all_converts_clean_and_reports_the_rest() {
  make_repo clean; make_repo dirty; make_repo local --no-remote
  ( cd "$P/dirty" && echo x >> a.txt && git commit -qam unpushed )
  gs add --all "$P"; assert_rc 2
  assert_contains "$OUT" "converted: 1"; assert_contains "$OUT" "unprotected: 1"
  assert_contains "$OUT" "refused or failed: 1"; assert_contains "$OUT" "dirty"
  assert_file "$P/clean/.git"; assert_dir "$P/dirty/.git"; assert_dir "$P/local/.git"
}
```

- [ ] **Step 2: Run** `bash tests/run.sh add_all`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.

### Task 13: Convert the remaining repos

No code. The user decides the order and approves each conversion.

- [ ] **Step 1:** On both Macs the user runs `./git-sync scan`, then `./git-sync status <path> --fetch` for any row that shows unpushed work, and pushes what is listed. Known on this Mac: `influencer-prompts` (3), `feather-note/universal` (2), `feather-note/server` (2), `feather-note/website` (1); `influencer-generator-tool` has the branch `captions-tab` to check.
- [ ] **Step 2:** Add the remaining repos one at a time with `./git-sync add <path>`, running `git-sync sync <path>` on the other Mac after each. Start with the small clean ones; leave `influencer-prompts` (ten conflicted copies, 440 MB) and `skool-scraper` (233 MB) for last.
- [ ] **Step 3:** `graphics-creator` and `influencer-prompts-generator` stay unprotected. Tell the user what each needs: a remote, or a first push.
- [ ] **Step 4:** Run `./git-sync status` on both Macs. Expected: every converted project `ready` on both.

---

# Phase 6: Skill and housekeeping

### Task 14: The Claude skill, the command on `PATH`, project notes

**Files:**
- Create: `skill/SKILL.md`, `AGENTS.md`; symlink `CLAUDE.md` → `AGENTS.md`

- [ ] **Step 1:** Read `~/Dropbox/Configs/claude/.claude/guides/writing-skills.md` and follow it.
- [ ] **Step 2: Write `skill/SKILL.md`.** Name `git-sync`. The description triggers on: adding a Dropbox project to git-sync, "sync my repos", "what's unpushed", setting up git on a new Mac, and a "not a git repository" error inside `~/Dropbox`. The body tells the agent to:
  - call the script by its Dropbox path, found with `jq -r .personal.path ~/.dropbox/info.json`, followed by `/hosts/devsite/projects/git-sync/git-sync`;
  - run `status`, `scan` and `sync` freely;
  - ask before `add`, `add --all` and `remove`, because each changes what the other Macs see;
  - never pass `--force` unless the user says so in that message;
  - show the user the table as printed, and relay any `WARNING:` line in full;
  - remind the user of the habit when it applies: `status` and push before leaving a Mac, `sync-all` on arriving at the other.
- [ ] **Step 3: Write `AGENTS.md`.** Sections: what this tool is (two lines, pointing to `plans/git-sync-design.md`); the commands; how to run the tests (`bash tests/run.sh`, optional name filter); the environment overrides table; "When changing the script": bash 3.2 only, no `rm`, never touch working files; the habit and the known limits, copied from the spec; "On a new Mac": wait for Dropbox, then the two one-time commands from steps 4 and 5 and `git-sync sync-all`.
- [ ] **Step 4:** With the user's go-ahead, link the command: `mkdir -p ~/.local/bin` then `ln -s ~/Dropbox/hosts/devsite/projects/git-sync/git-sync ~/.local/bin/git-sync`. Check: `git-sync status` works from another folder, and so does `git sync status`.
- [ ] **Step 5:** With the user's go-ahead, link the skill: `ln -s ~/Dropbox/hosts/devsite/projects/git-sync/skill ~/.claude/skills/git-sync`. Check: a new Claude session lists the `git-sync` skill.
- [ ] **Step 6:** Give the user both commands for the other Mac, ready to paste.

### Task 15: The global rule, and this project's own repo

**Files:**
- Modify: `~/Dropbox/Configs/claude/AGENTS.md:18`

- [ ] **Step 1:** With the user's go-ahead, replace the row

  ```
  | Work in a git repo inside `~/Dropbox/` | Mark the index ignored on each machine: `xattr -w com.dropbox.ignored 1 <repo>/.git/index` |
  ```

  with

  ```
  | Work in a git repo inside `~/Dropbox/` | Check it with `git-sync status <repo>`. If it is not registered, say so and offer `git-sync add <repo>`; never run `add` or `remove` without the user's yes, because both change the other Macs. On "not a git repository", run `git-sync sync <repo>`. |
  ```

- [ ] **Step 2:** Ask the user whether to make this project a git repo. If yes: they create an empty GitHub repo and give the SSH URL; then `git init -b main`, add the remote, and stop for them to ask for the first commit. After the first push, `git-sync add` this project too. `state/*.json` stays tracked or ignored at the user's choice; recommend ignoring it, since it changes on every run.
- [ ] **Step 3:** Final check: `bash tests/run.sh` passes, and `git-sync status` on both Macs shows every converted project `ready`.

---

## Note: test on this project itself

This project can serve as a live test case. Its remote is `git@github-personal:raduzoom/git-folder-outside-dropbox.git`. Once the user asks for the first commit and push (Task 15, step 2), run `git-sync add` on this folder and `git-sync sync` on the other Mac. That exercises the whole flow on a repo where a mistake costs nothing.
