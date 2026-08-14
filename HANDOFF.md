> status: active | one-liner: Take REAPER panel v0.8.1 published and verified live on Windows | next: unknown

# HANDOFF — Take for Reaper

Cold start for a new session. Read this first, then `LEARNINGS.md` / `ERRORS.md` / `MEMORY.md` before touching anything.

## State as of 2026-08-05 — v0.8.1 SHIPPED

**v0.8.1 is published and verified live** at `takeaudio.com/reaper/index.xml`.
The whole July 21 backlog went out in one release: 0.6.8 (security), 0.7.0
(QoL), 0.8.0 (cut/loop proposals), 0.8.1 (Windows fixes). The full smoke test
passed live on Windows 11 / REAPER 7.78 / ReaImGui 0.10.0.5 — pairing, projects,
stem push with upload progress, Import all, comments + 30s auto-refresh, voice
memo, and cut/loop proposals end to end. Migration 0028 is applied to prod
Supabase (David, via dashboard — this machine's Supabase MCP only holds the
Holler account, not Take's). Web app deployed via GitHub→Vercel auto-deploy
(commit `b4e767b` in the take repo).

Two Windows-only bugs were found on the panel's first-ever Windows run and fixed
as 0.8.1 — the detached-curl launch (ExecProcess positive-timeout kill + cmd
`move` vs forward slashes) and the ReaImGui 0.10 EndChild contract flip. Full
stories with the "next time" lessons in **ERRORS.md 2026-08-05** (both entries).
The debugging technique that cracked them: `reaper.exe -nonewinst <probe.lua>`
runs a script inside the already-running REAPER instance.

**Nothing is stranded.** Both repos clean and pushed: take-reaper `693a7aa`,
take `b4e767b`.

## Ship checklist for the NEXT release (order matters, all steps verified 2026-08-05)

1. **Smoke-test in live REAPER** — load projects, open one, push a stem (watch
   the upload percentage), Import all, post a comment, idle 30+ seconds
   (comment auto-refresh), voice memo on a non-default input, propose a cut.
2. **If there's a new migration, apply it to prod Supabase first** (dashboard
   paste; `supabase db push` may need
   `supabase migration repair --status applied 20260608210000` — MEMORY.md
   2026-06-08). Note the Vercel GitHub integration auto-deploys on ANY push to
   take's main — a push can leapfrog an unapplied migration, so apply before
   pushing server code that needs it.
3. **Bump `-- @version` in Take.lua AND add the matching
   `<version name="X.Y.Z">` block to index.xml** — publish.bat refuses to run
   without the index block.
4. **Run `publish.bat`** — runs tools/check.js, copies Take.lua + index.xml into
   the take repo (both locations), pushes both repos, verifies takeaudio.com.
   No vercel CLI on this box; the take push auto-deploys production anyway, so
   the script's immediate verify may warn — re-check the live index a minute
   later. Commit author must be `davidrussell112688@gmail.com` or Vercel Hobby
   blocks the build (repo-local git identity already set in both repos).

## Testing without REAPER

`node tools/check.js` — luaparse syntax check on all of Take.lua, plus behavioral tests for the pure-Lua blocks (JSON codec incl. null-drop and surrogate pairs, `safe_url`/`safe_filename` injection cases, `fmt_bytes`, `version_newer`) running in a real Lua 5.4 VM (wasmoon). The carve markers are comment lines in Take.lua — if you rename those comments, update `tools/check.js`.

## Testing WITH REAPER (without clicking)

`& "C:\Program Files\REAPER (x64)\reaper.exe" -nonewinst <script.lua>` executes
a ReaScript inside the running instance — write results to a temp file and read
them back. This is how the 2026-08-05 Windows bugs were isolated. ExecProcess
gotchas live in ERRORS.md.

## Candidate next slices

Pull-the-rough onto a muted reference track (A/B against the current mix — natural companion to proposals), batch stem push (all selected tracks), time-selection-bounded rough push, two-way marker sync (REAPER markers with a prefix → Take comments).

## Environment notes (this machine)

- No Lua toolchain; Node v24 present — hence the wasmoon harness.
- Git identity is repo-local only in both repos (`David Russell <davidrussell112688@gmail.com>`).
- `gh` CLI auth: user-level GH_TOKEN env var works for pushes/API.
- ReaImGui here is 0.10.0.5 — the panel's `end_child()` picks the right
  BeginChild/EndChild convention per version; don't "simplify" it back to one
  convention (see ERRORS.md, the flip-flop history).
