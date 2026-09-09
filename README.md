# Repair-codex-pet-overlay

Windows PowerShell workaround for a Codex Desktop avatar/pet overlay whose
visual position and native mouse-hit region become unsynchronized.

The script does not modify `app.asar` or any pet image. It adjusts the live
overlay window's native input styles and gives it a bounded hit region around
the saved pet position. The workaround is intentionally reversible and is
meant to be used until the upstream Windows overlay issue is fixed.

## Requirements

- Windows 10/11
- Codex Desktop (the packaged process is normally named `ChatGPT.exe`)
- Windows PowerShell 5.1

The script uses only local Windows APIs. It does not make network requests or
read GitHub credentials.

## Quick start

Open PowerShell in this directory and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\repair-codex-pet-overlay.ps1
```

For continuous repair while Codex is running:

```powershell
.\repair-codex-pet-overlay.ps1 -Watch -IntervalMs 500
```

The default mode reads the current anchor from:

```text
%USERPROFILE%\.codex\.codex-global-state.json
```

The window detector adapts its size thresholds to the monitor containing each
candidate window. It does not require a fixed 1000-pixel window height, so a
1920x1200 display reported as 1536x960 by a DPI-virtualized PowerShell process
is supported. Mixed-resolution monitors are handled independently, and no
resolution or scaling value needs to be entered manually.

If Codex is closed, the script simply reports that the overlay was not found;
it does not launch or modify Codex.

If the pet is missing after a previous workaround attempt, restart Codex once
before starting `-Watch`. The app must recreate a visible overlay window before
the shim can repair its native hit region. If the one-shot command reports
`overlay-not-found`, the shim has not changed anything; check that Codex is
running in the same interactive Windows session and try again after toggling
the pet off and on in Codex settings.

## Entering coordinates for another environment

Normally leave out `-AnchorX` and `-AnchorY`. The script follows the current
Codex value automatically. If the saved value is stale, pass both numbers as a
pair:

```powershell
.\repair-codex-pet-overlay.ps1 -AnchorX 2200 -AnchorY 1200
.\repair-codex-pet-overlay.ps1 -Watch -AnchorX 2200 -AnchorY 1200
```

These are absolute screen coordinates from Codex's saved display coordinate
space, not coordinates copied from a resized screenshot. For a 2560x1440
display, the top-left is normally `(0, 0)`; a monitor to the left can produce
negative X values. Use the values reported by Codex rather than guessing from
the image size.

To inspect the saved value:

```powershell
$statePath = Join-Path $env:USERPROFILE '.codex\.codex-global-state.json'
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$state.'electron-avatar-overlay-bounds' | Format-List
```

The `x` and `y` fields are the values to enter. If the JSON is being rewritten
while Codex is moving the pet, wait for the move to finish and run the command
again.

## Register at logon with Task Scheduler

Run the following from this repository directory. It registers a hidden task
for the current interactive user and starts the watch loop at logon:

```powershell
$taskName = 'Codex Pet Overlay Input Repair'
$scriptPath = Join-Path $PWD 'repair-codex-pet-overlay.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Watch -IntervalMs 500' -f $scriptPath
$action = New-ScheduledTaskAction -Execute $powershellPath -Argument $arguments
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
Start-ScheduledTask -TaskName $taskName
```

Check or remove it with:

```powershell
Get-ScheduledTask -TaskName 'Codex Pet Overlay Input Repair' | Select-Object TaskName,State
Stop-ScheduledTask -TaskName 'Codex Pet Overlay Input Repair'
Unregister-ScheduledTask -TaskName 'Codex Pet Overlay Input Repair' -Confirm:$false
```

If Task Scheduler denies registration, run PowerShell as Administrator and
repeat the registration block. The task still runs as the selected user, not
as a system service.

## Restore

To remove the shim from the currently visible overlay:

```powershell
.\repair-codex-pet-overlay.ps1 -Restore
```

Restart Codex afterward so the application can restore its own layered-window
and mouse-input policy. Removing the scheduled task is also recommended when
returning to the unmodified application.

## Privacy and repository scope

The repository intentionally contains only the PowerShell script, this README,
and the ignore file. The script does not contain a username, local absolute path, IP
address, token, screenshot, pet artwork, or Codex state snapshot. At runtime
it resolves the current user's profile dynamically, reads the local overlay
state, and writes `repair-codex-pet-overlay.log` only when an error occurs.

Do not commit the state file, screenshots, or runtime log. They are excluded by
`.gitignore` where applicable.

## Upstream context

- [Codex Desktop pet overlay discussion](https://community.openai.com/t/codex-desktop-pet-reacts-to-hover-but-cannot-be-dragged-on-windows/1393368)
- [OpenAI Codex issue #34227](https://github.com/openai/codex/issues/34227)
- [OpenAI Codex issue #41465](https://github.com/openai/codex/issues/41465)
