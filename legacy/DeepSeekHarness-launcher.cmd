@echo off
:: ===========================================================================
::  DeepSeek Harness - original machine-specific launcher (LEGACY)
::
::  This is the first version of the fix, kept for reference because it makes
::  the root cause very explicit: it hardcodes the two absolute paths that
::  npx refused to work with, and nothing else.
::
::  PREFER ..\DeepSeekHarness.cmd for real use - it auto-detects Node and the
::  dsh package, and works after the paths below stop existing.
::
::  THE PATHS BELOW ARE FROM THE MACHINE THIS WAS FIRST WRITTEN ON.
::  They almost certainly do not match yours. Replace them, or set the
::  environment variables instead:
::     DSH_NODE_EXE   full path to node.exe
::     DSH_BIN        full path to @deepseek-ai/dsh/lib/bin.js
::     DSH_WORKDIR    working directory for the server
::
::  KEEP THIS FILE PURE ASCII. cmd.exe parses a batch file by byte offset while
::  decoding it with the console code page; a UTF-8 non-ASCII character makes
::  the two disagree and the rest of the file is mis-executed.
:: ===========================================================================

setlocal

if not defined DSH_NODE_EXE set "DSH_NODE_EXE=D:\NodeJS\node.exe"
if not defined DSH_BIN      set "DSH_BIN=D:\NodeJS\node_cache\_npx\1e7f6d9597241db0\node_modules\@deepseek-ai\dsh\lib\bin.js"
if not defined DSH_WORKDIR  set "DSH_WORKDIR=D:\NodeJS"

if not exist "%DSH_NODE_EXE%" (
  echo [DeepSeek Harness] node.exe not found at "%DSH_NODE_EXE%"
  echo Set DSH_NODE_EXE, or edit this file.
  echo.
  pause
  exit /b 1
)

if not exist "%DSH_BIN%" (
  echo [DeepSeek Harness] the dsh package was not found at:
  echo   "%DSH_BIN%"
  echo Set DSH_BIN, or edit this file.
  echo.
  pause
  exit /b 1
)

if exist "%DSH_WORKDIR%" cd /d "%DSH_WORKDIR%"

echo Starting DeepSeek Harness...
echo   node : %DSH_NODE_EXE%
echo   dsh  : %DSH_BIN%
echo.
echo The browser UI opens automatically. Keep this window open while you use it;
echo closing it stops the server.
echo.

"%DSH_NODE_EXE%" "%DSH_BIN%" web %*
set "DSH_EXIT=%ERRORLEVEL%"

echo.
echo [DeepSeek Harness] exited with code %DSH_EXIT%.
pause
exit /b %DSH_EXIT%
