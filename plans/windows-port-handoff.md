# Handoff: a Windows version of git-sync

Goal: let a Windows machine (Dropbox at `K:\Dropbox`) keep its git data outside Dropbox for the same registered projects, without changing anything the Macs rely on. Read [git-sync-design.md](git-sync-design.md) first; it is the binding authority for the Mac behaviour.

## Why the Mac tool can't just run on Windows

- `add` replaces a project's `.git` with a synced one-line pointer: `gitdir: /Users/raduh/.git-sync/repos/<id>.git`. Git for Windows can't resolve that path, so in a converted project every git command fails on Windows ("not a git repository").
- The tool is bash 3.2 + `jq` + `trash` + a macOS LaunchAgent. None of that is stock on Windows.
- `git-sync` and `git-sync-agent` refuse to run when `uname -s` is not `Darwin` (Git Bash, MSYS, Cygwin, WSL, Linux), so they can't be called from Windows by accident. Don't remove that guard; the Windows tool is separate code.
- Dropbox root is found from `~/.dropbox/info.json`; on Windows it is `%LOCALAPPDATA%\Dropbox\info.json` (or `%APPDATA%\Dropbox\info.json`).

## The one hard problem

`.git` in a converted project is one synced file holding one absolute path. Windows needs its own path in that spot, and Dropbox will push any edit back to the Macs. Candidate solutions, in order of preference. Test each in a throwaway Dropbox folder with a second machine watching before it touches a real project.

1. **Windows-local `.git` pointer, Dropbox-ignored on Windows.** Mark the `.git` file ignored on Windows (`Set-Content -Path .git -Stream com.dropbox.ignored -Value 1`), then write a local pointer `gitdir: K:/git-sync/repos/<id>.git`. DANGER, verify first: Dropbox may treat ignoring an already-synced file as a delete and remove it from the other machines. If it does, this option breaks every Mac. Never try it on a real project before proving it doesn't.
2. **Environment variables, no `.git` involvement.** A wrapper (`gsgit <project> <git args>`, or a PowerShell function) sets `GIT_DIR=K:\git-sync\repos\<id>.git` and `GIT_WORK_TREE=<project folder>` and runs git. The Mac pointer file is never read or changed. Downside: IDEs and plain `git` in the folder won't work unless launched through the wrapper (or with these variables set in the session).
3. **Separate clone outside Dropbox** with the project's remote, plus a script that copies or mirrors the files. Last resort: it breaks the single working tree.

## Constraints (must not break the Macs)

- Do not edit anything under `git-sync/lib/`, `git-sync/git-sync`, `git-sync/git-sync-agent`, or `tests/`. Put the Windows code in a new folder, for example `git-sync/windows/`, and a new doc beside it.
- `repos.json` is read-only for the Windows tool. `add`, `remove` and any database edit stay Mac-only. Windows adds a project to its own machine only if the project is already in `repos.json` and already converted.
- State: each machine writes only its own `state/<machine-id>.json`. Before Windows writes one, read the Mac code that scans `state/*.json` (`lib/db.sh`, `lib/bundle.sh`, `lib/status.sh`) and confirm an extra file, or an extra `platform` field, can't confuse `status`, `sync-all` or `adopt`. Run `bash tests/run.sh` on a Mac with a sample Windows state file present. If unsure, have Windows write no state at first.
- Never touch the pointer file `.git` in a converted project from Windows unless option 1 has been proven safe.
- Never change a working file. Dropbox owns the files; the only file a Mac tool writes in a project is `.git`.
- Windows removals go through the Recycle Bin (for example `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory` with `SendToRecycleBin`), never `Remove-Item -Recurse -Force`.
- Windows git data lives at a fixed outside-Dropbox path, e.g. `%USERPROFILE%\.git-sync\repos\<id>.git`; don't put it under `K:\Dropbox`.
- Windows remotes: `git@github-personal:raduzoom/...` needs an SSH host alias `github-personal` in `%USERPROFILE%\.ssh\config` and a key with correct permissions. The tool should report a failing host, not set up SSH (design non-goal).

## What to build (minimum useful version)

PowerShell 5.1 (stock) plus `git`; use `ConvertFrom-Json` instead of `jq`. Commands, all read-only except where noted:

- `status [path...]`: for each project in `repos.json`, read uncommitted, unpushed and behind through the chosen mechanism. Offline unless `--fetch`.
- `sync <path>` / `sync-all`: if this machine's git data is missing, build it from the remote, then catch up. Never commit, pull, merge or push (same non-goals as the Mac tool).
- No `add` or `remove` in v1.

Reuse the Mac design's rules: refuse rather than drop unpushed commits, local-only branches or stashes; fail loudly with the host that failed.

## Verification

- Build a throwaway Dropbox folder with a converted sample project; confirm the Mac still sees it as `ready` before and after every Windows step.
- Check the Mac's `git-sync status` and `sync-all` after each Windows run, and `bash tests/run.sh` once at the end.
- Try the Dropbox-ignore behaviour (option 1) only on that sample project.

## Test project: `windows-apps/cache-checker`

Use `/Users/raduh/Dropbox/windows-apps/cache-checker` (Windows: `K:\Dropbox\windows-apps\cache-checker`) as the real-folder test project instead of the video cutter. It is outside `hosts/devsite/projects/`, not in `repos.json`, and not converted, so no Mac depends on its git data. Experiments here (including the Dropbox-ignore test in option 1) can't affect a converted Mac repo.

Known state on 2026-11-20 (checked from the Mac, nothing changed): it has a normal `.git` folder, but `.git/HEAD` is empty, so `git status` on the Mac says "not a git repository". Look at that first: if the repo is damaged, repair or re-clone it before testing, with the user's yes. Its remote and unpushed work are unknown, so check them before converting anything.

Order of work: sample throwaway folder first, then `cache-checker`, then the video cutter. Convert `cache-checker` with the Mac tool only if the Windows mechanism needs a converted project to test against (`add` is Mac-only and asks the user first).

## Context

- Mac-side machines are listed in `macs.md` (local only). Windows: Dropbox at `K:\Dropbox`, projects folder `K:\Dropbox\hosts\devsite\projects`; the Windows username and SSH setup are not recorded yet, so ask the user.
- The project that needs this in the end: `app-windows-video-cutter-and-trimmer`, converted on the Mac on 2026-11-20. It holds the Windows app, so it comes after `cache-checker` has proven the mechanism.
