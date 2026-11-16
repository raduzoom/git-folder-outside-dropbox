# git-sync

Keeps each Dropbox project's git data per Mac, outside Dropbox. A converted project's `.git` is a one-line pointer file that Dropbox syncs. The real git data lives in `~/.git-sync/repos/` on each Mac.

## Commands

Run from the `projects` folder (`~/Dropbox/hosts/devsite/projects`, or wherever Dropbox is on that Mac). The command comes first, then the path:

| Command | What it does |
|---|---|
| `./git-sync/git-sync status [path...] [--fetch]` | Table of registered projects (or the given paths). Offline unless `--fetch`. |
| `./git-sync/git-sync scan` | Git repos under `projects/` not in the database yet. |
| `./git-sync/git-sync add <path>` | Register and convert a project. |
| `./git-sync/git-sync remove <path>` | Undo `add`: git data back to a normal `.git` folder. |
| `./git-sync/git-sync sync <path>` | Rebuild missing git data, or catch up with the remote. Never commits, pulls, merges or pushes. |
| `./git-sync/git-sync sync-all` | `sync` for every registered project, then the status table. |

Example: `./git-sync/git-sync sync feather-note/apple`

Never use VS Code's Pull / Sync Changes to catch a converted project up. Use `git-sync sync`.

## Auto sync

A LaunchAgent runs `sync-all` at login and every 15 minutes. Install it once on each Mac.

```bash
cd ~/Dropbox/hosts/devsite/projects && ./git-sync/git-sync-agent install
```

| Command | What it does |
|---|---|
| `./git-sync/git-sync-agent install` | Turn auto sync on. |
| `./git-sync/git-sync-agent status` | Show whether it is installed and running. |
| `./git-sync/git-sync-agent run` | Run a sync now. |
| `./git-sync/git-sync-agent uninstall` | Turn auto sync off. |

Log: `~/Library/Logs/git-sync.log`. Check it to find which project failed on a run.

## More

- Design: [plans/git-sync-design.md](plans/git-sync-design.md)
- Agent notes, conversion procedure and test rules: [AGENTS.md](AGENTS.md)
