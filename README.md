# Repair-codex-pet-overlay

[日本語版](README.ja.md)

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

The script is manual and one-shot. It waits up to 300 seconds for the visible
Codex pet overlay. You may start it before Codex; once the overlay appears, the
script applies the repair once and exits. To change the startup wait window:

```powershell
.\repair-codex-pet-overlay.ps1 -WaitForOverlaySeconds 120
```

The default mode reads the current anchor from:

```text
%USERPROFILE%\.codex\.codex-global-state.json
```

The window detector adapts its size thresholds to the monitor containing each
candidate window. It does not require a fixed `1000`-pixel window height, so a
1920x1200 display reported as 1536x960 by a DPI-virtualized PowerShell process
is supported. Mixed-resolution monitors are handled independently, and no
resolution or scaling value needs to be entered manually.

The saved anchor is selected from the display-specific entries in Codex's
state when available (`byResolution` or `byDisplayId`). The script converts
that anchor into the live overlay window's own coordinate space. Resolution,
DPI percentage, and monitor dimensions are not user-supplied settings; the
current HWND and the saved display metadata are inspected at runtime.

The repair region spans the live overlay width, so a speech balloon can extend
sideways without being clipped. Its vertical bounds are derived from the live
window height and all plausible anchor conversions. This matters because
Windows `SetWindowRgn` limits both mouse input and drawing; the region must
cover the whole mascot and balloon to avoid clipping either one.

The script does not launch or modify Codex. A successful repair prints an
`applied ...` result and exits with status 0. If the overlay or its saved anchor
does not become available within the wait window, it reports the last result,
writes the diagnostic log, and exits with status 1. No background watcher is
left running.

If the pet is missing after a previous workaround attempt, restart Codex once
before starting the manual repair. The app must recreate a visible overlay
window before the shim can repair its native hit region. You can start the
script before Codex and leave it waiting, or run it after toggling the pet off
and on in Codex settings.

## Entering coordinates for another environment

Normally leave out `-AnchorX` and `-AnchorY`. The script follows the current
Codex value automatically. If the saved value is stale, pass both numbers as a
pair:

```powershell
.\repair-codex-pet-overlay.ps1 -AnchorX 2200 -AnchorY 1200
.\repair-codex-pet-overlay.ps1 -WaitForOverlaySeconds 300 -AnchorX 2200 -AnchorY 1200
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

## Manual startup only

This revision intentionally does not run a continuous watcher and no longer
accepts `-Watch`. Do not register it in Task Scheduler. Start it manually before
or after launching Codex; it waits for the overlay for up to five minutes,
repairs it once, and then terminates. If the app is restarted or recreates its
overlay later, run the script again when needed.

## Restore

To remove the shim from the currently visible overlay:

```powershell
.\repair-codex-pet-overlay.ps1 -Restore
```

Restart Codex afterward so the application can restore its own layered-window
and mouse-input policy. The repair process is already one-shot and exits after
success or timeout.

## Privacy and repository scope

The repository intentionally contains only the PowerShell script, the README
files, and the ignore file. The script does not contain a username, local
absolute path, IP address, token, screenshot, pet artwork, or Codex state snapshot. At runtime
it resolves the current user's profile dynamically, reads the local overlay
state, and writes `repair-codex-pet-overlay.log` only when an error occurs.

Do not commit the state file, screenshots, or runtime log. They are excluded by
`.gitignore` where applicable.

## Upstream context

- [Codex Desktop pet overlay discussion](https://community.openai.com/t/codex-desktop-pet-reacts-to-hover-but-cannot-be-dragged-on-windows/1393368)
- [OpenAI Codex issue #34227](https://github.com/openai/codex/issues/34227)
- [OpenAI Codex issue #41465](https://github.com/openai/codex/issues/41465)
