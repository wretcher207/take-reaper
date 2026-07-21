# HANDOFF — Take for Reaper

Cold start for a new session. Read this first, then `LEARNINGS.md` / `ERRORS.md` / `MEMORY.md` before touching anything.

## State as of 2026-07-21

Three unreleased versions are committed locally and **none are published or smoke-tested in live REAPER**:

| Version | Commit | What |
| --- | --- | --- |
| 0.6.8 | `5f1fbf9` | Security/reliability: `safe_url`/`safe_filename` sanitizers close a shell-injection hole (server strings were written into the async `.bat`/`.sh` curl scripts); unique per-request temp files (fixes a response-clobber race); JSON nulls dropped at decode (no more truthy-table crashes); UTF-16 surrogate pairs (emoji) decode correctly; every network button is async via the job system; voice record guarded against a rolling transport. |
| 0.7.0 | `5552526` | QoL: live transfer progress (uploads parse curl's `-#` meter from a stderr file, downloads poll file size); comments auto-refresh every 30s with new-comment notice; Import all + "(in session)" stem labels; voice-memo input picker in Settings; once-per-launch update nudge from the ReaPack index; `tools/check.js` test harness wired into both publish scripts. |
| 0.8.0 | `0437bb0` | Cut/loop proposals: Propose section posts a cut or loop (x2–x8) from REAPER's time selection to the current rough; proposals render as CUT/LOOP lanes with Select (time selection) and Region actions; marker sync creates regions for proposals. **Requires the take repo's server changes below.** |

Server side lives in the sibling `take` repo (public, cloned at `../take`), commit `583fa4a`:
migration `supabase/migrations/20260721120000_0028_reaper_cut_loop_proposals.sql` (extends `reaper_project_comments` with `proposal_*` fields, adds `reaper_create_proposal` RPC), route `apps/web/src/app/api/reaper/projects/[id]/proposals/route.ts`, types in `packages/shared/src/db.ts`. `pnpm -r typecheck` and all unit tests pass.

## Ship checklist (order matters)

1. **Smoke-test in live REAPER first** — three versions of changes, zero live testing. Click through: load projects, open one, push a stem (watch the upload percentage), Import all, post a comment, let the panel idle 30+ seconds (comment auto-refresh), record a voice memo with a non-default input, propose a cut from a time selection.
2. **Apply migration 0028 to prod Supabase** before the web app deploys — the comments GET RPC is dropped/recreated with a new return type. Paste the SQL in the dashboard, or `supabase db push` (may first need `supabase migration repair --status applied 20260608210000` — see MEMORY.md 2026-06-08).
3. **Deploy take**: push + `vercel --prod --yes` from the take repo root. Commit author must be `davidrussell112688@gmail.com` or Vercel Hobby marks the build BLOCKED (take/CLAUDE.md gotcha) — the existing commits are authored correctly.
4. **Publish the panel**: run `publish.bat` here. It now runs `tools/check.js` (auto-installs npm deps) before shipping, copies Take.lua + index.xml into the take repo, deploys, and verifies takeaudio.com.

## Testing without REAPER

`node tools/check.js` — luaparse syntax check on all of Take.lua, plus behavioral tests for the pure-Lua blocks (JSON codec incl. null-drop and surrogate pairs, `safe_url`/`safe_filename` injection cases, `fmt_bytes`, `version_newer`) running in a real Lua 5.4 VM (wasmoon). The carve markers are comment lines in Take.lua — if you rename those comments, update `tools/check.js`.

## Watch-list for the smoke test

- Upload progress: newest mechanism — curl `-#` stderr redirected to a `take_prog_*` file, tail-parsed each frame. If no percentage shows, the transfer still works; the fallback line shows total size only.
- Voice input picker on a real audio device (`GetInputChannelName` labels).
- The 30s comment auto-refresh should never fire while a transfer/recording/pairing is running (guarded in `loop()`).

## Candidate next slices

Pull-the-rough onto a muted reference track (A/B against the current mix — natural companion to proposals), batch stem push (all selected tracks), time-selection-bounded rough push, two-way marker sync (REAPER markers with a prefix → Take comments).

## Environment notes (this machine)

- No Lua toolchain; Node v24 present — hence the wasmoon harness.
- Git identity is repo-local only in both repos (`David Russell <davidrussell112688@gmail.com>`).
- `gh` CLI is not authenticated; pushes rely on stored git credentials.
