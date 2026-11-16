# git-sync

Keeps each Dropbox project's git data per Mac, outside Dropbox. A converted project's `.git` is a one-line pointer file (`gitdir: /Users/raduh/.git-sync/repos/<id>.git`) that Dropbox syncs; the real git data lives in `~/.git-sync/repos/` on each Mac. `repos.json` lists the projects and their remotes; each Mac writes only its own `state/<mac-id>.json`.

- Design (the binding authority): [plans/git-sync-design.md](plans/git-sync-design.md)
- Implementation plan and phases: [plans/git-sync.md](plans/git-sync.md)

## Commands

Run from the `projects` folder (this Mac: `~/Dropbox/hosts/devsite/projects`; Mac mini: `/Volumes/T7/Dropbox/hosts/devsite/projects`):

| Command | What it does |
|---|---|
| `./git-sync/git-sync status [path...] [--fetch]` | Table of registered projects (or the given paths). Offline unless `--fetch`. |
| `./git-sync/git-sync scan` | Git repos under `projects/` not in the database yet. Read-only. |
| `./git-sync/git-sync add <path>` | Register and convert. Refuses (exit 2) on unpushed commits, local-only branches or stashes. |
| `./git-sync/git-sync remove <path>` | Undo `add`: git data back to a normal `.git` folder. |
| `./git-sync/git-sync sync <path>` | Rebuild missing git data, or catch up with the remote. Never commits, pulls, merges or pushes. |
| `./git-sync/git-sync sync-all` | `sync` for every registered project, then the status table. |
| `./git-sync/git-sync-agent install\|uninstall\|status\|run` | Optional per-Mac LaunchAgent: `sync-all` at login and every 15 min, log at `~/Library/Logs/git-sync.log`. |

Never use VS Code's Pull / Sync Changes to catch a converted project up: Dropbox already delivered the files, so a pull trips over them. Use `git-sync sync`.

## The two Macs

- **This Mac (MacBook Pro):** Dropbox at `~/Dropbox`.
- **Mac mini:** Dropbox at `/Volumes/T7/Dropbox` (external T7 drive; must be mounted for `sync`). Give it commands with that path, not `~/Dropbox`.
- Both use the username `raduh`; pointer files hold the absolute `/Users/raduh/...` path, so a Mac with another username cannot use them.
- **SSH on the Mac mini:** plain `github.com` logs in as the `raduzoom-hd` account, which cannot see the `raduzoom` repos. Every repo must use the `github-personal` alias. `~/.ssh/id_github` there had to be `chmod 600` (it was 0644 and ssh ignored it).

## Converting a repo (the procedure that worked)

1. If its remote is `git@github.com:raduzoom/...`, check `git ls-remote --heads git@github-personal:raduzoom/<repo>.git` answers, then `git -C <repo> remote set-url origin git@github-personal:raduzoom/<repo>.git`. The `.git` folder is still Dropbox-synced at this point, so the Mac mini receives the change.
2. On this Mac: `./git-sync/git-sync status <repo> --fetch`. UNPUSHED must be 0; push first (with the user's yes) if not.
3. On the Mac mini: the same command. UNPUSHED 0 and the UNCOMMITTED count should match this Mac. If the counts differ, Dropbox is still syncing that project: hold it back.
4. On this Mac: `./git-sync/git-sync add <repo>` (ask the user before each conversion).
5. On the Mac mini: `./git-sync/git-sync sync-all`; the repo should print `rebuilt on main` and show `ready`.

## Open work

Rollout status, open items and deferred fixes: [action-items.md](action-items.md).

Keep this file lean: it is read every session. Status, action items, progress and history go in their own linked file (like `action-items.md`), never inline here.

## Working on the code

- Tests: `bash tests/run.sh` (all), `bash tests/run.sh <filter>` (substring of a test or file name). Each test runs in a temp sandbox; never point tests at real projects or `~/.git-sync`.
- Overrides used by tests: `GIT_SYNC_DROPBOX`, `GIT_SYNC_HOME`, `GIT_SYNC_DATA`, `GIT_SYNC_MAC_NAME`, `GIT_SYNC_TRASH` (default `trash`), and for the agent `GIT_SYNC_AGENT_LOG`, `GIT_SYNC_AGENT_NOTIFY`.
- `git-sync _call <function> [args]` calls one library function (for tests and checks).
- Rules: bash 3.2 (`/bin/bash`); never `rm`/`rmdir`/`unlink` (removals go through `$GIT_SYNC_TRASH`); never change a working file (the only project file written is `.git`); never `echo "$(cmd)"` or `local x="$(cmd)"` where cmd can fail; run `db__check` before any `db_id_by_path` lookup.
- A conflicted copy of a ref file makes `git rev-list --all` / `--branches` fail with "bad object"; name real refs explicitly when inspecting such a repo.
