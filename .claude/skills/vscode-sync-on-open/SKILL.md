---
name: vscode-sync-on-open
description: Set up a VS Code project so it runs `git-sync sync` for itself every time its folder is opened, through a `.vscode/tasks.json` task with `runOn: folderOpen`. Use when the user asks to make a project sync on open in VS Code, to add the git-sync VS Code task to a project, or to auto-run git-sync when VS Code starts for a project.
---

# VS Code: run git-sync when a project opens

Adds one task to `<project>/.vscode/tasks.json` that runs `git-sync sync <project>` when VS Code opens that folder. The command path is relative to the project, so the same file works on every Mac whatever its Dropbox location, and Dropbox syncs it to all of them.

Run every command below from the git-sync folder (the project this skill lives in). Each command is one line.

## 1. Find the project

The user names the project (a path, or a folder name under `projects/`). If they don't, ask which one. Resolve its physical path:

```bash
cd "<project path>" && pwd -P
```

Call the result `ABS`. It must be a folder inside Dropbox; `git-sync` refuses anything else.

## 2. Work out the command path

Get the path from the project to this git-sync folder, so nested projects (like `feather-note/apple`) get the right number of `../`:

```bash
python3 -I -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$(pwd -P)" "ABS"
```

Call the result `REL` (for a project directly under `projects/` it is `../git-sync`). The task's command is `${workspaceFolder}/REL/git-sync`.

## 3. Run the command once, exactly as VS Code will

```bash
"ABS/REL/git-sync" sync "ABS"
```

This proves the relative path works and shows the project's state. `sync` never commits, pulls, merges or pushes. Then:

- `not registered; run: git-sync add …`: the task would fail every time the folder opens. Stop and tell the user. Converting it follows "Converting a repo" in this project's `AGENTS.md`, with the user's yes for each conversion.
- `still a normal .git folder on this Mac`: the task would only print that line on each open. Tell the user and ask whether to set it up anyway.
- `.git points somewhere else` or `nothing to rebuild from`: the project needs fixing first. Stop and tell the user.
- Anything else (`up to date`, `moved forward …`, `rebuilt on …`, `cannot reach …` when offline, a warning about another Mac): the command works. Carry on, and pass any warning on to the user.

## 4. Write the task

The task, with `REL` filled in:

```json
{
  "label": "git-sync: sync this project",
  "type": "process",
  "command": "${workspaceFolder}/REL/git-sync",
  "args": ["sync", "${workspaceFolder}"],
  "runOptions": { "runOn": "folderOpen" },
  "presentation": { "reveal": "silent", "panel": "dedicated", "close": false },
  "problemMatcher": []
}
```

Use `"type": "process"`, not `"shell"`: arguments go straight to the script, so paths with spaces need no quoting.

- **No `.vscode/tasks.json` yet:** create it as `{ "version": "2.0.0", "tasks": [ <the task> ] }`.
- **The file exists:** read it, then add the task to its `tasks` array with Edit. Keep every other task, setting and comment as it is (the file may contain comments and trailing commas, which `jq` cannot parse, so do not rewrite it through `jq`). If a task with the label `git-sync: sync this project` is already there, replace that one task instead of adding a second.

If the file has no comments, check it parses: `/usr/bin/jq empty "ABS/.vscode/tasks.json"`.

## 5. Tell the user

Report the file written and the `sync` output from step 3, then:

- **Git:** `.vscode/tasks.json` is a working file, so git will list it. Ask whether to commit it or add `.vscode/` to the project's `.gitignore`; do neither without a yes.
- **Automatic tasks:** VS Code runs folder-open tasks only in a trusted folder, and may ask once whether to allow automatic tasks. Look up `task.allowAutomaticTasks` in `~/Library/Application Support/Code/User/settings.json`. If it is `"off"`, tell the user the task will not run until it is `"on"`; change the setting only on their yes.
- **Git panel after a rebuild:** VS Code's Git view can load before `sync` finishes. If `sync` had to rebuild the git data, "Developer: Reload Window" or the Source Control refresh button picks it up.

## Limits

- The task runs only when the project folder itself is opened. If the user opens it through a multi-folder `.code-workspace`, say so and ask before setting it up there.
- The optional LaunchAgent (`./git-sync-agent install`) already runs `sync-all` at login and every 15 minutes. This task adds an immediate sync for one project on open; it does not replace the agent.
