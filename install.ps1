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

    # msedge.exe to open the UI with. Auto-detected when omitted.
    [string]$EdgeExe,

    # Working directory for the launched server. Defaults to the folder this
    # repository lives in, which is a sensible project root for the UI.
    [string]$WorkDir,

    # Where the shortcut is written. Defaults to the current user's Desktop.
    [string]$DesktopDir,

    # Name of the shortcut file, without the .lnk extension.
    [string]$ShortcutName = 'DeepSeek Harness',

    # Build the icon but do not create the shortcut.
    [switch]$NoShortcut,

    # Leave the installed dsh frontend's favicon alone. The browser tab then goes
    # back to the official behaviour of turning into a WHITE whale on a dark theme.
    [switch]$NoFaviconPatch,

    # Patch the frontend favicon (the browser tab icon) and do nothing else. This
    # is the run to use when the npm cache belongs to Administrators and the tab
    # icon is the only thing that needs one elevated invocation.
    [switch]$OnlyFavicon,

    # Put the installed frontend's original favicon.svg back and do nothing else.
    [switch]$RestoreFavicon,

    # Detect and report only; write nothing.
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$assetsDir = Join-Path $repoDir 'assets'
$whaleSvg = Join-Path $assetsDir 'deepseek-whale.svg'
$whaleBlackSvg = Join-Path $assetsDir 'deepseek-whale-black.svg'
$launchPs1 = Join-Path $repoDir 'launch.ps1'
$windowStatePs1 = Join-Path $repoDir 'window-state.ps1'

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
# 3. locate Microsoft Edge
# ---------------------------------------------------------------------------
function Resolve-EdgeExe {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "the -EdgeExe path does not exist: $Explicit"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }

    $cmd = Get-Command msedge.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

# ---------------------------------------------------------------------------
# 4. the favicon the browser tab shows
#
# The frontend that dsh serves ships its favicon with a dark-mode rule that turns
# the whale WHITE whenever the browser is in a dark theme. The page icon should
# stay a black whale, matching the shortcut icon, so this copies our always-black
# copy over the installed file - backing the original up as favicon.svg.orig
# first, which is also what -RestoreFavicon puts back.
#
# This is the only file the installer touches outside this repository. It is
# rewritten whenever the package is reinstalled or upgraded, so run install.ps1
# again afterwards.
# ---------------------------------------------------------------------------
function Get-FrontendFaviconPath {
    param([string]$DshBinPath)

    if (-not $DshBinPath) { return $null }

    # ...\node_modules\@deepseek-ai\dsh\lib\bin.js
    #   -> ...\node_modules\@deepseek-ai\dsh-web-frontend\dist\favicon.svg
    $dshPkg = Split-Path -Parent (Split-Path -Parent $DshBinPath)
    $scope = Split-Path -Parent $dshPkg
    if (-not $scope) { return $null }

    $target = Join-Path $scope 'dsh-web-frontend\dist\favicon.svg'
    if (Test-Path -LiteralPath $target) { return $target }
    return $null
}

# Can this account write that file? On a machine-wide Node.js install the npm
# cache belongs to BUILTIN\Administrators with Users limited to ReadAndExecute -
# the very reason `npx` needed an elevated console. The optional favicon patch
# inherits that, while everything else here works without administrator rights.
function Test-WritableFile {
    param([string]$Target)

    $dir = Split-Path -Parent $Target
    $probe = Join-Path $dir ('.dsh-write-probe-' + [Guid]::NewGuid().ToString('N'))
    try {
        $stream = [System.IO.File]::Create($probe)
        $stream.Dispose()
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

function Update-FrontendFavicon {
    param([string]$Target, [string]$BlackSvg, [switch]$Restore)

    if (-not $Target) { return $false }
    $backup = "$Target.orig"

    if ($Restore) {
        if (-not (Test-Path -LiteralPath $backup)) { return $false }
        Copy-Item -LiteralPath $backup -Destination $Target -Force
        return $true
    }

    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $Target -Destination $backup -Force
    }

    $want = [System.IO.File]::ReadAllText($BlackSvg)
    $have = [System.IO.File]::ReadAllText($Target)
    if ($have -ne $want) {
        Copy-Item -LiteralPath $BlackSvg -Destination $Target -Force
    }
    return $true
}

# One reporting wrapper around the patch, so the normal install and the elevated
# `-OnlyFavicon` run explain themselves identically.
function Set-FrontendFavicon {
    param([string]$Target, [string]$BlackSvg)

    $elevatedHint = 'For the always-black tab icon, run this once from an elevated PowerShell:'
    $elevatedCmd = '  powershell -ExecutionPolicy Bypass -File .\install.ps1 -OnlyFavicon'

    if (-not $Target) {
        Write-Warn 'the installed dsh frontend was not found next to the dsh package; nothing to patch'
        return $false
    }
    if (-not (Test-Path -LiteralPath $BlackSvg)) {
        Write-Warn "missing asset: $BlackSvg"
        return $false
    }
    # Already in the desired state? Then there is nothing to write and no
    # permissions to worry about - report success rather than a write error.
    try {
        if ([System.IO.File]::ReadAllText($Target) -eq [System.IO.File]::ReadAllText($BlackSvg)) {
            Write-Ok "$Target (already the always-black whale)"
            return $true
        }
    }
    catch { }

    if (-not (Test-WritableFile -Target $Target)) {
        Write-Warn "cannot write $Target"
        Write-Warn 'this npm cache belongs to Administrators - the same reason npx needed an elevated console.'
        Write-Warn 'Everything else in this installer still works without administrator rights.'
        Write-Warn $elevatedHint
        Write-Warn $elevatedCmd
        Write-Warn 'or skip the tab icon with -NoFaviconPatch.'
        return $false
    }

    try {
        Update-FrontendFavicon -Target $Target -BlackSvg $BlackSvg | Out-Null
        # Verify by comparing the bytes actually on disk with the asset. Grepping
        # for the dark-mode rule would be wrong: the asset documents that rule in
        # its own comment.
        $want = [System.IO.File]::ReadAllText($BlackSvg)
        $have = [System.IO.File]::ReadAllText($Target)
        if ($have -ne $want) {
            Write-Warn "the patch did not take: $Target"
            return $false
        }
        Write-Ok "$Target (original kept as favicon.svg.orig)"
        return $true
    }
    catch {
        Write-Warn "could not patch the favicon: $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# 5. build the whale icon (transparent background)
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
# 6. create the shortcut, with the "run as administrator" bit cleared
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

Write-Step 'Locating Microsoft Edge'
$edge = Resolve-EdgeExe -Explicit $EdgeExe
if ($edge) { Write-Ok $edge } else { Write-Warn 'msedge.exe not found - the launcher will fall back to the default browser' }

if (-not $WorkDir) { $WorkDir = $repoDir }
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }

$favicon = Get-FrontendFaviconPath -DshBinPath $dsh
$faviconWritable = $false
$faviconPatched = $false
$faviconState = 'not found (nothing to patch)'
if ($favicon) {
    $faviconWritable = Test-WritableFile -Target $favicon
    try {
        $faviconPatched = (Test-Path -LiteralPath $whaleBlackSvg) -and
                          ([System.IO.File]::ReadAllText($favicon) -eq [System.IO.File]::ReadAllText($whaleBlackSvg))
    }
    catch { $faviconPatched = $false }

    if (Test-Path -LiteralPath "$favicon.orig") { $faviconState = "$favicon (backup: favicon.svg.orig)" }
    else { $faviconState = "$favicon (no backup yet)" }
    if ($faviconPatched) { $faviconState += ' [already the always-black whale]' }
    elseif (-not $faviconWritable) { $faviconState += ' [NOT WRITABLE by this account]' }
}

Write-Step 'Resolved settings'
Write-Ok "node.exe   : $node"
Write-Ok "dsh bin.js : $dsh"
Write-Ok "msedge.exe : $edge"
Write-Ok "workdir    : $WorkDir"
Write-Ok "launch.ps1 : $launchPs1"
if (Test-Path -LiteralPath $windowStatePs1) {
    foreach ($line in (& $windowStatePs1 -Mode show)) { Write-Ok "window mem : $line" }
}
else {
    Write-Warn 'window mem : window-state.ps1 is missing - the window size will not be remembered'
}
Write-Ok "shortcut   : $(Join-Path $DesktopDir ($ShortcutName + '.lnk'))"
Write-Ok "favicon    : $faviconState"

if ($WhatIfOnly) {
    Write-Step 'WhatIfOnly: nothing was written.'
    return
}

if (-not $node) { throw 'cannot continue without node.exe; pass -NodeExe <path>' }
if (-not $dsh) { throw 'cannot continue without the dsh package; run: npx @deepseek-ai/dsh --version' }

# 4a. the tab icon on its own, for the one elevated run.
if ($OnlyFavicon) {
    Write-Step 'Patching the browser tab icon only'
    [void](Set-FrontendFavicon -Target $favicon -BlackSvg $whaleBlackSvg)
    return
}

# 4b. put the official favicon back and stop here.
if ($RestoreFavicon) {
    Write-Step 'Restoring the original frontend favicon'
    if (-not $favicon) { Write-Warn 'the frontend favicon was not found; nothing to restore' }
    elseif (-not (Test-Path -LiteralPath "$favicon.orig")) { Write-Warn "no backup next to $favicon; nothing was changed" }
    elseif (-not $faviconWritable) {
        Write-Warn "cannot write $favicon - run this once from an elevated PowerShell"
    }
    else {
        try { Update-FrontendFavicon -Target $favicon -Restore | Out-Null; Write-Ok $favicon }
        catch { Write-Warn "could not restore: $($_.Exception.Message)" }
    }
    return
}

# 4c. materialise a concrete launcher.
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

if ($edge -and (& $isAscii $edge)) { $body = $body.Replace('__EDGE_EXE__', $edge) }
else { $skipped += 'msedge.exe'; Write-Warn 'msedge.exe was not baked in - the launcher will auto-detect it' }

if (& $isAscii $launchPs1) { $body = $body.Replace('__LAUNCH_PS1__', $launchPs1) }
else { $skipped += 'launch.ps1'; Write-Warn 'the launch.ps1 path is not ASCII - it will be found next to the launcher' }

[System.IO.File]::WriteAllText($launcherOut, $body, (New-Object System.Text.UTF8Encoding($false)))
$target = $launcherOut

# the generated file must never contain a non-ASCII byte
$badBytes = ([System.IO.File]::ReadAllBytes($launcherOut) | Where-Object { $_ -gt 126 }).Count
if ($badBytes -ne 0) { throw "generated launcher contains $badBytes non-ASCII bytes; cmd.exe would mis-parse it" }
Write-Ok $launcherOut

# 4d. icon
Write-Step 'Building the whale icon'
$ico = Join-Path $repoDir 'deepseek-whale.ico'
New-WhaleIcon -SvgPath $whaleSvg -OutIco $ico | Out-Null
Write-Ok "$ico ($((Get-Item -LiteralPath $ico).Length) bytes)"

# 4e. the favicon the browser tab shows
if ($NoFaviconPatch) {
    Write-Step 'Favicon patch skipped (-NoFaviconPatch)'
    Write-Warn 'the tab icon keeps the official behaviour: white whale on a dark theme'
}
else {
    Write-Step 'Making the browser tab icon an always-black whale'
    Set-FrontendFavicon -Target $favicon -BlackSvg $whaleBlackSvg | Out-Null
}

if ($NoShortcut) {
    Write-Step 'NoShortcut: launcher and icon written, no shortcut created.'
    return
}

# 4f. shortcut
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
Write-Host 'It opens the UI in its own Microsoft Edge app window (own taskbar whale button, remembered size) and reuses the running server when there is one.'
Write-Host 'The console window it opens must stay open; closing it stops the server.'
