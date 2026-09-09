[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Restore,
    [ValidateRange(100, 5000)]
    [int]$IntervalMs = 500,
    [ValidateRange(-32768, 32767)]
    [int]$AnchorX,
    [ValidateRange(-32768, 32767)]
    [int]$AnchorY
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'repair-codex-pet-overlay.log'
$script:lastLoggedMessage = $null
$script:lastLoggedAt = [DateTime]::MinValue
$script:anchorOverride = $null
if ($PSBoundParameters.ContainsKey('AnchorX') -or $PSBoundParameters.ContainsKey('AnchorY')) {
    if (-not ($PSBoundParameters.ContainsKey('AnchorX') -and $PSBoundParameters.ContainsKey('AnchorY'))) {
        throw 'AnchorX and AnchorY must be provided together.'
    }
    $script:anchorOverride = [pscustomobject]@{
        X = $AnchorX
        Y = $AnchorY
        DisplayX = 0
        DisplayY = 0
        DisplayWidth = 0
        DisplayHeight = 0
    }
}
$script:lastKnownAnchor = $script:anchorOverride

function Write-RepairLog {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }
    if ($Message.Length -gt 512) {
        $Message = $Message.Substring(0, 512) + '...'
    }

    $now = Get-Date
    if ($Message -eq $script:lastLoggedMessage -and ($now - $script:lastLoggedAt).TotalSeconds -lt 30) {
        return
    }
    $script:lastLoggedMessage = $Message
    $script:lastLoggedAt = $now

    try {
        Add-Content -LiteralPath $logPath -Value ("{0} {1}" -f (Get-Date -Format o), $Message) -Encoding UTF8
    }
    catch {
        # Logging must never prevent the repair loop from continuing.
    }
}

try {
    if (-not ('CodexPetOverlayShim' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class CodexPetOverlayShim
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowRgn(IntPtr hWnd, IntPtr region, bool redraw);

    [DllImport("user32.dll")]
    public static extern int GetWindowRgnBox(IntPtr hWnd, out RECT rect);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO
    {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
    }

    private const int GWL_EXSTYLE = -20;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;
    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const long WS_EX_TOOLWINDOW = 0x80L;
    private const long WS_EX_TRANSPARENT = 0x20L;
    private const long WS_EX_LAYERED = 0x80000L;
    public static IntPtr FindOverlay()
    {
        var processIds = new HashSet<uint>();
        foreach (var process in Process.GetProcessesByName("ChatGPT"))
        {
            processIds.Add((uint)process.Id);
        }

        IntPtr result = IntPtr.Zero;
        int resultArea = 0;
        int virtualWidth = Math.Abs(GetSystemMetrics(SM_CXVIRTUALSCREEN));
        int virtualHeight = Math.Abs(GetSystemMetrics(SM_CYVIRTUALSCREEN));

        // GetWindowRect can be DPI-virtualized for a PowerShell host.  The
        // overlay is normally a tall tool window, but a fixed 1000px minimum
        // rejects a 1536x960 logical desktop (for example, 1920x1200 at 125%
        // scaling).  Derive a conservative lower bound from the monitor that
        // owns each candidate instead of assuming one physical resolution or
        // using the tallest monitor in a mixed-resolution desktop.
        int fallbackMinimumWidth = virtualWidth > 0
            ? Math.Max(160, Math.Min(300, virtualWidth / 8))
            : 200;
        int fallbackMinimumHeight = virtualHeight > 0
            ? Math.Max(360, Math.Min(1000, virtualHeight / 2))
            : 480;

        EnumWindows((hWnd, lParam) =>
        {
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            if (!processIds.Contains(processId) || !IsWindowVisible(hWnd))
            {
                return true;
            }

            RECT rect;
            GetWindowRect(hWnd, out rect);
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            int area = width * height;
            long style = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
            bool isToolWindow = (style & WS_EX_TOOLWINDOW) != 0;

            int monitorWidth = virtualWidth;
            int monitorHeight = virtualHeight;
            IntPtr monitor = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
            if (monitor != IntPtr.Zero)
            {
                MONITORINFO info = new MONITORINFO();
                info.Size = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(monitor, ref info))
                {
                    monitorWidth = Math.Abs(info.Monitor.Right - info.Monitor.Left);
                    monitorHeight = Math.Abs(info.Monitor.Bottom - info.Monitor.Top);
                }
            }

            int minimumWidth = monitorWidth > 0
                ? Math.Max(160, Math.Min(300, monitorWidth / 8))
                : fallbackMinimumWidth;
            int minimumHeight = monitorHeight > 0
                ? Math.Max(360, Math.Min(1000, monitorHeight / 2))
                : fallbackMinimumHeight;
            if (width >= minimumWidth && height >= minimumHeight && isToolWindow && area > resultArea)
            {
                result = hWnd;
                resultArea = area;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private static int Clamp(int value, int minimum, int maximum)
    {
        if (value < minimum) return minimum;
        if (value > maximum) return maximum;
        return value;
    }

    private static bool HasExpectedRegion(IntPtr hWnd, int left, int top, int right, int bottom)
    {
        RECT current;
        int regionType = GetWindowRgnBox(hWnd, out current);
        return regionType != 0
            && current.Left == left
            && current.Top == top
            && current.Right == right
            && current.Bottom == bottom;
    }

    public static string Apply(int anchorX, int anchorY, int displayX, int displayY, int displayWidth, int displayHeight)
    {
        IntPtr overlay = FindOverlay();
        if (overlay == IntPtr.Zero)
        {
            return "overlay-not-found";
        }

        RECT window;
        GetWindowRect(overlay, out window);
        int width = window.Right - window.Left;
        int height = window.Bottom - window.Top;

        // The current renderer leaves the visible mascot near the saved anchor,
        // while the native input surface can remain at the old top layout.
        // Keep the shim bounded to a small area around that saved mascot.
        //
        // On some Windows/DPI combinations the saved display coordinates and
        // the native overlay window use different spaces.  A direct conversion
        // is preferred when it lands inside the window; otherwise use the
        // anchor's normalized position within the saved display.  Never clamp
        // an invalid conversion to a one-pixel strip: SetWindowRgn also clips
        // drawing, which can make the mascot disappear.
        int directLeft = anchorX - window.Left - 128;
        int directTop = anchorY - window.Top - 96;
        bool directFits = directLeft > -160 && directLeft < width + 160
            && directTop > -128 && directTop < height + 128;
        int anchorLocalX = directFits
            ? directLeft
            : displayWidth > 0
                ? (int)Math.Round((double)(anchorX - displayX) * width / displayWidth) - 128
                : width / 2 - 128;
        int anchorLocalY = directFits
            ? directTop
            : displayHeight > 0
                ? (int)Math.Round((double)(anchorY - displayY) * height / displayHeight) - 96
                : height / 2 - 96;
        int left = Clamp(anchorLocalX, 0, Math.Max(0, width - 160));
        int top = Clamp(anchorLocalY, 0, Math.Max(0, height - 160));
        int right = Math.Min(width, left + 300);
        int bottom = Math.Min(height, top + 300);
        if (right <= left || bottom <= top)
        {
            return "invalid-target-region";
        }

        long currentStyle = GetWindowLongPtr(overlay, GWL_EXSTYLE).ToInt64();
        long desiredStyle = currentStyle & ~WS_EX_LAYERED & ~WS_EX_TRANSPARENT;
        if (desiredStyle != currentStyle)
        {
            SetWindowLongPtr(overlay, GWL_EXSTYLE, new IntPtr(desiredStyle));
        }

        EnumChildWindows(overlay, (child, lParam) =>
        {
            RECT childRect;
            GetWindowRect(child, out childRect);
            if (childRect.Left == window.Left
                && childRect.Top == window.Top
                && childRect.Right == window.Right
                && childRect.Bottom == window.Bottom)
            {
                long childStyle = GetWindowLongPtr(child, GWL_EXSTYLE).ToInt64();
                long desiredChildStyle = childStyle & ~WS_EX_TRANSPARENT;
                if (desiredChildStyle != childStyle)
                {
                    SetWindowLongPtr(child, GWL_EXSTYLE, new IntPtr(desiredChildStyle));
                }
            }
            return true;
        }, IntPtr.Zero);

        if (!HasExpectedRegion(overlay, left, top, right, bottom))
        {
            IntPtr region = CreateRectRgn(left, top, right, bottom);
            if (!SetWindowRgn(overlay, region, true))
            {
                DeleteObject(region);
                return "set-window-region-failed";
            }
        }

        return string.Format(
            "applied hwnd=0x{0:X} mode={1} window={2},{3},{4}x{5} region={6},{7},{8}x{9}",
            overlay.ToInt64(),
            directFits ? "direct" : "normalized",
            window.Left,
            window.Top,
            width,
            height,
            left,
            top,
            right - left,
            bottom - top);
    }

    public static string Restore()
    {
        IntPtr overlay = FindOverlay();
        if (overlay == IntPtr.Zero)
        {
            return "overlay-not-found";
        }

        SetWindowRgn(overlay, IntPtr.Zero, true);
        long style = GetWindowLongPtr(overlay, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(overlay, GWL_EXSTYLE, new IntPtr(style | WS_EX_LAYERED));
        return string.Format("restored hwnd=0x{0:X}; restart Codex to restore its own input policy", overlay.ToInt64());
    }
}
'@
    }
}
catch {
    Write-RepairLog ("initialization failed: {0}" -f $_.Exception.Message)
    throw
}

$profileRoot = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($profileRoot)) {
    $profileRoot = [Environment]::GetFolderPath('UserProfile')
}
if ([string]::IsNullOrWhiteSpace($profileRoot)) {
    throw 'Could not determine the current user profile path.'
}
$statePath = Join-Path $profileRoot '.codex\.codex-global-state.json'

function Get-PetAnchor {
    if ($null -ne $script:anchorOverride) {
        return $script:anchorOverride
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        return $script:lastKnownAnchor
    }

    # The app rewrites this large JSON file while dragging/restarting. Read only
    # the small root-level bounds object first so a transient partial write does
    # not terminate the watch loop or flood the log with the whole state file.
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $rawState = [System.IO.File]::ReadAllText($statePath)
            $boundsMatch = [regex]::Match(
                $rawState,
                '"electron-avatar-overlay-bounds"\s*:\s*\{[^{}]*?"x"\s*:\s*(-?\d+)[^{}]*?"y"\s*:\s*(-?\d+)',
                [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($boundsMatch.Success) {
                $anchor = [pscustomobject]@{
                    X = [int]$boundsMatch.Groups[1].Value
                    Y = [int]$boundsMatch.Groups[2].Value
                    DisplayX = 0
                    DisplayY = 0
                    DisplayWidth = 0
                    DisplayHeight = 0
                }
                $displayMatch = [regex]::Match(
                    $rawState,
                    '"electron-avatar-overlay-bounds"\s*:\s*\{.*?"displayBounds"\s*:\s*\{\s*"x"\s*:\s*(-?\d+)\s*,\s*"y"\s*:\s*(-?\d+)\s*,\s*"width"\s*:\s*(\d+)\s*,\s*"height"\s*:\s*(\d+)',
                    [System.Text.RegularExpressions.RegexOptions]::Singleline)
                if ($displayMatch.Success) {
                    $anchor.DisplayX = [int]$displayMatch.Groups[1].Value
                    $anchor.DisplayY = [int]$displayMatch.Groups[2].Value
                    $anchor.DisplayWidth = [int]$displayMatch.Groups[3].Value
                    $anchor.DisplayHeight = [int]$displayMatch.Groups[4].Value
                }
                $script:lastKnownAnchor = $anchor
                return $anchor
            }

            # Fall back to the JSON parser if field order/format changes.
            $globalState = $rawState | ConvertFrom-Json
            $property = $globalState.PSObject.Properties['electron-avatar-overlay-bounds']
            $bounds = if ($null -ne $property) { $property.Value } else { $null }
            if ($null -ne $bounds -and $null -ne $bounds.x -and $null -ne $bounds.y) {
                $anchor = [pscustomobject]@{
                    X = [int]$bounds.x
                    Y = [int]$bounds.y
                    DisplayX = if ($null -ne $bounds.displayBounds) { [int]$bounds.displayBounds.x } else { 0 }
                    DisplayY = if ($null -ne $bounds.displayBounds) { [int]$bounds.displayBounds.y } else { 0 }
                    DisplayWidth = if ($null -ne $bounds.displayBounds) { [int]$bounds.displayBounds.width } else { 0 }
                    DisplayHeight = if ($null -ne $bounds.displayBounds) { [int]$bounds.displayBounds.height } else { 0 }
                }
                $script:lastKnownAnchor = $anchor
                return $anchor
            }
        }
        catch {
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds 25
            }
        }
    }

    return $script:lastKnownAnchor
}

if ($Restore) {
    [CodexPetOverlayShim]::Restore()
    exit 0
}

do {
    try {
        $anchor = Get-PetAnchor
        if ($null -ne $anchor) {
            [CodexPetOverlayShim]::Apply(
                $anchor.X,
                $anchor.Y,
                $anchor.DisplayX,
                $anchor.DisplayY,
                $anchor.DisplayWidth,
                $anchor.DisplayHeight)
        }
    }
    catch {
        Write-RepairLog ("repair iteration failed: {0}" -f $_.Exception.Message)
        if (-not $Watch) {
            throw
        }
    }
    if (-not $Watch) {
        break
    }
    Start-Sleep -Milliseconds $IntervalMs
} while ($true)
