@echo off
REM Publish Take.lua v0.5.2 to the take-reaper ReaPack repo (origin/main).
REM Double-click from C:\Users\david\workspace\take-reaper if this update
REM has not already been pushed.
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

git add Take.lua index.xml README.md publish-v0.5.2.bat
git commit -m "Take.lua v0.5.2 - clarify Reaper setup" -m "Make the Server URL and API token fields explicit in the Reaper panel and docs."
git push origin main
echo.
echo Done. Verify: curl https://raw.githubusercontent.com/wretcher207/take-reaper/main/index.xml
pause
