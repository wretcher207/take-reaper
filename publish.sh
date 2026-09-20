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
if command -v node >/dev/null 2>&1; then
  [ -d tools/node_modules ] || (cd tools && npm install --silent --no-audit --no-fund)
  node tools/check.js || { echo "Take.lua checks failed. Not publishing."; exit 1; }
else
  echo "node not found; skipping Take.lua test harness."
fi
WEB=../take/apps/web/public/reaper; APP=../take/apps/reaper
[ -d "$WEB" ] || { echo "Can't find $WEB — is the take repo a sibling?"; exit 1; }
# This repo is pushed to origin main below.
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "take-reaper is not on main. Check out main and re-run."; exit 1; }
# The take repo must be on main, clean, and level with origin. The push +
# `vercel --prod` below run from whatever it has checked out, and vercel uploads
# the working directory rather than a commit — so a feature branch or a dirty
# tree would put unmerged app code (and migrations nobody applied) on
# takeaudio.com. A Reaper release must never be the thing that deploys that.
(
  cd ../take
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "The take repo is on $(git rev-parse --abbrev-ref HEAD), not main. Merge to main and check it out there first."; exit 1; }
  # --porcelain, not `git diff --quiet HEAD`: vercel uploads untracked files too.
  [ -z "$(git status --porcelain)" ] || { echo "The take repo has uncommitted or untracked changes; vercel --prod would deploy them. Commit, stash, or clean first:"; git status --short; exit 1; }
  git fetch --quiet origin main || { echo "Could not fetch origin/main in the take repo."; exit 1; }
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "The take repo's main is not level with origin/main. Pull or push there first."; exit 1; }
) || exit 1
echo "take repo: on main, clean, level with origin."
cp Take.lua index.xml "$WEB"/; cp Take.lua index.xml "$APP"/
git add Take.lua index.xml README.md publish.sh publish.bat tools
git commit -m "Take v$VERSION" || true
git push origin main
( cd ../take && git add apps/web/public/reaper apps/reaper && (git commit -m "Reaper: publish Take v$VERSION" || true) && git push && vercel --prod --yes )
echo "Verifying https://takeaudio.com/reaper/index.xml ..."
if curl -s https://takeaudio.com/reaper/index.xml | grep -q "name=\"$VERSION\""; then
  echo "OK: v$VERSION is live. In REAPER: ReaPack > Synchronize packages."
else
  echo "Not visible yet — deploy may still be propagating; re-check in a minute."
fi
