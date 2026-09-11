# DeepSeek Harness - remember the app window's size, position and maximized state
#
# Chromium does not persist the geometry of an `--app=` window: close it resized
# and the next launch comes back at the default size (verified - even with a
# byte-identical URL). So the geometry is remembered here instead, in a small JSON
# file, and re-applied to the fresh window.
#
#   open   read the saved geometry, start Edge as an app window, apply the
#          geometry, then leave a hidden watcher behind that keeps it current.
#          Called (in-process) by launch.ps1, so it returns a word - 'ok' when a
#          window was opened - and never calls exit: the caller is the launcher.
#   watch  poll one window handle and rewrite the state file when it changes.
#          Runs as its own hidden process and stops when the window is gone.
#   remember
#          read one window's geometry right now and save it. Useful to adopt a
#          window that was opened before this helper existed, and in tests.
#   show   print the state file and its contents. Diagnostics; changes nothing.
#
# Geometry is always read and written with the same Win32 coordinate space
# (GetWindowPlacement / SetWindowPlacement), so a DPI-scaled display cannot make
# the remembered size drift. The Chromium switches below are only a head start
# that avoids a visible resize; the placement call is what decides.
#
# KEEP THIS FILE PURE ASCII: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI,
# so non-ASCII text in here would be mis-decoded.

[CmdletBinding()]
param(
    [ValidateSet('open', 'watch', 'remember', 'show')][string]$Mode = 'show',

    # msedge.exe (open mode).
    [string]$Edge,

    # The URL to open (open mode).
    [string]$Url,

    # Window handle to keep an eye on (watch mode), or 0 to find it (open mode).
    [long]$Hwnd = 0,

    # Where the geometry is remembered. Defaults to
    # %LOCALAPPDATA%\DeepSeekHarness\window.json, or $env:DSH_WINDOW_STATE.
    [string]$StateFile,

    # A window counts as ours when its title contains this (open mode).
    [string]$TitleContains = 'DeepSeek Harness',

    # ...and does not end with this - that is the ordinary browser window, whose
    # title carries the profile suffix (open mode).
    [string]$BrowserTitlePattern = 'Microsoft\s?Edge\s*$',

    # How long to wait for the new window to appear (open mode).
    [int]$WaitSeconds = 20
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# state file
# ---------------------------------------------------------------------------
function Resolve-StateFile([string]$Explicit) {
    if ($Explicit) { return $Explicit }
    if ($env:DSH_WINDOW_STATE) { return $env:DSH_WINDOW_STATE }
    return (Join-Path $env:LOCALAPPDATA 'DeepSeekHarness\window.json')
}

function Read-SavedState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        $state = $raw | ConvertFrom-Json
    }
    catch { return $null }

    foreach ($name in @('left', 'top', 'width', 'height')) {
        $value = $state.$name
        if ($null -eq $value -or -not ($value -is [int]) -and -not ($value -is [long])) { return $null }
    }
    # A window smaller than this is not a real remembered window; a saved rect that
    # no longer touches any screen (the monitor was unplugged) keeps its size but
    # loses its position.
    if ($state.width -lt 200 -or $state.height -lt 200) { return $null }
    if ($state.width -gt 20000 -or $state.height -gt 20000) { return $null }

    $virtual = Get-VirtualScreen
    if (-not (Test-OnScreen -State $state -Virtual $virtual)) {
        $state.left = $virtual.Left + 40
        $state.top = $virtual.Top + 40
        if ($state.width -gt $virtual.Width) { $state.width = $virtual.Width - 80 }
        if ($state.height -gt $virtual.Height) { $state.height = $virtual.Height - 80 }
    }
    if ($null -eq $state.maximized) { $state | Add-Member -NotePropertyName maximized -NotePropertyValue $false -Force }
    return $state
}

function Test-OnScreen($State, $Virtual) {
    $right = [Math]::Min($State.left + $State.width, $Virtual.Left + $Virtual.Width)
    $bottom = [Math]::Min($State.top + $State.height, $Virtual.Top + $Virtual.Height)
    $visibleWidth = $right - [Math]::Max($State.left, $Virtual.Left)
    $visibleHeight = $bottom - [Math]::Max($State.top, $Virtual.Top)
    return ($visibleWidth -ge 120 -and $visibleHeight -ge 120)
}

function Write-SavedState([string]$Path, $State) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = [ordered]@{
        left      = [int]$State.left
        top       = [int]$State.top
        width     = [int]$State.width
        height    = [int]$State.height
        maximized = [bool]$State.maximized
    } | ConvertTo-Json -Compress

    $temp = "$Path.tmp"
    [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Format-State($State) {
    if ($null -eq $State) { return '(none)' }
    $flags = ''
    if ($State.maximized) { $flags = ' maximized' }
    return ("{0},{1} {2}x{3}{4}" -f $State.left, $State.top, $State.width, $State.height, $flags)
}

# ---------------------------------------------------------------------------
# Win32 (read and write geometry through the same API pair)
# ---------------------------------------------------------------------------
function Initialize-Native {
    if ('DshWindowNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DshWindowNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hwnd, ref WINDOWPLACEMENT placement);
    [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hwnd, ref WINDOWPLACEMENT placement);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);

    public const int SW_SHOWNORMAL = 1;
    public const int SW_SHOWMINIMIZED = 2;
    public const int SW_SHOWMAXIMIZED = 3;

    public static WINDOWPLACEMENT Read(IntPtr hwnd) {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(hwnd, ref p);
        return p;
    }

    public static bool Write(IntPtr hwnd, int left, int top, int width, int height, bool maximized) {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        if (!GetWindowPlacement(hwnd, ref p)) return false;
        p.rcNormalPosition.Left = left;
        p.rcNormalPosition.Top = top;
        p.rcNormalPosition.Right = left + width;
        p.rcNormalPosition.Bottom = top + height;
        p.showCmd = maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
        return SetWindowPlacement(hwnd, ref p);
    }

    public static string Title(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(512);
        GetWindowTextW(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@
}

function Get-VirtualScreen {
    Initialize-Native
    $left = [DshWindowNative]::GetSystemMetrics(76)      # SM_XVIRTUALSCREEN
    $top = [DshWindowNative]::GetSystemMetrics(77)       # SM_YVIRTUALSCREEN
    $width = [DshWindowNative]::GetSystemMetrics(78)     # SM_CXVIRTUALSCREEN
    $height = [DshWindowNative]::GetSystemMetrics(79)    # SM_CYVIRTUALSCREEN
    if ($width -le 0) { $left = 0; $top = 0; $width = [DshWindowNative]::GetSystemMetrics(0); $height = [DshWindowNative]::GetSystemMetrics(1) }
    return @{ Left = $left; Top = $top; Width = $width; Height = $height }
}

# ---------------------------------------------------------------------------
# finding the app window
#
# The window is identified by handle, not by title: UIA enumerates the top-level
# Chromium windows, and "the Chromium window that appeared while we were starting
# Edge, and is not the browser" is unambiguous even before the page has set its
# title.
# ---------------------------------------------------------------------------
function Get-ChromiumWindows {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $auto = [System.Windows.Automation.AutomationElement]
    $condition = New-Object System.Windows.Automation.PropertyCondition($auto::ClassNameProperty, 'Chrome_WidgetWin_1')
    $elements = $auto::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    $result = @()
    for ($i = 0; $i -lt $elements.Count; $i++) {
        $element = $elements.Item($i)
        $handle = $element.Current.NativeWindowHandle
        if ($handle -eq 0) { continue }
        $result += , @{ Hwnd = [long]$handle; Title = [string]$element.Current.Name }
    }
    return $result
}

function Test-IsBrowserWindow([string]$Title) {
    if (-not $Title) { return $false }
    return ($Title -match $BrowserTitlePattern)
}

function Find-NewAppWindow([long[]]$Known, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($window in Get-ChromiumWindows) {
            if ($Known -contains $window.Hwnd) { continue }
            if (Test-IsBrowserWindow $window.Title) { continue }
            return $window.Hwnd
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------
$statePath = Resolve-StateFile -Explicit $StateFile

if ($Mode -eq 'show') {
    "state file : $statePath"
    if (Test-Path -LiteralPath $statePath) {
        "contents   : $([System.IO.File]::ReadAllText($statePath))"
        $saved = Read-SavedState -Path $statePath
        if ($null -eq $saved) { 'parsed     : (invalid, would be ignored)' } else { "parsed     : $(Format-State $saved)" }
    }
    else { 'contents   : (none yet)' }
    return
}

# One window's current geometry, or $null when it cannot be read (gone, or a
# nonsensical rect such as a minimized window's off-screen one).
function Get-LiveState($Handle) {
    if (-not [DshWindowNative]::IsWindow($Handle)) { return $null }
    $placement = [DshWindowNative]::Read($Handle)
    $rect = $placement.rcNormalPosition
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 200 -or $height -lt 200) { return $null }
    return @{
        left      = $rect.Left
        top       = $rect.Top
        width     = $width
        height    = $height
        maximized = ($placement.showCmd -eq [DshWindowNative]::SW_SHOWMAXIMIZED)
    }
}

if ($Mode -eq 'remember') {
    Initialize-Native
    if ($Hwnd -eq 0) { return 'nohandle' }
    $live = Get-LiveState ([IntPtr]$Hwnd)
    if ($null -eq $live) { return 'nostate' }
    Write-SavedState -Path $statePath -State $live
    Write-Host "    remembered: $(Format-State $live) -> $statePath"
    return 'ok'
}

if ($Mode -eq 'watch') {
    Initialize-Native
    if ($Hwnd -eq 0) { return }
    $handle = [IntPtr]$Hwnd
    $lastWritten = ''
    $misses = 0
    $deadline = (Get-Date).AddHours(12)

    try {
        while ((Get-Date) -lt $deadline) {
            if (-not [DshWindowNative]::IsWindow($handle)) {
                # give a slow close a moment before believing it is gone
                $misses++
                if ($misses -ge 3) { return }
                Start-Sleep -Milliseconds 1500
                continue
            }
            $misses = 0
            $live = Get-LiveState $handle
            if ($null -ne $live) {
                $fingerprint = Format-State $live
                if ($fingerprint -ne $lastWritten) {
                    Write-SavedState -Path $statePath -State $live
                    $lastWritten = $fingerprint
                }
            }
            Start-Sleep -Milliseconds 1500
        }
    }
    catch {
        # a hidden helper must never take the launcher down with it
        try {
            $log = Join-Path (Split-Path -Parent $statePath) 'window-state-error.log'
            Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date).ToString('s'), $_.Exception.Message)
        }
        catch { }
    }
    return
}

# --- open ------------------------------------------------------------------
Initialize-Native
$saved = Read-SavedState -Path $statePath
$known = @(Get-ChromiumWindows | ForEach-Object { $_.Hwnd })

$arguments = '--app="' + $Url + '"'
if ($null -ne $saved) {
    # Best effort: lets the window come up already in the right place instead of
    # jumping there. The placement call below is what actually decides.
    $arguments += " --window-size=$($saved.width),$($saved.height) --window-position=$($saved.left),$($saved.top)"
    if ($saved.maximized) { $arguments += ' --start-maximized' }
}

try {
    Start-Process -FilePath $Edge -ArgumentList $arguments | Out-Null
}
catch {
    Write-Host "    could not start Microsoft Edge: $($_.Exception.Message)" -ForegroundColor Yellow
    return 'failed'
}

$handle = Find-NewAppWindow -Known $known -Seconds $WaitSeconds
if ($handle -eq 0) {
    # Edge was started, so the caller must not start it again - only the geometry
    # memory is lost for this window.
    Write-Host '    (could not identify the new Edge window; its size will not be remembered)' -ForegroundColor Yellow
    return 'unidentified'
}

# From here on Edge is already running, so nothing below may throw: a failure only
# costs this window's geometry memory, while an exception would make the caller
# start Edge a second time.
try {
    if ($null -ne $saved) {
        $placement = [DshWindowNative]::Read([IntPtr]$handle)
        $rect = $placement.rcNormalPosition
        $isMaximized = ($placement.showCmd -eq [DshWindowNative]::SW_SHOWMAXIMIZED)
        $off = ([Math]::Abs($rect.Left - $saved.left) -gt 8) -or ([Math]::Abs($rect.Top - $saved.top) -gt 8) -or
               ([Math]::Abs(($rect.Right - $rect.Left) - $saved.width) -gt 8) -or
               ([Math]::Abs(($rect.Bottom - $rect.Top) - $saved.height) -gt 8)
        if ($saved.maximized -ne $isMaximized -or ($off -and -not $saved.maximized)) {
            [void][DshWindowNative]::Write([IntPtr]$handle, $saved.left, $saved.top, $saved.width, $saved.height, [bool]$saved.maximized)
        }
    }

    # Leave the geometry keeper behind; it exits by itself when the window is gone.
    #
    # Started through Start-Process -WindowStyle Hidden on purpose: that gives the
    # watcher its own hidden console instead of inheriting this process's handles,
    # so it neither holds a caller's output pipe open nor dies with the launcher's
    # console window.
    $watcher = Join-Path $PSScriptRoot 'window-state.ps1'
    if (Test-Path -LiteralPath $watcher) {
        $watcherArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $watcher + '"' +
                            ' -Mode watch -Hwnd ' + [string]$handle + ' -StateFile "' + $statePath + '"'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                      -ArgumentList $watcherArguments -WindowStyle Hidden | Out-Null
    }
}
catch {
    Write-Host "    (window size memory failed: $($_.Exception.Message))" -ForegroundColor Yellow
}

return 'ok'
