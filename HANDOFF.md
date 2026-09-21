## Current release: v0.8.3 (2026-09-20)

Published with David's authorization. Take main and take-reaper main are synchronized; live takeaudio.com/reaper/index.xml serves v0.8.3 and both live files match the committed release. This release simplifies Comments / Import stems / Upload audio navigation and connection setup. Native layout checked in an isolated preview; Lua syntax, state tests, and tools/check.js pass. The installed REAPER action loads this repository's Take.lua. Older notes below are historical and superseded.

> status: v0.8.2 PREPARED, NOT PUBLISHED; v0.8.1 still live; v0.9.0 scoped | one-liner: v0.8.2 safety release is staged in both repos and passes every offline check — it needs David's live REAPER smoke test, then a merge to main, then publish.bat | next: run the v0.8.2 release steps below. v0.9.0's four approved features come after.

# HANDOFF — Take for Reaper

Cold start for a new session. Read this first, then `LEARNINGS.md` / `ERRORS.md` / `MEMORY.md` before touching anything.

## v0.8.2 — prepared 2026-09-20, NOT published

Nothing has been pushed, deployed or published. ReaPack still serves 0.8.1.
`Take.lua` and `index.xml` are staged at 0.8.2 and byte-identical across all
four locations (`take-reaper/`, `take/apps/reaper/`,
`take/apps/web/public/reaper/`). Both repos are uncommitted.

**What 0.8.2 contains.** The remediation fixes that landed in the take repo
after 0.8.1 shipped and were never released (HOSTILE_REVIEW_2026-09-20 §12),
plus four fixes found reviewing them:

- Voice-memo teardown restores record-arm by **track identity**, not by index,
  skips tracks that were deleted mid-recording, and does its transport stop /
  temp-track removal / cursor restore on the **project tab the memo started in**,
  putting the user's tab back afterwards.
- An async stem import aborts — before AND after the download — if the REAPER
  tab or the selected Take project changed, and deletes the downloaded file
  instead of dropping audio into the wrong session.
- "The project owner's storage is full" on a push (413 from the reservation)
  **and** on a voice memo, which has no reservation step — its only refusal is
  the storage trigger rejecting the signed PUT, so `http_upload` now returns the
  response body and `is_quota_failure()` reads the reason out of it.
- A push is finalized against the **project it started on**. The panel stays
  clickable during an upload, so opening another project mid-transfer used to
  file an object written under the original project's folder against the new one.
- `Stop and post` no longer throws a recording away when a background comment
  refresh holds the single job slot; it refuses, keeps rolling, and on the
  fallback path names the file it kept.

`take-reaper` had **no** unreleased work to lose — its `Take.lua` is untouched
since the v0.8.1 commit, and the approved v0.9.0 features are scoped in this
file only, with no code anywhere. take-reaper is now the source of truth again,
which matters because `publish.bat` copies FROM here INTO take.

**Verified offline:** `luac -p` on all three copies, `node tools/check.js`
(syntax + Lua-VM unit tests, now covering `is_quota_failure`),
`lua tests/reaper-state.test.lua` in the take repo (now covering the push's
project binding and the voice-memo quota message), `cmp` across all four
locations, and the index parses as XML.

**Unverified — needs a live REAPER session.** Every behavior above. No agent
can test ReaImGui, the transport, project tabs, or a real upload.

### The ordered steps for David

1. **Smoke-test 0.8.2 in live REAPER first.** Load `Take.lua` from
   `take-reaper\` (or copy it over the installed script) and exercise:
   - Start a voice memo, and **while it records** reorder two tracks and delete
     a third. Stop and post. Every surviving track's record-arm must come back
     exactly as it was, the temp track must be gone, and the edit cursor must be
     where you left it.
   - Start a voice memo, **switch to another project tab**, then Stop and post
     from there. The other tab's transport, tracks and cursor must be untouched.
   - `Import all` on a project with several stems, then **switch project tabs
     mid-pull**. It must stop with "Return to the original project tab" and put
     nothing in the new tab. Switch back and pull again — it must finish.
   - Push a stem, and **while it uploads go Back and open a different project**.
     The stem must land on the project you pushed from, not the one you opened.
   - If you can get an account to its storage limit, push a stem and record a
     voice memo: both must say the owner's storage is full, not an error code.
   - Then the standard list: pairing, projects, stem push with the percentage,
     comments, 30s auto-refresh, a cut proposal.
2. **Merge to `main` in the take repo and check main out there.** `publish.bat`
   pushes and deploys production from whatever take has checked out, and
   `vercel --prod` uploads the working directory rather than a commit. The guard
   added below will refuse to run otherwise, but the merge still has to happen.
   Apply any migration that unmerged app code depends on to prod Supabase BEFORE
   that merge lands — Vercel auto-deploys on any push to take's main.
3. **Double-click `publish.bat`** in `take-reaper`. It re-runs the checks,
   copies both files into the take repo, pushes both repos and deploys.
4. **In REAPER: ReaPack > Synchronize packages**, then confirm the panel reports
   0.8.2. If the index looks stale, remove the Take repo in ReaPack and
   re-import `https://takeaudio.com/reaper/index.xml` (LEARNINGS 2026-06-09).

### publish.bat / publish.sh now guard the take repo

Both scripts refuse to run unless the take repo is on `main`, has no
uncommitted tracked changes, and is level with `origin/main` (and unless
take-reaper itself is on `main`). Today, with take on `feat/return-loop` and
dirty, running `publish.bat` would have pushed that branch and deployed its
working directory — unmerged app code, some of it depending on migrations that
are not applied — to takeaudio.com as a side effect of a Reaper release.

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

## v0.9.0: the four approved features (David, 2026-09-11)

David approved all four candidates on 2026-09-11. They are no longer candidates.
Ordered below by dependency and by how much each one is worth on its own, so the release
can be cut after any of them if it needs to ship early.

**1. Pull-the-rough onto a muted reference track.** Pull the current rough down from Take
and drop it on a new track, muted, so it can be A/B'd against the mix in progress. This is
the natural companion to the cut/loop proposals already shipped in 0.8.0, and it is the one
that changes daily use the most: right now a rough has to leave REAPER to be heard against
the session. Muted-on-arrival is the important detail, so it never surprises anyone on
playback. Do this first; it also builds the download-and-insert path the others can reuse.

**2. Time-selection-bounded rough push.** Push only what is inside the time selection
instead of the whole timeline. Small once #1 exists, because it is the same push path with
a start and end, and it makes pushing a single section for feedback cheap.

**3. Batch stem push (all selected tracks).** Push every selected track as a stem in one
action rather than one at a time. The upload-progress UI from 0.8.1 already exists and has
been verified live; the work is queueing, per-stem progress, and a partial-failure story
that does not leave half a push on the server.

**4. Two-way marker sync.** REAPER markers carrying a prefix become Take comments, and Take
comments come back as markers. Last because it is the only one with a real sync-conflict
design problem: what happens when both sides change between refreshes. Do not start it
until the first three are shipped and the prefix convention is settled.

### Before writing any of this

Read `LEARNINGS.md`, `ERRORS.md` and `MEMORY.md` first, as the top of this file says. Two
hard-won Windows lessons in ERRORS.md 2026-08-05 bear directly on this work: the
detached-curl launch needs an ExecProcess positive-timeout kill and cmd `move` rather than
forward slashes, and ReaImGui 0.10 flipped the EndChild contract. The debugging technique
that cracked both is `reaper.exe -nonewinst <probe.lua>`, which runs a script inside the
REAPER instance that is already open.

The ship checklist above is not optional and its order matters: live REAPER smoke test,
then any migration applied to prod Supabase BEFORE pushing server code, because Vercel
auto-deploys on any push to take's main and can leapfrog an unapplied migration.

Every one of these needs David's ears in a live REAPER session before it can be called
done. None of them can be verified by tests alone.

## Environment notes (this machine)

- No Lua toolchain; Node v24 present — hence the wasmoon harness.
- Git identity is repo-local only in both repos (`David Russell <davidrussell112688@gmail.com>`).
- `gh` CLI auth: user-level GH_TOKEN env var works for pushes/API.
- ReaImGui here is 0.10.0.5 — the panel's `end_child()` picks the right
  BeginChild/EndChild convention per version; don't "simplify" it back to one
  convention (see ERRORS.md, the flip-flop history).
