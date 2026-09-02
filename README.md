# RAPP Refresh

Safely force RAPP Brainstem through a factory install without deleting your
identity, memories, configuration, authentication, or custom agents.

## Install

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/kody-w/rapp-refresh/main/install.ps1 | iex
```

Then run:

```powershell
rapp-refresh
```

For a no-install, one-shot refresh:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/kody-w/rapp-refresh/main/rapp-refresh.ps1 | iex
```

RAPP Refresh asks for confirmation before changing anything. Use
`rapp-refresh -WhatIf` to preview the operation or `rapp-refresh -Yes` for an
unattended run.

## What it does

1. Stops only processes belonging to the current Brainstem installation.
2. Moves the complete `~\.brainstem` tree into a timestamped backup (an atomic
   metadata-only rename with the default same-volume paths).
3. Removes only `brainstem.cmd`, `brainstem.ps1`, and Brainstem's user `PATH`
   entry.
4. Downloads and runs the official installer with `--no-launch`, forcing a new
   source clone, virtual environment, dependency install, CLI install, and
   configuration bootstrap.
5. Restores durable state before Brainstem starts.
6. Keeps the untouched prior installation as a full rollback snapshot.
7. Starts Brainstem under the operation lock, waits until its owned process is
   visible, then releases the lock and opens the healthy local server.

If the installer or data restore fails, RAPP Refresh moves the failed install
aside and restores the previous installation, launchers, and `PATH`.

## Commands

| Command | Result |
| --- | --- |
| `rapp-refresh` | Factory reinstall, restore data, then launch Brainstem |
| `rapp-refresh -NoLaunch` | Factory reinstall and restore data without launching |
| `rapp-refresh -NoBrowser` | Launch and verify Brainstem without opening a browser |
| `rapp-refresh -ResetAuthentication` | Reinstall without restoring Copilot tokens |
| `rapp-refresh -Version v0.6.14` | Reinstall a specific Brainstem release |
| `rapp-refresh -Action Uninstall` | Safe uninstall; retain a complete snapshot |
| `rapp-refresh -Action List` | List snapshots and their restore status |
| `rapp-refresh -Action Restore -Backup <id>` | Replace the active install with a snapshot |
| `rapp-refresh -WhatIf` | Show the target operation without changing the machine |

`-ResetAuthentication` never deletes the old tokens; it leaves them in the
snapshot while forcing the newly installed Brainstem through authentication.

## Data safety

Backups live under:

```text
%USERPROFILE%\.rapp-refresh\backups\<timestamp>-<process-id>\
```

Each backup contains:

- `brainstem\`: the complete prior installation, including unknown or future
  data that RAPP Refresh does not yet recognize
- `metadata\launchers\`: the previous CLI launchers
- `metadata\brainstem-path.json`: whether and how the Brainstem bin entry
  appeared in the user `PATH` (unrelated entries are never rolled back)
- `manifest.json`: version, size, status, installer hash, and restore results

The following state is restored automatically over the clean install:

- `.brainstem_data` memories and local storage
- `soul.md` and prior soul backups
- `.env`, model selection, book, secret, and voice state
- in-install custom paths referenced by `SOUL_PATH` and `AGENTS_PATH`
- Copilot token/session state unless `-ResetAuthentication` is used
- user-created and modified Python agents
- prior `recovery` records

When a modified agent has the same name as a fresh built-in agent, the fresh
built-in wins and the old file is retained under
`~\.brainstem\recovery\rapp-refresh-<backup-id>\agents\`.

Full snapshots can be several gigabytes because they deliberately include the
old virtual environment, source checkout, worktrees, and any unrecognized
files. RAPP Refresh never prunes backups automatically.

`BrainstemHome` and `StateHome` must stay on the same volume. This guarantees
that quarantine and restore use atomic directory renames rather than
copy/delete moves that could be interrupted halfway through.

Mutating commands share one cross-session lock per Windows user so separate
Brainstem layouts cannot race while changing launchers or the user `PATH`.

## Scope

RAPP Refresh resets Brainstem-owned state. It intentionally does not uninstall
shared machine prerequisites such as Git, Python, GitHub CLI, or winget.
Testing those prerequisite installation branches requires a disposable Windows
Sandbox or virtual machine; removing shared development tools from a host is
not a safe uninstall strategy.

## Development

Run the dependency-free Windows PowerShell test suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

## License

[MIT](LICENSE)
