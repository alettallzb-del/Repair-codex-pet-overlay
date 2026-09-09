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
$script:cachedGlobalState = $null
$script:cachedStateWriteTimeUtc = $null

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

    public static bool TryGetMonitorBounds(IntPtr hWnd, out RECT bounds)
    {
        bounds = new RECT();
        IntPtr monitor = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
        if (monitor == IntPtr.Zero)
        {
            return false;
        }

        MONITORINFO info = new MONITORINFO();
        info.Size = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(monitor, ref info))
        {
            return false;
        }

        bounds = info.Monitor;
        return true;
    }

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
    private const int DEFAULT_MASCOT_HEIGHT = 121;
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

    private static bool IsUsableAnchor(int localX, int localY, int width, int height, int margin)
    {
        return localX > -margin
            && localX < width + margin
            && localY > -margin
            && localY < height + margin;
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

        // Keep the geometry in the live overlay's own coordinate space.
        // Monitor resolution and DPI are not configuration inputs here:
        // display metadata is used only to normalize the saved screen anchor
        // into the current window, while the live HWND supplies the bounds.
        // Keep both interpretations when a DPI-virtualized host makes them
        // disagree; the union prevents a wrong conversion from clipping the
        // mascot or its balloon.
        int directLocalY = anchorY - window.Top;
        var candidateAnchorYs = new List<int>();
        candidateAnchorYs.Add(directLocalY);
        if (displayHeight > 0)
        {
            int normalizedLocalY = (int)Math.Round(
                (double)(anchorY - displayY) * height / displayHeight);
            candidateAnchorYs.Add(normalizedLocalY);
        }

        int candidateMargin = Math.Max(DEFAULT_MASCOT_HEIGHT, height / 4);
        int minAnchorY = int.MaxValue;
        int maxAnchorY = int.MinValue;
        foreach (int candidateY in candidateAnchorYs)
        {
            if (!IsUsableAnchor(0, candidateY, 1, height, candidateMargin))
            {
                continue;
            }
            minAnchorY = Math.Min(minAnchorY, candidateY);
            maxAnchorY = Math.Max(maxAnchorY, candidateY);
        }
        if (minAnchorY == int.MaxValue)
        {
            minAnchorY = Math.Max(0, height / 2 - DEFAULT_MASCOT_HEIGHT / 2);
            maxAnchorY = minAnchorY;
        }

        // SetWindowRgn clips painting as well as mouse input.  Use the full
        // live overlay width so a balloon can extend horizontally without
        // being cut off.  The vertical padding is derived from the current
        // window height and expands around every plausible anchor conversion.
        // No 300x300 box or hand-tuned -128/-96 offsets remain.
        int verticalPadding = Math.Max(DEFAULT_MASCOT_HEIGHT, height / 8);
        int left = 0;
        int top = Clamp(minAnchorY - verticalPadding, 0, height);
        int right = width;
        int bottom = Clamp(maxAnchorY + DEFAULT_MASCOT_HEIGHT + verticalPadding, 0, height);
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
            "window-wide",
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

function ConvertTo-PetAnchor {
    param(
        [object]$Bounds,
        [string]$Source
    )

    if ($null -eq $Bounds) {
        return $null
    }

    $xProperty = $Bounds.PSObject.Properties['x']
    $yProperty = $Bounds.PSObject.Properties['y']
    if ($null -eq $xProperty -or $null -eq $yProperty) {
        return $null
    }

    $displayX = 0
    $displayY = 0
    $displayWidth = 0
    $displayHeight = 0
    $displayProperty = $Bounds.PSObject.Properties['displayBounds']
    $displayBounds = if ($null -ne $displayProperty) { $displayProperty.Value } else { $null }
    if ($null -ne $displayBounds) {
        $displayXProperty = $displayBounds.PSObject.Properties['x']
        $displayYProperty = $displayBounds.PSObject.Properties['y']
        $displayWidthProperty = $displayBounds.PSObject.Properties['width']
        $displayHeightProperty = $displayBounds.PSObject.Properties['height']
        if ($null -ne $displayXProperty -and $null -ne $displayYProperty -and $null -ne $displayWidthProperty -and $null -ne $displayHeightProperty) {
            $displayX = [int]$displayXProperty.Value
            $displayY = [int]$displayYProperty.Value
            $displayWidth = [int]$displayWidthProperty.Value
            $displayHeight = [int]$displayHeightProperty.Value
        }
    }

    [pscustomobject]@{
        X = [int]$xProperty.Value
        Y = [int]$yProperty.Value
        DisplayX = $displayX
        DisplayY = $displayY
        DisplayWidth = $displayWidth
        DisplayHeight = $displayHeight
        Source = $Source
    }
}

function Get-CurrentOverlayMonitorBounds {
    try {
        $overlay = [CodexPetOverlayShim]::FindOverlay()
        if ($overlay -eq [IntPtr]::Zero) {
            return $null
        }

        $monitor = New-Object -TypeName 'CodexPetOverlayShim+RECT'
        if (-not [CodexPetOverlayShim]::TryGetMonitorBounds($overlay, [ref]$monitor)) {
            return $null
        }

        [pscustomobject]@{
            X = $monitor.Left
            Y = $monitor.Top
            Width = [Math]::Abs($monitor.Right - $monitor.Left)
            Height = [Math]::Abs($monitor.Bottom - $monitor.Top)
        }
    }
    catch {
        return $null
    }
}

function Get-PetDisplayScore {
    param(
        [object]$Candidate,
        [object]$CurrentDisplay
    )

    if ($null -eq $CurrentDisplay) {
        return 0
    }
    if ($Candidate.DisplayWidth -le 0 -or $Candidate.DisplayHeight -le 0) {
        return -1000000000
    }

    $candidateWidth = [double]$Candidate.DisplayWidth
    $candidateHeight = [double]$Candidate.DisplayHeight
    $currentWidth = [double]$CurrentDisplay.Width
    $currentHeight = [double]$CurrentDisplay.Height
    if ($currentWidth -le 0 -or $currentHeight -le 0) {
        return 0
    }

    $aspectDifference = [Math]::Abs(
        ($candidateWidth / $candidateHeight) - ($currentWidth / $currentHeight))
    $sizeDifference = (([Math]::Abs($candidateWidth - $currentWidth) / [Math]::Max($candidateWidth, $currentWidth)) + ([Math]::Abs($candidateHeight - $currentHeight) / [Math]::Max($candidateHeight, $currentHeight)))
    $score = -($aspectDifference * 100000) - ($sizeDifference * 100)
    if ($Candidate.DisplayWidth -eq $CurrentDisplay.Width -and $Candidate.DisplayHeight -eq $CurrentDisplay.Height) {
        $score += 1000000
    }
    return $score
}

function Get-PetAnchorFromState {
    param([object]$GlobalState)

    $boundsProperty = $GlobalState.PSObject.Properties['electron-avatar-overlay-bounds']
    $bounds = if ($null -ne $boundsProperty) { $boundsProperty.Value } else { $null }
    $rootCandidate = ConvertTo-PetAnchor -Bounds $bounds -Source 'root'
    if ($null -eq $rootCandidate) {
        return $script:lastKnownAnchor
    }

    $currentDisplay = Get-CurrentOverlayMonitorBounds
    if ($null -eq $currentDisplay) {
        $script:lastKnownAnchor = $rootCandidate
        return $rootCandidate
    }

    $candidates = @($rootCandidate)
    foreach ($collectionName in @('byResolution', 'byDisplayId')) {
        $collectionProperty = $bounds.PSObject.Properties[$collectionName]
        if ($null -eq $collectionProperty -or $null -eq $collectionProperty.Value) {
            continue
        }

        foreach ($entry in $collectionProperty.Value.PSObject.Properties) {
            $candidate = ConvertTo-PetAnchor -Bounds $entry.Value -Source ("{0}:{1}" -f $collectionName, $entry.Name)
            if ($null -ne $candidate) {
                $candidates += $candidate
            }
        }
    }

    $bestCandidate = $rootCandidate
    $bestScore = Get-PetDisplayScore -Candidate $rootCandidate -CurrentDisplay $currentDisplay
    foreach ($candidate in $candidates) {
        $score = Get-PetDisplayScore -Candidate $candidate -CurrentDisplay $currentDisplay
        if ($score -gt $bestScore) {
            $bestCandidate = $candidate
            $bestScore = $score
        }
    }

    $script:lastKnownAnchor = $bestCandidate
    return $bestCandidate
}

function Get-PetAnchor {
    if ($null -ne $script:anchorOverride) {
        return $script:anchorOverride
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        return $script:lastKnownAnchor
    }

    # The app rewrites this large JSON file while dragging/restarting. Cache the
    # parsed document by write time, and keep the last complete document if a
    # transient partial write is observed. This also lets us select the
    # display-specific entry without reparsing the file on every watch tick.
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $stateItem = Get-Item -LiteralPath $statePath -ErrorAction Stop
            $rawState = [System.IO.File]::ReadAllText($statePath)
            if ($null -eq $script:cachedGlobalState -or $script:cachedStateWriteTimeUtc -ne $stateItem.LastWriteTimeUtc) {
                $script:cachedGlobalState = $rawState | ConvertFrom-Json
                $script:cachedStateWriteTimeUtc = $stateItem.LastWriteTimeUtc
            }
            break
        }
        catch {
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds 25
            }
        }
    }

    if ($null -eq $script:cachedGlobalState) {
        return $script:lastKnownAnchor
    }

    return Get-PetAnchorFromState -GlobalState $script:cachedGlobalState
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
