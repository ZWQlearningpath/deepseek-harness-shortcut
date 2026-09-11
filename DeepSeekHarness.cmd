@echo off
:: ===========================================================================
::  DeepSeek Harness - double-click launcher
::
::  Starts the `dsh` package that is already installed under your npx package
::  cache - using node.exe directly - and opens the UI in a NEW Microsoft Edge
::  tab. If a Harness server is already running, no second server is started:
::  the running instance just gets another page.
::
::  The browser hand-off itself lives in launch.ps1, which is the part a batch
::  file cannot do reliably: it has to read the authenticated URL that
::  `dsh web` prints and hand exactly that URL to msedge.exe. This file does
::  the detection and then gets out of the way.
::
::  WHY NOT "npx @deepseek-ai/dsh web" ?
::  npx revalidates its package against the registry on every start and writes
::  into the npm cache (_cacache). When that cache directory is not writable by
::  a normal user (a very common state for a machine-wide Node install), the
::  plain double-click dies with EPERM and only works from an elevated console.
::  This launcher never touches the npm cache, so no administrator is needed.
::
::  IMPORTANT - KEEP THIS FILE PURE ASCII.
::  cmd.exe parses a batch file by byte offset while decoding it with the
::  console code page. A UTF-8 non-ASCII character (a Chinese folder name, say)
::  desynchronises those two, cmd resynchronises mid-line, and the rest of the
::  file is mis-executed. So no non-ASCII path is ever written in here:
::  install.ps1 only substitutes ASCII paths, and everything else is found at
::  run time (or supplied through the environment).
::
::  Recognised environment variables (all optional):
::    DSH_NODE_EXE   full path to node.exe
::    DSH_BIN        full path to @deepseek-ai/dsh/lib/bin.js
::    DSH_WORKDIR    working directory for the server
::    DSH_EDGE_EXE   full path to msedge.exe
::    DSH_LAUNCH     full path to launch.ps1
:: ===========================================================================

setlocal EnableExtensions

:: >>>NODE_EXE
if not defined DSH_NODE_EXE set "DSH_NODE_EXE=__NODE_EXE__"
:: <<<NODE_EXE

:: >>>DSH_BIN
if not defined DSH_BIN set "DSH_BIN=__DSH_BIN__"
:: <<<DSH_BIN

:: >>>EDGE_EXE
if not defined DSH_EDGE_EXE set "DSH_EDGE_EXE=__EDGE_EXE__"
:: <<<EDGE_EXE

:: >>>LAUNCH_PS1
if not defined DSH_LAUNCH set "DSH_LAUNCH=__LAUNCH_PS1__"
:: <<<LAUNCH_PS1

if not exist "%DSH_NODE_EXE%" call :detect_node
if not exist "%DSH_BIN%" call :detect_dsh

if not exist "%DSH_NODE_EXE%" (
  echo [DeepSeek Harness] node.exe not found.
  echo Install Node.js, or re-run install.ps1 with -NodeExe pointing at it.
  echo.
  pause
  exit /b 1
)

if not exist "%DSH_BIN%" (
  echo [DeepSeek Harness] the dsh package was not found.
  echo Install it once, then re-run install.ps1:
  echo   npx @deepseek-ai/dsh --version
  echo.
  pause
  exit /b 1
)

:: working directory: whatever we inherited (usually the shortcut's "Start in"),
:: otherwise the folder holding this script
if not defined DSH_WORKDIR set "DSH_WORKDIR=%~dp0"
if exist "%DSH_WORKDIR%" cd /d "%DSH_WORKDIR%"

:: the browser hand-off script ships next to this file
if not exist "%DSH_LAUNCH%" set "DSH_LAUNCH=%~dp0launch.ps1"
if not exist "%DSH_LAUNCH%" (
  echo [DeepSeek Harness] launch.ps1 was not found next to this file.
  echo Copy the whole repository folder, not just this .cmd.
  echo.
  pause
  exit /b 1
)

:: everything the launcher needs travels through the environment, so that a
:: non-ASCII path never has to survive a command line
set "DSH_ARGS=%*"

set "DSH_PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%DSH_PWSH%" set "DSH_PWSH=powershell.exe"

"%DSH_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%DSH_LAUNCH%"
set "DSH_EXIT=%ERRORLEVEL%"

if not "%DSH_EXIT%"=="0" (
  echo.
  echo [DeepSeek Harness] the launcher stopped with code %DSH_EXIT%.
  pause
)
exit /b %DSH_EXIT%

:: --- helpers ---------------------------------------------------------------
:detect_node
if not defined DSH_NODE_EXE for /f "delims=" %%I in ('where node.exe 2^>nul') do if not defined DSH_NODE_EXE set "DSH_NODE_EXE=%%I"
if not defined DSH_NODE_EXE if exist "%ProgramFiles%\nodejs\node.exe" set "DSH_NODE_EXE=%ProgramFiles%\nodejs\node.exe"
if not defined DSH_NODE_EXE if exist "%ProgramFiles(x86)%\nodejs\node.exe" set "DSH_NODE_EXE=%ProgramFiles(x86)%\nodejs\node.exe"
if not defined DSH_NODE_EXE if exist "%LOCALAPPDATA%\Programs\nodejs\node.exe" set "DSH_NODE_EXE=%LOCALAPPDATA%\Programs\nodejs\node.exe"
exit /b 0

:detect_dsh
:: 1. the usual locations of npm's cache
if not defined DSH_BIN if exist "%LOCALAPPDATA%\npm-cache\_npx" call :scan_npx "%LOCALAPPDATA%\npm-cache\_npx"
if not defined DSH_BIN if exist "%APPDATA%\npm-cache\_npx" call :scan_npx "%APPDATA%\npm-cache\_npx"
:: 2. ask npm itself, if npm is on PATH
if not defined DSH_BIN call :npm_cache
if defined DSH_NPM_CACHE call :scan_npx "%DSH_NPM_CACHE%\_npx"
:: 3. npm installed next to node.exe but not on PATH
if not defined DSH_BIN call :npm_cache_beside_node
if defined DSH_NPM_CACHE call :scan_npx "%DSH_NPM_CACHE%\_npx"
:: 4. give up and look for a dsh checkout in the working directory
if not defined DSH_BIN if exist "%DSH_WORKDIR%node_modules\@deepseek-ai\dsh\lib\bin.js" set "DSH_BIN=%DSH_WORKDIR%node_modules\@deepseek-ai\dsh\lib\bin.js"
exit /b 0

:npm_cache
if defined DSH_NPM_CACHE exit /b 0
for /f "delims=" %%I in ('npm config get cache 2^>nul') do if not defined DSH_NPM_CACHE set "DSH_NPM_CACHE=%%I"
exit /b 0

:npm_cache_beside_node
if defined DSH_NPM_CACHE exit /b 0
for %%N in ("%DSH_NODE_EXE%") do set "DSH_NODE_DIR=%%~dpN"
if exist "%DSH_NODE_DIR%node_modules\npm\bin\npm-prefix.js" (
  for /f "delims=" %%I in ('"%DSH_NODE_EXE%" "%DSH_NODE_DIR%node_modules\npm\bin\npm-prefix.js" 2^>nul') do if not defined DSH_NPM_CACHE set "DSH_NPM_CACHE=%%I"
)
exit /b 0

:scan_npx
if not exist "%~1" exit /b 0
for /d %%D in ("%~1\*") do (
  if not defined DSH_BIN if exist "%%D\node_modules\@deepseek-ai\dsh\lib\bin.js" set "DSH_BIN=%%D\node_modules\@deepseek-ai\dsh\lib\bin.js"
)
exit /b 0
