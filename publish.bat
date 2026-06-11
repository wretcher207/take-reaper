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
REM    5. Commits/pushes both repos and deploys take to production (Vercel).
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

REM --- Locate the sibling take repo ----------------------------------
set "WEB=..\take\apps\web\public\reaper"
set "APP=..\take\apps\reaper"
if not exist "%WEB%\" (
  echo Cannot find %WEB% - is the take repo a sibling of take-reaper?
  pause & exit /b 1
)

REM --- Copy the two files into both in-repo locations ----------------
copy /Y "Take.lua"  "%WEB%\Take.lua"  >nul || ( echo copy failed & pause & exit /b 1 )
copy /Y "index.xml" "%WEB%\index.xml" >nul || ( echo copy failed & pause & exit /b 1 )
copy /Y "Take.lua"  "%APP%\Take.lua"  >nul
copy /Y "index.xml" "%APP%\index.xml" >nul
echo Copied Take.lua + index.xml into the take repo.
echo.

REM --- Commit + push take-reaper (this repo) -------------------------
git add Take.lua index.xml publish.bat
git commit -m "Take v%VERSION%" >nul 2>nul
git push origin main
if errorlevel 1 ( echo take-reaper push failed. & pause & exit /b 1 )

REM --- Commit the reaper files in the take repo, then deploy ---------
pushd "..\take"
git add apps/web/public/reaper/Take.lua apps/web/public/reaper/index.xml apps/reaper/Take.lua apps/reaper/index.xml
git commit -m "Reaper: publish Take v%VERSION%" >nul 2>nul
git push

echo.
where vercel >nul 2>nul
if not errorlevel 1 (
  echo Deploying take to production ^(Vercel^)...
  call vercel --prod --yes
) else (
  echo vercel CLI not found - deploy take manually: vercel --prod --yes
)
popd

REM --- Verify the channel ReaPack actually reads --------------------
echo.
echo Verifying https://takeaudio.com/reaper/index.xml ...
curl -s https://takeaudio.com/reaper/index.xml | findstr /c:"name=\"%VERSION%\"" >nul
if errorlevel 1 (
  echo WARNING: v%VERSION% not visible at takeaudio.com yet.
  echo The deploy may still be propagating - re-check in a minute.
) else (
  echo OK: v%VERSION% is live at takeaudio.com/reaper/index.xml
)
echo.
echo Then in REAPER: ReaPack ^> Synchronize packages, and re-open the Take panel.
pause
