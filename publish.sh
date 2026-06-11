#!/usr/bin/env bash
# Take publish (macOS/Linux) — one script for every release.
# Reads the version from Take.lua's @version header, ships to the channel
# ReaPack actually reads (takeaudio.com/reaper/*), and deploys.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(grep '^-- @version' Take.lua | awk '{print $3}')
[ -n "$VERSION" ] || { echo "No @version in Take.lua"; exit 1; }
echo "Publishing Take v$VERSION"
grep -q "<version name=\"$VERSION\"" index.xml || { echo "index.xml has no block for v$VERSION — add the changelog first."; exit 1; }
command -v luac >/dev/null 2>&1 && luac -p Take.lua
WEB=../take/apps/web/public/reaper; APP=../take/apps/reaper
[ -d "$WEB" ] || { echo "Can't find $WEB — is the take repo a sibling?"; exit 1; }
cp Take.lua index.xml "$WEB"/; cp Take.lua index.xml "$APP"/
git add Take.lua index.xml publish.sh publish.bat
git commit -m "Take v$VERSION" || true
git push origin main
( cd ../take && git add apps/web/public/reaper apps/reaper && (git commit -m "Reaper: publish Take v$VERSION" || true) && git push && vercel --prod --yes )
echo "Verifying https://takeaudio.com/reaper/index.xml ..."
if curl -s https://takeaudio.com/reaper/index.xml | grep -q "name=\"$VERSION\""; then
  echo "OK: v$VERSION is live. In REAPER: ReaPack > Synchronize packages."
else
  echo "Not visible yet — deploy may still be propagating; re-check in a minute."
fi
