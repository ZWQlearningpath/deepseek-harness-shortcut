# DeepSeek Harness launcher - installer
#
# Builds a desktop shortcut that starts the DeepSeek Harness web UI with a
# plain double-click, with NO administrator rights, and gives it the official
# black whale icon on a transparent background.
#
# Everything is auto-detected; nothing about the original machine is baked in.
#
#   .\install.ps1                     normal install
#   .\install.ps1 -WhatIfOnly         detect and report, change nothing
#   .\install.ps1 -NodeExe C:\node\node.exe -DshBin C:\...\dsh\lib\bin.js
#   .\install.ps1 -DesktopDir .\out   write the shortcut somewhere else (test)
#
# If PowerShell blocks the script, run it for this session only with:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

[CmdletBinding()]
param(
    # node.exe to use. Auto-detected when omitted.
    [string]$NodeExe,

    # Absolute path to @deepseek-ai/dsh/lib/bin.js. Auto-detected when omitted.
    [string]$DshBin,

    # Working directory for the launched server. Defaults to the folder this
    # repository lives in, which is a sensible project root for the UI.
    [string]$WorkDir,

    # Where the shortcut is written. Defaults to the current user's Desktop.
    [string]$DesktopDir,

    # Name of the shortcut file, without the .lnk extension.
    [string]$ShortcutName = 'DeepSeek Harness',

    # Build the icon but do not create the shortcut.
    [switch]$NoShortcut,

    # Detect and report only; write nothing.
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$assetsDir = Join-Path $repoDir 'assets'
$whaleSvg = Join-Path $assetsDir 'deepseek-whale.svg'

function Write-Step([string]$text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host "    $text" -ForegroundColor Green }
function Write-Warn([string]$text) { Write-Host "    $text" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. locate node.exe
# ---------------------------------------------------------------------------
function Resolve-NodeExe {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "the -NodeExe path does not exist: $Explicit"
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates.Add($cmd.Source) }

    # the Node.js installer's usual machine-wide and per-user locations
    $candidates.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe')) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')) }
    # nvm-windows keeps a symlink here
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'nodejs\nvm\node.exe')) }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 2. locate the installed dsh package
# ---------------------------------------------------------------------------
function Resolve-DshBin {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "the -DshBin path does not exist: $Explicit"
    }

    $rel = 'node_modules\@deepseek-ai\dsh\lib\bin.js'

    # a) npm config points straight at the cache
    try {
        $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($npmCmd) {
            $cache = (& $npmCmd config get cache 2>$null | Select-Object -First 1)
            if ($cache) {
                $cache = $cache.Trim()
                foreach ($sub in @('_npx', '')) {
                    $root = if ($sub) { Join-Path $cache $sub } else { $cache }
                    if (Test-Path -LiteralPath $root) {
                        $hit = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                            ForEach-Object { Join-Path $_.FullName $rel } |
                            Where-Object { Test-Path -LiteralPath $_ } |
                            Select-Object -First 1
                        if ($hit) { return $hit }
                    }
                }
            }
        }
    }
    catch { Write-Verbose "npm cache probe failed: $($_.Exception.Message)" }

    # b) npm's per-user default cache locations of last resort
    $fallbacks = @()
    if ($env:LOCALAPPDATA) { $fallbacks += (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') }
    if ($env:APPDATA) { $fallbacks += (Join-Path $env:APPDATA 'npm-cache\_npx') }
    if ($env:USERPROFILE) { $fallbacks += (Join-Path $env:USERPROFILE 'AppData\Local\npm-cache\_npx') }
    foreach ($f in $fallbacks) {
        if (Test-Path -LiteralPath $f) {
            $hit = Get-ChildItem -LiteralPath $f -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName $rel } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($hit) { return $hit }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 3. build the whale icon (transparent background)
# ---------------------------------------------------------------------------
function New-WhaleIcon {
    param([string]$SvgPath, [string]$OutIco)

    Add-Type -AssemblyName System.Drawing

    if (-not (Test-Path -LiteralPath $SvgPath)) { throw "logo not found: $SvgPath" }
    $svg = [System.IO.File]::ReadAllText($SvgPath)

    $m = [regex]::Match($svg, '<path[^>]*\sd="([^"]+)"')
    if (-not $m.Success) { throw "no <path d=`"...`"> found in $SvgPath" }
    $d = $m.Groups[1].Value

    # the logo is pure absolute M / C / Z, so the walk is simple
    $tokens = [regex]::Matches($d, '[MCZ]|-?\d*\.?\d+(?:[eE][-+]?\d+)?') | ForEach-Object { $_.Value }

    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding   # svg fill-rule="nonzero"

    $i = 0
    $startX = 0.0; $startY = 0.0; $cx = 0.0; $cy = 0.0
    while ($i -lt $tokens.Count) {
        switch ($tokens[$i]) {
            'M' {
                $i++
                $cx = [double]$tokens[$i]; $i++
                $cy = [double]$tokens[$i]; $i++
                $startX = $cx; $startY = $cy
                $gp.StartFigure()
            }
            'C' {
                $i++
                $x1 = [double]$tokens[$i]; $i++
                $y1 = [double]$tokens[$i]; $i++
                $x2 = [double]$tokens[$i]; $i++
                $y2 = [double]$tokens[$i]; $i++
                $x3 = [double]$tokens[$i]; $i++
                $y3 = [double]$tokens[$i]; $i++
                $gp.AddBezier([single]$cx, [single]$cy, [single]$x1, [single]$y1,
                              [single]$x2, [single]$y2, [single]$x3, [single]$y3)
                $cx = $x3; $cy = $y3
            }
            'Z' {
                $i++
                $gp.CloseFigure()
                $cx = $startX; $cy = $startY
            }
            default { throw "unexpected path token '$($tokens[$i])' at index $i" }
        }
    }

    $box = $gp.GetBounds()
    if ($box.Width -le 0 -or $box.Height -le 0) { throw 'the whale path has an empty bounding box' }

    function Render([int]$size) {
        $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bmp.SetResolution(96, 96)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)   # no white background
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

            $pad = [Math]::Max(1.0, $size * 0.03)
            $avail = $size - 2 * $pad
            $scale = $avail / [Math]::Max($box.Width, $box.Height)

            # centre the artwork, honouring its true aspect ratio
            $offX = ($size - $box.Width * $scale) / 2.0 - $box.X * $scale
            $offY = ($size - $box.Height * $scale) / 2.0 - $box.Y * $scale

            # scale first, then translate: GDI+ prepends, so this yields
            # device = user * scale + offset
            $g.ScaleTransform([single]$scale, [single]$scale)
            $g.TranslateTransform([single]$offX, [single]$offY)

            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 0, 0))
            # a hairline outline in the same black keeps the thin flukes readable at 16px
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0, 0, 0), [single](0.09 / $scale))
            $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $g.FillPath($brush, $gp)
            $g.DrawPath($pen, $gp)
            $brush.Dispose()
            $pen.Dispose()
        }
        finally { $g.Dispose() }
        return $bmp
    }

    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = @()
    foreach ($s in $sizes) {
        $bmp = Render $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $frames += , $ms.ToArray()
        $bmp.Dispose(); $ms.Dispose()
    }
    $gp.Dispose()

    $fs = [System.IO.File]::Create($OutIco)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($n = 0; $n -lt $sizes.Count; $n++) {
            $s = $sizes[$n]
            $dim = if ($s -ge 256) { [Byte]0 } else { [Byte]$s }
            $bw.Write($dim); $bw.Write($dim)
            $bw.Write([Byte]0); $bw.Write([Byte]0)
            $bw.Write([UInt16]1); $bw.Write([UInt16]32)
            $bw.Write([UInt32]$frames[$n].Length)
            $bw.Write([UInt32]$offset)
            $offset += $frames[$n].Length
        }
        foreach ($f in $frames) { $bw.Write($f) | Out-Null }
    }
    finally { $bw.Dispose(); $fs.Dispose() }

    return $OutIco
}

# ---------------------------------------------------------------------------
# 4. create the shortcut, with the "run as administrator" bit cleared
# ---------------------------------------------------------------------------
function New-LauncherShortcut {
    param(
        [string]$LnkPath,
        [string]$Target,
        [string]$WorkingDirectory,
        [string]$IconPath
    )

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($LnkPath)
    $lnk.TargetPath = $Target
    $lnk.Arguments = ''
    $lnk.WorkingDirectory = $WorkingDirectory
    $lnk.IconLocation = "$IconPath,0"
    $lnk.Description = 'DeepSeek Harness web UI (no administrator rights required)'
    $lnk.WindowStyle = 1
    $lnk.Save()

    # WScript.Shell can leave the RunAsUser bit set when the target is a .cmd,
    # which would force a UAC prompt on every launch. The shell-link header
    # stores LinkFlags at offset 0x14; bit 0x20 of byte 0x15 is RunAsUser.
    $fs = [System.IO.File]::Open($LnkPath, [System.IO.FileMode]::Open,
                                 [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $buf = New-Object byte[] 1
        $fs.Position = 0x15
        $fs.Read($buf, 0, 1) | Out-Null
        $cleared = [byte]($buf[0] -band (-bnot 0x20))
        if ($cleared -ne $buf[0]) {
            $fs.Position = 0x15
            $fs.Write($cleared, 0, 1)
        }
    }
    finally { $fs.Dispose() }

    return $LnkPath
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
Write-Step 'Detecting Node.js'
$node = Resolve-NodeExe -Explicit $NodeExe
if ($node) { Write-Ok $node } else { Write-Warn 'node.exe not found - pass -NodeExe <path>' }

Write-Step 'Locating the installed dsh package'
$dsh = Resolve-DshBin -Explicit $DshBin
if ($dsh) { Write-Ok $dsh } else { Write-Warn 'dsh not found - run: npx @deepseek-ai/dsh --version' }

if (-not $WorkDir) { $WorkDir = $repoDir }
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }

Write-Step 'Resolved settings'
Write-Ok "node.exe   : $node"
Write-Ok "dsh bin.js : $dsh"
Write-Ok "workdir    : $WorkDir"
Write-Ok "shortcut   : $(Join-Path $DesktopDir ($ShortcutName + '.lnk'))"

if ($WhatIfOnly) {
    Write-Step 'WhatIfOnly: nothing was written.'
    return
}

if (-not $node) { throw 'cannot continue without node.exe; pass -NodeExe <path>' }
if (-not $dsh) { throw 'cannot continue without the dsh package; run: npx @deepseek-ai/dsh --version' }

# 4a. materialise a concrete launcher.
#
# The batch file must stay pure ASCII: cmd.exe parses a .cmd by byte offset
# while decoding it with the console code page, so a UTF-8 non-ASCII character
# (a Chinese folder name, say) desynchronises the parser and the rest of the
# file is mis-executed. So only pure-ASCII paths are substituted; anything else
# is left as a marker and found by the launcher's own auto-detection at run
# time. The working directory is never embedded at all - the shortcut carries
# it in its "Start in" field, which is UTF-16 and therefore safe.
$isAscii = { param($s) ($s.ToCharArray() | Where-Object { [int]$_ -gt 126 }).Count -eq 0 }

Write-Step 'Writing launcher'
$launcherSrc = Join-Path $repoDir 'DeepSeekHarness.cmd'
$launcherOut = Join-Path $repoDir 'DeepSeekHarness.local.cmd'
$body = [System.IO.File]::ReadAllText($launcherSrc)

$skipped = @()
if (& $isAscii $node) { $body = $body.Replace('__NODE_EXE__', $node) }
else { $skipped += 'node.exe'; Write-Warn "node.exe path is not ASCII - the launcher will auto-detect it" }

if (& $isAscii $dsh) { $body = $body.Replace('__DSH_BIN__', $dsh) }
else { $skipped += 'dsh bin.js'; Write-Warn "dsh path is not ASCII - the launcher will auto-detect it" }

[System.IO.File]::WriteAllText($launcherOut, $body, (New-Object System.Text.UTF8Encoding($false)))
$target = $launcherOut

# the generated file must never contain a non-ASCII byte
$badBytes = ([System.IO.File]::ReadAllBytes($launcherOut) | Where-Object { $_ -gt 126 }).Count
if ($badBytes -ne 0) { throw "generated launcher contains $badBytes non-ASCII bytes; cmd.exe would mis-parse it" }
Write-Ok $launcherOut

# 4b. icon
Write-Step 'Building the whale icon'
$ico = Join-Path $repoDir 'deepseek-whale.ico'
New-WhaleIcon -SvgPath $whaleSvg -OutIco $ico | Out-Null
Write-Ok "$ico ($((Get-Item -LiteralPath $ico).Length) bytes)"

if ($NoShortcut) {
    Write-Step 'NoShortcut: icon and launcher written, no shortcut created.'
    return
}

# 4c. shortcut
Write-Step 'Creating the desktop shortcut'
if (-not (Test-Path -LiteralPath $DesktopDir)) { New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null }
$lnkPath = Join-Path $DesktopDir ($ShortcutName + '.lnk')
New-LauncherShortcut -LnkPath $lnkPath -Target $target -WorkingDirectory $WorkDir -IconPath $ico | Out-Null

# verify, including that the admin bit really is clear
$bytes = [System.IO.File]::ReadAllBytes($lnkPath)
$runAsAdmin = ($bytes[0x15] -band 0x20) -ne 0
Write-Ok $lnkPath
Write-Ok ("run-as-administrator flag set: {0}" -f $runAsAdmin)

if ($runAsAdmin) { Write-Warn 'the RunAsUser bit is still set; the shortcut may prompt for UAC' }

Write-Host ''
Write-Host 'Done. Double-click the shortcut on your desktop.' -ForegroundColor Green
Write-Host 'The console window it opens must stay open; closing it stops the server.'
