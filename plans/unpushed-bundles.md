# Carrying unpushed commits between Macs

Status: proposed 2026-11-18, not approved. When approved, it amends
[git-sync-design.md](git-sync-design.md). Until then the design doc wins.

## Why

Dropbox brings a Mac's working files to the other Macs, but not its commits.
When a Mac commits and doesn't push, the other Macs get the files as
uncommitted changes and a warning:

```
gutenberg-writer: WARNING: Radu MBR14 has unpushed work on main (a447c53). Push from there before committing here.
```

On 2026-11-18 this blocked two projects on MBR16M1MAX (gutenberg-writer from
MBR14, gpt-image-prompter from MBR16 M4). The Mac that made the commit was not
at hand, and SSH between the Macs isn't set up. Today there are two ways out:

- Wait until you're back at that Mac and push from there.
- Commit the same files again here and push. The other Mac's commit then
  diverges from GitHub and has to be dropped there with
  `git reset origin/<branch>`. This Mac keeps warning until that Mac syncs.

## Goals

- A commit made on one Mac and not pushed can be pushed from any other Mac,
  as the same commit, with its message and author intact.
- The warning goes away once GitHub has the work, whichever Mac pushed it.
- Nothing about the safety rules changes. No working file is touched, and the
  tool never commits, pushes, merges or pulls.

## Non-goals

- Stashes, local-only branches other than the recorded one, git config and
  hooks. These stay per Mac, as now.
- Pushing automatically, on any Mac.
- Git hooks. The design decided "branches are recorded on every run; no git
  hooks", and that still holds. A commit is carried only once its Mac has run
  `status`, `sync` or the agent after making it.

## How it works

### 1. Each Mac publishes its unpushed commits as a bundle

Whenever this Mac records its branch and commit for a project (the existing
`state_record`, which `status`, `sync` and `sync-all` all call), it also checks
whether that commit is on a remote (`repo_commit_on_remote`).

- **If it isn't,** it writes a git bundle of the commits that are on this branch
  and on no remote:
  `git bundle create <tmp> refs/heads/<branch> --not --remotes`.
- **If it is,** it moves any old bundle for this project to the Trash
  (`$GIT_SYNC_TRASH`).

Where it goes, in this project folder (Dropbox-synced, already gitignored
under `state/`):

```
state/bundles/<mac-id>/<project-id>.bundle
```

Only one Mac ever writes a given file, so Dropbox can't make conflicted copies
of it, the same rule as `state/<mac-id>.json`.

The bundle is written to `~/.git-sync/tmp/` first and checked with
`git bundle verify`. Only then is it moved into place, and only then is the
state record updated. The record gains two fields:

```json
"hosts--devsite--projects--gutenberg-writer": {
  "branch": "main", "head": "a447c53…", "at": "…",
  "bundle": { "head": "a447c53…", "bytes": 48213 }
}
```

The bundle is rewritten only when the recorded head changes or the file is
missing. That keeps `status` fast.

**Size cap.** If the bundle would be larger than 25 MB, it isn't kept. The
record says `"bundle": { "skipped": "too large", "bytes": … }`, and the other
Macs keep today's warning with "(too large to carry)" added. This leaves out
influencer-prompts-style commits of large generated files. The cap can be
overridden with `GIT_SYNC_BUNDLE_MAX` (bytes).

### 2. Other Macs pick the bundle up during sync

During `sync` (catch-up and rebuild), after the fetch, for the latest other
Mac's record (`state_latest_other`):

1. Its commit is already on the remote, so there is nothing to do. Delete any
   local `refs/git-sync/…` ref for that Mac and project.
2. Its record has a `bundle`, the bundle file exists, and the bundle's tip
   (from `git bundle list-heads`) equals the recorded head. Then:
   `git fetch <bundle> refs/heads/<branch>:refs/git-sync/<mac-id>/<branch>`.
3. Otherwise, skip it quietly. Dropbox hasn't delivered the file yet, or the
   file is from an older commit. The next sync tries again.

The fetched commits go under `refs/git-sync/`, never `refs/remotes/`. This
matters because `repo_commit_on_remote` treats anything under `refs/remotes/`
as pushed. Putting the bundle there would hide the warning before anything
reached GitHub.

The warning changes when the commit is present but not adopted:

```
gutenberg-writer: Radu MBR14 has unpushed work on main (a447c53); its commits are here: run git-sync adopt gutenberg-writer, then push
```

`status` NOTES says the same thing in short form:
`Radu MBR14: unpushed a447c53, adoptable`.

### 3. `git-sync adopt <path>` moves this Mac onto that commit

`adopt` is a new command. It changes only git's branch pointer and index,
like the existing "follow the other Mac's branch" step in sync.

It refuses, changing nothing, unless all of these hold:

- The project is registered and `ready` on this Mac.
- The other Mac's commit is present under `refs/git-sync/` (run `sync` first).
- This Mac is on the same branch the other Mac recorded.
- This Mac's commit is an ancestor of the other Mac's, so this is a pure
  move forward. If this Mac has unpushed commits of its own that the other
  Mac doesn't have, it reports "both Macs have unpushed commits on <branch>"
  and stops.
- **Files check.** Take every file that changed between this Mac's commit and
  the other Mac's. The working file here must match that file in the other
  Mac's commit. If any differ, it lists them (at most 10, then a count) and
  says either Dropbox hasn't finished delivering them or they were edited here
  since. `--force` skips this check only. Files are still not touched, so the
  differences just show as uncommitted.

If it goes ahead, it:

1. Moves `refs/heads/<branch>` to the other Mac's commit, using the existing
   `sync__move_ref`, which checks the old value.
2. Runs `git reset -q` to refresh the index. Staged changes are cleared, and
   it says so. This is the same behaviour as sync's move, plus the one-line
   notice already listed as a deferred fix.
3. Records the new head in this Mac's state file.
4. Prints: `adopted 2 commits from Radu MBR14 (a447c53); now 2 unpushed, push when ready`.

You then push from this Mac as usual. On the other Mac, the next `sync` finds
its commit on the remote and reports "up to date", with no divergence and no
reset. If that Mac committed more on top in the meantime, it is simply ahead.
If it amended or rebased the commit, it shows "diverged", which is what
happens today.

### 4. Recognising work that was re-committed instead of adopted

This covers the case where someone commits the same files here instead of
adopting, which is what you'd do today. The other Mac's commit never reaches
GitHub, so the warning stays forever.

It adds one more check, reported only and done locally after a fetch.

- **What it checks.** Take every file that changed between the other Mac's
  commit and the point where it left the remote branch (their merge base).
  Each of those files must be the same on `origin/<branch>` as in the other
  Mac's commit. When that holds, GitHub has all of that commit's changes.
- **This Mac.** The warning becomes the note
  `Radu MBR14's a447c53 is on the remote under another commit` and stops
  saying "push from there". This needs the bundle to be present. Without it,
  the old warning stays.
- **That Mac.** `sync` sees "diverged" and runs the same check on its own
  unpushed commits. If they hold, it reports
  `diverged, but the remote already has these changes: git reset origin/main drops the local commit, files untouched`.
  It never runs the reset itself, because that would drop a commit, which the
  design's anti-goals forbid doing silently.

## Risks

1. **Timing.** Dropbox can deliver the bundle and the files in either order.
   - A bundle without its files is caught by `adopt`'s files check.
   - A bundle that doesn't match the state record is skipped (step 2.3).
   - A state record that arrives before its bundle is skipped too.
2. **Stale bundles.** If the other Mac amends the commit after you adopted and
   pushed, that Mac shows "diverged". Part 4 then tells it what to do, which
   is better than today.
3. **Size.** Bundles duplicate committed data in Dropbox until it's pushed. The
   cap and the cleanup once a commit is on the remote bound this.
4. **Torn file.** A bundle read while Dropbox is still writing it fails
   `git bundle verify` or the tip check, and is skipped.
5. **Cross-volume move.** On the Mac mini, `~/.git-sync` and Dropbox are on
   different volumes, so moving the bundle into place is a copy, not an atomic
   rename. Readers can therefore see a partial file. The verify and the tip
   check cover that. Writing it as `<id>.bundle.partial` and then renaming it
   inside the same folder makes the final step atomic too.
6. **New branch-moving code.** It is held to the existing rules: no working
   file touched, `update-ref` with the old value, and sandbox tests that play
   two Macs.
7. **Coverage.** A commit is carried only after its Mac has run `status`,
   `sync`, the agent, or the VS Code sync-on-open task. Installing
   `git-sync-agent` on every Mac (an open item already) closes most of that
   gap.

## Open questions for Radu

- Should `adopt` stay a separate command, or should `sync` do it on its own
  when the files check passes? The recommendation is to keep it separate:
  sync stays predictable, and adopting is a choice to take over another Mac's
  commit.
- Is a 25 MB cap right?
- Should `sync-all` print one summary line listing the adoptable projects?

## Tests (sandbox, two Macs as in the existing sync tests)

- Mac A commits without pushing, then runs `status`. The bundle exists, the
  record has `bundle.head`, and the bundle verifies.
- Mac A pushes, then runs `status`. The bundle is trashed and the field is
  gone.
- Mac B runs `sync`. The ref lands under `refs/git-sync/`. `status` NOTES says
  "adoptable". `repo_commit_on_remote` is still false.
- `adopt` with the files matching moves the branch forward, shows N unpushed,
  and leaves every working file byte-identical.
- `adopt` refuses when:
  - a file differs (and `--force` then goes ahead);
  - the branch is different;
  - Mac B has its own unpushed commit;
  - no bundle has been fetched.
- After Mac B adopts and pushes, Mac A's `sync` reports "up to date".
- A bundle whose tip doesn't match the record, and a truncated bundle, are
  both skipped with no error.
- Going over the size cap gives `skipped: too large` and the old warning.
- Part 4: Mac B commits the same files under another commit and pushes.
  - Mac B's note changes.
  - Mac A's sync reports "remote already has these changes" and moves nothing.
- Every new message follows the existing format, and every removal goes
  through `$GIT_SYNC_TRASH`.

## Rough size

About 200 lines of bash in `lib/` (a new `lib/bundle.sh` plus hooks in
`state_record`, `repo_other_mac_note`, `sync_catch_up` and `sync_rebuild`),
`cmd_adopt`, and about 15 tests. Parts 1 to 3 can ship without part 4.
