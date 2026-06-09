@echo off
REM Publish Take.lua v0.6.2 to the take-reaper ReaPack repo (origin/main).
REM Double-click from C:\Users\david\workspace\take-reaper.
REM Comments now land immediately: the panel inserts the server-returned comment
REM optimistically so it appears in the list even if the GET refresh fails.
REM Window defaults to 450×700 (with 360×480 minimum) so the comment list
REM isn't hidden below the fold.
cd /d %~dp0

where luac >nul 2>nul
if not errorlevel 1 (
  luac -p Take.lua
  if errorlevel 1 (
    echo.
    echo Lua syntax check failed. Not publishing.
    pause
    exit /b 1
  )
) else (
  echo luac not found; skipping local Lua syntax check.
)

git add Take.lua index.xml publish-v0.6.2.bat
git commit -m "Take.lua v0.6.2 - comments land immediately, usable window size" -m "Optimistic comment insert from POST response so the comment appears in the list even if the follow-up GET fails. Default window 450x700 (min 360x480) so the comment list, push stem, and project list aren't hidden below the fold. Comment list child height increased from 150 to 220px."
git push origin main
echo.
echo Done. Verify: curl https://raw.githubusercontent.com/wretcher207/take-reaper/main/index.xml
echo Then in REAPER: ReaPack ^> Synchronize packages, and re-open the Take panel.
pause
