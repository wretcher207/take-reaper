@echo off
REM Publish Take.lua v0.5.0 to the take-reaper ReaPack repo (origin/main).
REM Double-click after the matching Take web app API is deployed.
cd /d %~dp0
luac -p Take.lua
if errorlevel 1 (
  echo.
  echo Lua syntax check failed. Not publishing.
  pause
  exit /b 1
)
git add Take.lua index.xml README.md publish-v0.5.0.bat
git commit -m "Take.lua v0.5.0 - session review cockpit" -m "Jump from comments to the edit cursor, drop Take markers, and open voice memos from the Reaper panel."
git push origin main
echo.
echo Done. Verify: curl https://raw.githubusercontent.com/wretcher207/take-reaper/main/index.xml
pause
