---
name: jetbrains-sync-on-open
description: Set up a PhpStorm / IntelliJ IDEA (JetBrains) project so it runs `git-sync sync` for itself every time the project opens, through a shared Run Configuration in `.idea/runConfigurations/` plus an entry in `.idea/startup.xml` (Tools | Startup Tasks). Use when the user asks to make a project sync on open in PhpStorm, IDEA or another JetBrains IDE, or to add the git-sync run configuration to a project.
---

# JetBrains IDEs: run git-sync when a project opens

JetBrains IDEs have no `folderOpen` task like VS Code. The equivalent is two shared files in `<project>/.idea/`:

1. `runConfigurations/git-sync_sync_this_project.xml`: a Shell Script **Run Configuration** that runs `git-sync sync <project>`. Its command path is relative to the project, so the same file works on every Mac.
2. `startup.xml`: the **Tools | Startup Tasks** list, which names the configurations to run when the project opens.

Dropbox syncs both, so nothing needs doing per Mac. Do not edit `workspace.xml`; it is per user and the IDE rewrites it constantly.

The VS Code version is the [vscode-sync-on-open skill](../vscode-sync-on-open/SKILL.md). Steps 1 to 3 below are the same as its steps 1 to 3; follow them there ("Find the project", "Work out the command path", "Run the command once, exactly as VS Code will" — the command in step 3 is the same one), then come back here. They give you `ABS` and `REL`.

Run every command from the git-sync folder (the project this skill lives in). Each command is one line.

## 4. Write the run configuration

Create `ABS/.idea/runConfigurations/git-sync_sync_this_project.xml` (make the folder if missing), with `REL` filled in:

```xml
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="git-sync: sync this project" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="$PROJECT_DIR$/REL/git-sync" />
    <option name="SCRIPT_OPTIONS" value="sync &quot;$PROJECT_DIR$&quot;" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="/bin/bash" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="false" />
    <option name="EXECUTE_SCRIPT_FILE" value="true" />
    <envs />
    <method v="2" />
  </configuration>
</component>
```

PhpStorm 2026.3 loaded and ran this template on one project (git-sync itself) and listed it under its name; its fields were not otherwise compared.

If a file with that name already exists, read it and replace it only if it is this configuration.

If the project has no `.idea/` folder at all, the user has not opened it in a JetBrains IDE yet. Create the file anyway; the IDE picks it up on first open.

## 4b. Write the startup entry

Create `ABS/.idea/startup.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="ProjectStartupSharedConfiguration">
    <configurations>
      <configuration id="Shell Script.git-sync: sync this project" name="git-sync: sync this project" />
    </configurations>
  </component>
</project>
```

This is the file PhpStorm 2026.3 wrote when the entry was added through **Settings → Tools → Startup Tasks → +** on one project (git-sync itself). One project, one IDE version; the `id` is `<run configuration type>.<name>`, which is inferred from that single case.

- **`startup.xml` exists:** read it and add the `<configuration …/>` line inside `<configurations>`; keep the others.
- **The IDE has the project open:** it keeps these files in memory and may overwrite your write. Ask the user to close the project first, or to add the entry in the IDE (**Settings → Tools → Startup Tasks → +**, pick "git-sync: sync this project") and check `startup.xml` afterwards.

## 5. Tell the user

Report the files written and the `sync` output from step 3, then:

- **Check once:** in the IDE, **Run | Edit Configurations** should list "git-sync: sync this project" with the right script path, and **Settings → Tools → Startup Tasks** should list it. Closing and reopening the project should run the sync in the Run tool window. If any of that looks wrong, fix it in the IDE, compare the files it rewrote with these templates, and update this skill.
- **Git:** `.idea/` is often in the project's `.gitignore`. If the new files show in `git status`, ask whether to commit them or ignore them; do neither without a yes.
- **VCS view after a rebuild:** if `sync` had to rebuild the git data, the IDE's Git tool window can load before it finishes. **File → Reload All from Disk**, or reopening the project, picks it up.

## Limits

- Startup tasks run when the project itself opens. If the user opens a parent folder or a different module root, it will not run.
- The optional LaunchAgent (`./git-sync-agent install`) already runs `sync-all` at login and every 15 minutes. This adds an immediate sync for one project on open; it does not replace the agent.
