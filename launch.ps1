# DeepSeek Harness - browser hand-off launcher
#
# Called by DeepSeekHarness.cmd / DeepSeekHarness.local.cmd. It does the three
# things a batch file cannot do reliably:
#
#   1. If a Harness server already answers on the target port it does NOT start a
#      second one. It just opens a NEW Microsoft Edge tab on the running instance,
#      so double-clicking the shortcut twice always gives you a page, never a
#      "port already in use" error.
#   2. Otherwise it starts `dsh web --no-open` with its stdout captured, watches
#      for the authenticated URL that `dsh web` prints, and opens exactly that URL
#      in Microsoft Edge - always a new tab, never the default browser by accident.
#   3. The server's console output is streamed into this window, so startup errors
#      stay visible, and the server still dies with the window.
#
# Inputs travel through the environment, never through a command line, so that a
# non-ASCII path (a Chinese folder name) never has to survive cmd.exe quoting:
#
#   DSH_NODE_EXE   full path to node.exe            (required)
#   DSH_BIN        full path to @deepseek-ai/dsh/lib/bin.js   (required)
#   DSH_WORKDIR    working directory for the server (optional)
#   DSH_EDGE_EXE   full path to msedge.exe          (optional, auto-detected)
#   DSH_ARGS       extra arguments the user passed to the .cmd, forwarded as-is
#
#   .\launch.ps1 -ProbeOnly    report what would happen, change nothing
#
# KEEP THIS FILE PURE ASCII: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI,
# so non-ASCII text in here would be mis-decoded.

[CmdletBinding()]
param(
    # Report the resolved configuration and whether a server is already running,
    # then exit without starting or opening anything. Diagnostics only.
    [switch]$ProbeOnly
)

$ErrorActionPreference = 'Stop'

$DefaultPort = 3080

function Get-EnvText([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# arguments: the port the server will listen on, taken from the dsh arguments
# ---------------------------------------------------------------------------
function Get-DshPort([string]$Arguments, [int]$Fallback) {
    if ($Arguments) {
        # --port 3099 / --port=3099 / --port "3099"
        $m = [regex]::Match($Arguments, '--port(?:=|\s+)"?(\d+)"?')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    }
    return $Fallback
}

# ---------------------------------------------------------------------------
# Microsoft Edge
# ---------------------------------------------------------------------------
function Resolve-EdgeExe([string]$Explicit) {
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) {
        return (Resolve-Path -LiteralPath $Explicit).Path
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

    return ''
}

# A URL that is already open in an Edge tab can be re-activated instead of opened
# again. A unique query parameter - which the Harness server and the Web client
# both ignore - makes the URL differ every time, so a new tab is guaranteed.
function Add-NewTabNonce([string]$Url) {
    $separator = '?'
    if ($Url.Contains('?')) { $separator = '&' }
    return $Url + $separator + 'dsh-open=' + [string][DateTime]::UtcNow.Ticks
}

# Hand one URL to Microsoft Edge. Falls back to the default browser only when Edge
# is genuinely not installed. Returns 'edge' or 'default'.
function Open-EdgeTab([string]$Url, [string]$EdgeExe) {
    if ($EdgeExe) {
        Start-Process -FilePath $EdgeExe -ArgumentList ('"' + $Url + '"') | Out-Null
        return 'edge'
    }
    Start-Process $Url | Out-Null
    return 'default'
}

# ---------------------------------------------------------------------------
# is a Harness server already serving this port?
#
# Two responses are conclusive and nothing else is accepted, so an unrelated
# service that happens to hold the port is never mistaken for the Harness:
#   * 200 (cookie accepted)  -> the index page carries the product title
#   * 401 (no cookie yet)    -> the authentication notice says so
# ---------------------------------------------------------------------------
function Test-DshWeb([int]$Port) {
    if ($Port -le 0 -or $Port -gt 65535) { return $false }
    try {
        $response = Invoke-WebRequest -Uri ("http://127.0.0.1:" + [string]$Port + "/") -UseBasicParsing -TimeoutSec 3
        return ($response.Content -match 'DeepSeek Harness')
    }
    catch {
        $webResponse = $_.Exception.Response
        if ($null -eq $webResponse) { return $false }
        try {
            if ([int]$webResponse.StatusCode -ne 401) { return $false }
            $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            return ($body -match 'dsh web authentication required')
        }
        catch { return $false }
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$nodeExe = Get-EnvText 'DSH_NODE_EXE'
$dshBin = Get-EnvText 'DSH_BIN'
$workDir = Get-EnvText 'DSH_WORKDIR'
$edgeEnv = Get-EnvText 'DSH_EDGE_EXE'
$dshArgs = Get-EnvText 'DSH_ARGS'

$port = Get-DshPort -Arguments $dshArgs -Fallback $DefaultPort
$edgeExe = Resolve-EdgeExe -Explicit $edgeEnv
$localUrl = "http://127.0.0.1:$port/"

$missing = @()
if (-not $nodeExe -or -not (Test-Path -LiteralPath $nodeExe)) { $missing += 'node.exe' }
if (-not $dshBin -or -not (Test-Path -LiteralPath $dshBin)) { $missing += 'the dsh package' }

if ($ProbeOnly) {
    Write-Step 'ProbeOnly: nothing will be started or opened.'
    Write-Ok "node.exe     : $(if ($nodeExe) { $nodeExe } else { '(unset)' })"
    Write-Ok "dsh bin.js   : $(if ($dshBin) { $dshBin } else { '(unset)' })"
    Write-Ok "msedge.exe   : $(if ($edgeExe) { $edgeExe } else { '(not found)' })"
    Write-Ok "workdir      : $(if ($workDir) { $workDir } else { '(inherited)' })"
    Write-Ok "port         : $port"
    Write-Ok "dsh args     : $(if ($dshArgs) { $dshArgs } else { '(none)' })"
    if ($missing.Count -gt 0) { Write-Warn ("missing       : " + ($missing -join ', ')) }
    if (Test-DshWeb $port) { Write-Ok "server       : a Harness server is already running on $localUrl" }
    else { Write-Ok 'server       : nothing is listening (a new server would be started)' }
    exit 0
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ("[DeepSeek Harness] cannot start: " + ($missing -join ' and ') + ' not found.') -ForegroundColor Red
    Write-Host 'Run install.ps1 again, or set DSH_NODE_EXE / DSH_BIN yourself.'
    exit 1
}

# --- case 1: a server is already running -> just open another page -------------
if (Test-DshWeb $port) {
    Write-Step "A DeepSeek Harness server is already running on $localUrl"
    $url = Add-NewTabNonce $localUrl
    $how = Open-EdgeTab -Url $url -EdgeExe $edgeExe
    if ($how -eq 'edge') { Write-Ok "opened a new Microsoft Edge tab: $url" }
    else { Write-Warn "Microsoft Edge was not found; opened the default browser instead: $url" }
    Write-Ok 'no second server was started; this window can be closed right away'
    Write-Host ''
    Write-Host 'If the page asks for authentication, use the URL printed by the console window that is already open.' -ForegroundColor Yellow
    exit 0
}

# --- case 2: no server -> start one and open the URL it prints ----------------
Write-Step 'Starting DeepSeek Harness'
Write-Ok "node  : $nodeExe"
Write-Ok "dsh   : $dshBin"
if ($edgeExe) { Write-Ok "edge  : $edgeExe" } else { Write-Warn 'Microsoft Edge was not found; the default browser will be used' }
if ($workDir) { Write-Ok "work  : $workDir" }
Write-Host ''
Write-Host 'The browser UI opens in a new Microsoft Edge tab.' -ForegroundColor Green
Write-Host 'Keep this window open while you use it; closing it stops the server.'
Write-Host ''

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $nodeExe
$startInfo.Arguments = '"' + $dshBin + '" web --no-open'
if ($dshArgs) { $startInfo.Arguments += ' ' + $dshArgs }
$startInfo.UseShellExecute = $false
# stdout is captured so the authenticated URL can be read out of it; stderr keeps
# writing straight to this console, so nothing can deadlock and errors show live.
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $false
$startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
if ($workDir -and (Test-Path -LiteralPath $workDir)) { $startInfo.WorkingDirectory = $workDir }

$server = New-Object System.Diagnostics.Process
$server.StartInfo = $startInfo
$opened = $false
$started = $false

try {
    [void]$server.Start()
    $started = $true

    while ($true) {
        $line = $server.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        Write-Host $line

        if (-not $opened) {
            $m = [regex]::Match($line, '^dsh web:\s+(\S+)')
            if ($m.Success) {
                $opened = $true
                $url = Add-NewTabNonce $m.Groups[1].Value
                $how = Open-EdgeTab -Url $url -EdgeExe $edgeExe
                Write-Host ''
                if ($how -eq 'edge') { Write-Host "==> opened a new Microsoft Edge tab: $url" -ForegroundColor Green }
                else { Write-Host "==> Microsoft Edge was not found; opened the default browser instead: $url" -ForegroundColor Yellow }
                Write-Host ''
            }
        }
    }
}
finally {
    # never leave an orphan server behind if this script is torn down first
    if ($started) {
        try {
            if ($server.HasExited -eq $false) { $server.Kill() }
        }
        catch { }
    }
}

$server.WaitForExit()
$exitCode = $server.ExitCode

if (-not $opened) {
    Write-Host ''
    Write-Host '[DeepSeek Harness] the server never printed its URL, so no page was opened.' -ForegroundColor Yellow
    Write-Host 'Use the URL printed above, or the --port argument.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "[DeepSeek Harness] exited with code $exitCode."
try { Read-Host 'Press Enter to close this window' | Out-Null } catch { }
exit 0
