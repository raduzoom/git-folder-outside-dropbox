# git-sync design

Status: approved by Radu on 2026-11-12. Nothing is built yet.

## Why

The same Dropbox projects are used from more than one Mac. Dropbox syncs each
repo's `.git` between them, two Macs write the same git files, and the repo
breaks. `influencer-prompts/.git` already holds ten "conflicted copy" files.

The fix is to keep git data per Mac, out of Dropbox, and to keep a shared list
of project → remote so any Mac, including a new one, can rebuild its own git
data from GitHub.

## Goals

- Git data for a registered project never lives in Dropbox.
- A shared database records every project's path and git remotes.
- One command on one folder, or on all of them, makes this Mac's git data
  correct: it builds what is missing and catches up with the remote.
- A status view on demand shows, for every project in the database, what is
  uncommitted, unpushed or behind.
- A new Mac needs no installs: the tool uses only the shell, `git` and `jq`,
  all shipped with macOS.

## Non-goals

- No automatic commit, pull, merge or push. The tool reports; you decide.
- No background job beyond the optional `git-sync-agent` (added 2026-11-13 at Radu's
  request): a per-Mac LaunchAgent that runs `sync-all` at login and every 15 minutes, logs
  to `~/Library/Logs/git-sync.log`, and notifies once per distinct problem. It does
  nothing `sync-all` doesn't do by hand.
- No SSH key or `~/.ssh/config` setup. If a remote can't be reached, the tool
  says which host failed.
- No support for a home folder other than the one the pointer was written
  with (`/Users/raduh` on every Mac, confirmed).
- No rename or move command in this version. See "Left to the builder".
- No syncing of local git config, hooks or stashes between Macs.
- macOS only.

## Anti-goals

These make it a failure even if it works:

- It changes, restores or deletes a working file. Dropbox owns the files.
- It silently drops unpushed commits, local-only branches or stashes.
- It deletes anything with `rm`. Removals go through `trash`.

## Constraints

- Runs on stock macOS: `/bin/bash` 3.2 or `/bin/zsh`, `/usr/bin/git`,
  `/usr/bin/jq`.
- The project lives in Dropbox, so the script and the database reach every
  Mac on their own.
- Dropbox may be at `~/Dropbox` or under `~/Library/CloudStorage`. Database
  paths are relative to the Dropbox folder. Each Mac finds that folder from
  `~/.dropbox/info.json` (`personal.path`).
- Two Macs must never write the same shared file as routine work, or Dropbox
  makes conflicted copies of the tool's own data.

## Approaches

Three ways were considered.

1. **Ignore flag.** `.git` stays a folder in the project, marked
   `com.dropbox.ignored` on each Mac. Standard layout, every tool works. But
   the protection is a hidden flag set per Mac and per repo; if it is ever
   missing, Dropbox syncs `.git` again without a word. Dropbox under
   CloudStorage needs a different flag name. Rebuilding has to flag the folder
   before Dropbox sees it.
2. **Pointer file (picked).** `.git` becomes a one-line file, synced by
   Dropbox, that points to the real git data in a folder outside Dropbox on
   each Mac. Nothing depends on a flag or on which Dropbox install is used. A
   missing store fails loudly ("not a git repository") and sync repairs it.
   The cost: the pointer holds an absolute path, so every Mac needs the same
   home folder, and tools that insist `.git` is a folder break. Git uses the
   same mechanism for worktrees and submodules.
3. **Pointer to a flagged folder inside Dropbox** (the old
   `~/Dropbox/hosts/git-outside.sh`). Carries the downsides of both. Dropped.

Picked: **pointer file**, because its failures are visible and it handles the
CloudStorage case with no extra work.

Checked before picking, in a throwaway folder (git 2.54):

- A pointer with an absolute path works: status, log, commit. No
  `core.worktree` needed. Renaming the project folder keeps it working.
- A pointer using `~` fails.
- History can be rebuilt from a remote for a folder that already has files,
  without touching them; status then shows only the real local edits.
- A flag on `.git/index` is lost on the first `git add`.

Dropbox's help page confirms an ignored item "will be deleted from the Dropbox
server and your other devices".

Not yet tested: what Dropbox does on the other Macs when `.git` changes from a
folder to a file. The expectation is that they lose their `.git` folder and
receive the pointer. Phase 4 proves this on a throwaway Dropbox folder, with
both Macs, before any real repo is converted.

## How it works

### Where things live

In this project (synced by Dropbox):

| Path | What |
|---|---|
| `git-sync` | the script |
| `repos.json` | the database: one entry per project |
| `state/<mac-id>.json` | what each Mac last saw; a Mac writes only its own file |
| `tests/` | the test script |
| `skill/` | the Claude skill (last phase) |
| `AGENTS.md`, `CLAUDE.md` | project notes; `CLAUDE.md` is a symlink |

On each Mac, outside Dropbox:

| Path | What |
|---|---|
| `~/.git-sync/repos/<id>.git` | the real git data for one project |
| `~/.git-sync/mac-id` | a random id made on first run; names this Mac's state file |

In each registered project:

| Path | What |
|---|---|
| `.git` | a file: `gitdir: /Users/raduh/.git-sync/repos/<id>.git` |

### The database

```json
{
  "version": 1,
  "repos": [
    {
      "id": "hosts--devsite--projects--gutenberg-writer",
      "path": "hosts/devsite/projects/gutenberg-writer",
      "remotes": { "origin": "git@github-personal:raduzoom/gutenberg-writer.git" }
    }
  ]
}
```

`id` is made from the path when the project is added, is unique, and never
changes afterwards. The store folder is named after it. `repos.json` changes
only on `add` and `remove`.

Each Mac's state file holds the Mac's readable name and, per project id, the
branch and commit it was on and when. Every command that looks at a project
updates it, `status` included, and only when something changed. This is how
one Mac learns which branch and commit the other was on, without both writing
one file. The file is named by a random id, not the Mac's name, because two
Macs here have names that differ only by case.

### Commands

```
git-sync status [path...] [--fetch]
git-sync scan [folder]
git-sync add <path> [--force]
git-sync add --all <folder>
git-sync remove <path>
git-sync sync <path>
git-sync sync-all
```

**status** prints one row per project in the database (or per given path). It
is offline and instant by default; `--fetch` asks the remotes first. It works
on any git repo, registered or not.

```
PROJECT                    HERE         BRANCH  UNCOMMITTED  UNPUSHED  BEHIND  NOTES
gutenberg-writer           ready        main              3         0       0
influencer-prompts         normal .git  main              4         3       0  5 conflicted copies
feather-note/universal     needs sync   -                 -         -       -
graphics-creator           unprotected  main              2         -       -  no remote
influencer-generator-tool  ready        main              3         0       0  local-only branch: captions-tab
```

HERE is one of: `ready` (pointer and store both present), `needs sync`
(registered, store missing on this Mac), `normal .git` (still a folder),
`folder missing`, `unprotected` (no pushed remote). Stashes show in NOTES.

**scan** lists git repos under a folder, nested ones included, that are not in
the database yet, with the same columns. It defaults to
`hosts/devsite/projects`. Read-only.

**add** registers a project and converts it:

1. The path must be inside Dropbox and contain a `.git`.
2. If `.git` already points to this tool's store, only make sure the project
   is in the database. If it points anywhere else, refuse.
3. Fetch, then run the safety gate. Refuse, and list what to push, when there
   are unpushed commits, branches that are not on the remote, or stashes.
   `--force` overrides this.
4. A repo with no remote, or with nothing pushed, is written to the database
   as unprotected and left as a normal `.git` folder. `--force` does not
   change this.
5. List any "conflicted copy" files inside `.git` and move them to the Trash.
   One exception: a conflicted copy of a branch file whose commit is not on
   the remote is unpushed work from another Mac. Refuse and report it.
6. Write the database entry.
7. Move the `.git` folder to the store, then write the pointer file.
8. Check that `git status` works and the commit is the one from before. If
   not, put the folder back and report.
9. Remind you that the other Macs need `git-sync sync <path>`.

Running `add` again on a project that is already in the database:

- It copies this Mac's remotes into the database. This is how a changed URL,
  or a remote added to an unprotected repo, reaches the other Macs. An
  unprotected repo that now has a pushed remote is converted.
- If `.git` is a folder and this Mac has no store for the project, the folder
  is this Mac's real git data: convert it in place, gate included.
- If `.git` is a folder and this Mac already has a store, the folder is a
  leftover that Dropbox brought back. Move it to the Trash and write the
  pointer, but only when every commit its branches point to is already in the
  store. Otherwise refuse and report.

`add --all <folder>` runs `add` on every repo `scan` finds, and prints which
were converted and which were refused and why.

**remove** undoes `add` for one project on this Mac: it moves the git data
from the store back to a normal `.git` folder and deletes the database entry.
Dropbox then syncs that folder to the other Macs again. Stores left on other
Macs are reported by `status` as no longer in the database.

**sync** makes this Mac's git data right for one project. What it does depends
on what it finds:

| It finds | It does |
|---|---|
| Not in the database | Stops: "run add first" |
| Project folder not on this Mac | Skips it |
| `.git` is still a folder | Reports it; changes nothing |
| Store missing | Rebuilds it (below) |
| Store present | Catches up (below) |

*Rebuild:* create the store, write the pointer if Dropbox has not delivered
it, add the remotes from the database, fetch, choose the branch, point it at
the remote's copy, and refresh git's file list. No working file is touched.
The branch is the one another Mac last recorded for this project; if there is
no record, the remote's default branch.

*Catch up:* fetch, then:

1. If another Mac recorded a different branch more recently than this Mac's
   own record, and this Mac has nothing unpushed on its current branch, switch
   to that branch without touching files.
2. If this Mac's branch is strictly behind the remote's, move it to the
   remote's commit without touching files.
3. If it is ahead, report the number of unpushed commits. If it has diverged,
   or the branch is not on the remote, report that. Change nothing.

A Mac never follows a branch record it wrote itself; its own current branch
wins and the record is updated.

When another Mac's latest record names a branch or a commit that is not on the
remote, that Mac has unpushed work and the files here may contain it.
Catch-up does not switch to that branch. A rebuild still uses that Mac's
branch when the branch exists on the remote, because the files here belong
to it; otherwise the remote's default branch. Either way it prints a warning that names the Mac, the branch and the commit,
and says to push from there before committing here. `status` repeats the
warning in NOTES until the commit shows up on the remote.

Sync sets a store's remotes from the database only when it rebuilds. If an
existing store's remote differs from the database, sync reports it and changes
nothing; `add` on the Mac with the right URL publishes it.

**sync-all** runs sync on every project in the database, then prints the
status table.

### The habit this assumes

Before leaving a Mac: `git-sync status`, and push what it shows as unpushed.
On arriving at the other: `git-sync sync-all`.

### What sync can and cannot bring back

It brings back everything that was pushed. It cannot bring back unpushed
commits, stashes, branches that were never pushed, or local git config and
hooks. The safety gate and the status view exist to keep that list empty.

### Known limits

- A commit made outside these Dropbox folders (on github.com, or from another
  clone) is not in the working files. After sync, git shows those files as
  changed. Restore them from git by hand.
- If sync runs before Dropbox has finished delivering files, git shows the
  not-yet-arrived changes as differences until Dropbox finishes.
- Moving a branch this way clears anything that was staged with `git add` but
  not committed. The edits stay in the files.
- If a project is converted while another Mac is offline with changes inside
  its `.git` folder, Dropbox may bring that folder back. `status` shows the
  project as `normal .git` when this happens.

## Phases

Each phase ends with a check. Phases 4 and 5 touch real repos and stop for
your go-ahead before each conversion.

1. **Foundation, no repo is changed.** Script skeleton, Dropbox-folder
   detection, the database file, the per-Mac id and state file, `status` and
   `scan`, and the test harness. Check: the table matches what a manual look
   at the repos shows. Safe to run on both Macs straight away, and it tells
   you what is unpushed on each. The only thing it writes is this Mac's state
   file.
2. **add and remove.** Registration, the safety gate, trashing conflicted
   copies, conversion to a pointer with rollback, re-running `add`, and the
   undo. Check: tests against temporary repos, including every refusal case,
   a failed conversion, and add followed by remove leaving the repo as it was.
3. **sync and sync-all.** Rebuild, catch up, following another Mac's branch,
   and the unpushed-work warning. Check: tests that play two Macs sharing one
   project folder, including a branch switch, a missing store, and a recorded
   commit that is not on the remote.
4. **Pilot.** First prove the folder-to-file change on a throwaway Dropbox
   folder with both Macs. Then push everything for the two pilot repos on the
   other Mac, `add` `gpt-image-2-seedance-storyboard-skill` and
   `promo-builder` here, and `sync` them there. Check: commit and push on one
   Mac, sync on the other, both show clean; no conflicted copies appear.
5. **Rollout.** Push the unpushed commits found so far (`influencer-prompts`,
   `feather-note/universal`, `feather-note/server`, `feather-note/website`).
   Add the remaining repos one at a time, then build `add --all`. The two
   repos with nothing on GitHub stay unprotected until they have a remote.
6. **Skill and housekeeping.** The Claude skill that calls the script, the
   command on `PATH`, this project's `AGENTS.md`, and the replacement of the
   "mark `.git/index` ignored" rule in `~/Dropbox/Configs/claude/AGENTS.md`
   with "register the repo with `git-sync add`".

## Decisions

Decided by Radu:

- Sync fetches and follows the remote without touching files; it never pulls,
  merges, pushes or commits.
- A missing `.git` is rebuilt from the database; a folder that is not on disk
  is skipped, never cloned.
- `add` refuses on unpushed work unless forced.
- Database paths must survive Dropbox being in a different location.
- One `repos.json` in this folder.
- One shell script first, a thin skill later.
- Pilot repos: `gpt-image-2-seedance-storyboard-skill`, `promo-builder`.
- Pointer-file route.
- Status on demand for the projects in the database.
- Branches are recorded on every run; no git hooks.
- Repos with nothing on GitHub are listed but left alone.
- Conflicted copies inside `.git` go to the Trash on `add`.
- Nothing runs automatically. (Changed 2026-11-13: an optional per-Mac background agent,
  `git-sync-agent install`, runs `sync-all` at login and every 15 minutes.)
- The `AGENTS.md` index rule is replaced in the last phase.
- `remove` exists as the undo for `add`.

Claude's calls, open to correction:

- Git data lives in `~/.git-sync/repos/`.
- Branch records go in one file per Mac under `state/`, so two Macs never
  write the same file. `repos.json` holds only path and remotes.
- A Mac ignores branch records it wrote itself.
- State files are named by a random per-Mac id kept in `~/.git-sync/mac-id`.
- `status` writes this Mac's state file, so the leaving habit also records
  the branch.
- When another Mac's recorded branch or commit is not on the remote, sync
  warns and does not follow it.
- Re-running `add` publishes this Mac's remotes; sync only reports a remote
  that differs.
- A `.git` folder that comes back on a converted project is fixed by `add`,
  as described under that command.
- A conflicted copy of a branch file is trashed only if its commit is on the
  remote.
- The Dropbox folder is read from `~/.dropbox/info.json`.
- `status` works on unregistered repos, and `scan` exists from phase 1, so
  the other Mac can be checked before anything is converted.
- `add` and `sync` stay separate verbs. `sync` never registers a project,
  because converting affects the other Macs.
- Two project folders may share one remote (`image-generator-via-api` and
  `video-generator-via-api` do); each gets its own entry and store.
- This project becomes a git repo of its own and is registered like the rest,
  once you create a remote for it.

## Left to the builder

- Shell choice between bash 3.2 and zsh, and the script's internal layout.
- The exact slug rule for `id`.
- Test layout. The suggested shape: temporary folders, local bare repos as
  remotes, environment overrides for the store, the Dropbox folder, the
  database folder and the Mac name. Two Macs are played by swapping the store
  folder while keeping the project folder.
- Where the command is linked on `PATH` (`~/.local/bin` is writable and on
  `PATH` here) and where the skill is installed (`~/.claude/skills/` has a
  `synced` folder to look at first).
- Wording of messages and the exact table layout.
- Handling of a renamed or moved project. For now: edit `path` in
  `repos.json` by hand; the pointer keeps working because it names the store,
  not the project.
