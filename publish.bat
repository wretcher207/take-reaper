@echo off
REM ====================================================================
REM  Take publish - ONE script for every release.
REM  (Replaces the per-version publish-vX.Y.Z.bat files.)
REM
REM  Double-click from the take-reaper folder. It:
REM    1. Reads the version from Take.lua's "-- @version" header (one source
REM       of truth - bump it in Take.lua, that's it).
REM    2. Checks index.xml already has a <version> block for that version.
REM    3. Syntax-checks Take.lua with luac.
REM    4. Copies Take.lua + index.xml into the take web app, which serves the
REM       channel ReaPack ACTUALLY reads: https://takeaudio.com/reaper/*
REM       (NOT raw.githubusercontent.com - ReaPack never reads that).
REM    5. Commits/pushes both repos. The push to take's main starts the
REM       production deploy (GitHub Actions -> Netlify).
REM    6. Verifies the new version is live at takeaudio.com.
REM
REM  Assumed layout (the two repos are siblings):
REM      ...\take-reaper\   <- this folder (Take.lua, index.xml, publish.bat)
REM      ...\take\          <- web app, deploys to takeaudio.com
REM ====================================================================

REM Run from this script's own folder, quoted so spaces in the path are safe.
cd /d "%~dp0"

REM --- Read version from Take.lua's "-- @version X.Y.Z" header ---------
set "VERSION="
for /f "tokens=3" %%v in ('findstr /b /c:"-- @version" Take.lua') do set "VERSION=%%v"
if not defined VERSION (
  echo Could not read "-- @version" from Take.lua. Aborting.
  pause & exit /b 1
)
echo Publishing Take v%VERSION%
echo.

REM --- index.xml must already carry a matching <version> block --------
findstr /c:"<version name=\"%VERSION%\"" index.xml >nul
if errorlevel 1 (
  echo index.xml has no ^<version name="%VERSION%"^> entry.
  echo Add the changelog block for %VERSION% to index.xml first, then re-run.
  pause & exit /b 1
)

REM --- Lua syntax check (skip cleanly if luac isn't installed) --------
where luac >nul 2>nul
if not errorlevel 1 (
  luac -p Take.lua
  if errorlevel 1 (
    echo.
    echo Lua syntax check failed. Not publishing.
    pause & exit /b 1
  )
) else (
  echo luac not found; skipping local Lua syntax check.
)

REM --- Syntax + unit tests via the Node harness (tools/check.js) ------
where node >nul 2>nul
if not errorlevel 1 (
  if not exist "tools\node_modules\" (
    echo Installing test harness dependencies...
    pushd tools
    call npm install --silent --no-audit --no-fund
    popd
  )
  node tools\check.js
  if errorlevel 1 (
    echo.
    echo Take.lua checks failed. Not publishing.
    pause & exit /b 1
  )
) else (
  echo node not found; skipping Take.lua test harness.
)

REM --- This repo must be on main (we push origin main below) ---------
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set "RBRANCH=%%b"
if /i not "%RBRANCH%"=="main" (
  echo take-reaper is on "%RBRANCH%", not main. Check out main and re-run.
  pause & exit /b 1
)

REM --- Locate the sibling take repo ----------------------------------
set "WEB=..\take\apps\web\public\reaper"
set "APP=..\take\apps\reaper"
if not exist "%WEB%\" (
  echo Cannot find %WEB% - is the take repo a sibling of take-reaper?
  pause & exit /b 1
)

REM --- The take repo must be on main, clean, and level with origin ---
REM  Step 5 below pushes the take repo's main, and that push deploys
REM  takeaudio.com. A feature branch or a dirty tree would put unmerged app
REM  code on takeaudio.com - including code that expects a migration nobody has
REM  applied yet. A Reaper release must never be the thing that deploys that.
pushd "..\take"
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set "TBRANCH=%%b"
if /i not "%TBRANCH%"=="main" (
  echo.
  echo The take repo is on "%TBRANCH%", not main.
  echo Merge your work to main and check main out there first - publishing from
  echo a feature branch would deploy unmerged code to takeaudio.com.
  popd & pause & exit /b 1
)
REM  --porcelain, not `git diff --quiet HEAD`: a half-finished migration or
REM  route sitting untracked is exactly the thing this guard exists to keep
REM  out of the release commit.
set "TDIRTY="
for /f "delims=" %%s in ('git status --porcelain') do set "TDIRTY=1"
if defined TDIRTY (
  echo.
  echo The take repo has uncommitted or untracked changes. Commit, stash, or
  echo clean them first so the release commit carries only the Reaper files:
  git status --short
  popd & pause & exit /b 1
)
git fetch --quiet origin main
if errorlevel 1 (
  echo.
  echo Could not fetch origin/main in the take repo. Check the network and
  echo re-run - publishing without knowing what is on main is not safe.
  popd & pause & exit /b 1
)
for /f "delims=" %%h in ('git rev-parse HEAD') do set "THEAD=%%h"
for /f "delims=" %%h in ('git rev-parse origin/main') do set "TORIGIN=%%h"
if not "%THEAD%"=="%TORIGIN%" (
  echo.
  echo The take repo's main is not level with origin/main.
  echo   local:  %THEAD%
  echo   origin: %TORIGIN%
  echo Pull or push there first, then re-run.
  popd & pause & exit /b 1
)
popd
echo take repo: on main, clean, level with origin.
echo.

REM --- Copy the two files into both in-repo locations ----------------
copy /Y "Take.lua"  "%WEB%\Take.lua"  >nul || ( echo copy failed & pause & exit /b 1 )
copy /Y "index.xml" "%WEB%\index.xml" >nul || ( echo copy failed & pause & exit /b 1 )
copy /Y "Take.lua"  "%APP%\Take.lua"  >nul
copy /Y "index.xml" "%APP%\index.xml" >nul
echo Copied Take.lua + index.xml into the take repo.
echo.

REM --- Commit + push take-reaper (this repo) -------------------------
git add Take.lua index.xml README.md publish.bat publish.sh tools
git commit -m "Take v%VERSION%" >nul 2>nul
git push origin main
if errorlevel 1 ( echo take-reaper push failed. & pause & exit /b 1 )

REM --- Commit the reaper files in the take repo, then deploy ---------
pushd "..\take"
git add apps/web/public/reaper/Take.lua apps/web/public/reaper/index.xml apps/reaper/Take.lua apps/reaper/index.xml
git commit -m "Reaper: publish Take v%VERSION%" >nul 2>nul
git push
if errorlevel 1 ( echo take push failed. & popd & pause & exit /b 1 )
echo Pushed take main. GitHub Actions deploys it to Netlify in a few minutes.
popd

REM --- Verify the channel ReaPack actually reads --------------------
REM  Waits up to ten minutes for the deploy, checking every 30 seconds.
echo.
echo Waiting for v%VERSION% at https://takeaudio.com/reaper/index.xml ...
set /a TRIES=0
:waitlive
curl -s https://takeaudio.com/reaper/index.xml | findstr /c:"name=\"%VERSION%\"" >nul
if not errorlevel 1 goto live
set /a TRIES+=1
if %TRIES% GEQ 20 goto notlive
timeout /t 30 /nobreak >nul
goto waitlive
:notlive
echo WARNING: v%VERSION% still not visible after ten minutes.
echo Check the Deploy workflow on GitHub and the Netlify deploy log.
goto afterverify
:live
echo OK: v%VERSION% is live at takeaudio.com/reaper/index.xml
:afterverify
echo.
echo Then in REAPER: ReaPack ^> Synchronize packages, and re-open the Take panel.
pause
