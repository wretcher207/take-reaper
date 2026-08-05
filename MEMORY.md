# MEMORY — Take for Reaper (decision log)

## 2026-08-05 — 0.8.1: first live Windows run; smoke test passed (minus proposals)

- **Smoke-tested 0.6.8+0.7.0+0.8.0 live** on Windows 11 / REAPER 7.78 /
  ReaImGui 0.10.0.5 — pairing, projects, stem push with progress, Import all,
  comments + 30s auto-refresh, voice memo: all passed. Cut/loop proposals still
  untested: migration 0028 is not yet applied to prod (blocked on Supabase
  dashboard access; the MCP connector on this machine only holds the Holler
  account).
- **Two Windows-only bugs found and fixed as 0.8.1** (full stories in
  ERRORS.md): the detached curl .bat never ran (positive ExecProcess timeout
  kills the child + cmd `move` rejects forward slashes), and the EndChild
  convention flipped again in ReaImGui 0.10.
- **Decided: EndChild convention is resolved at runtime**, not hardcoded —
  `end_child(visible)` picks guarded vs unconditional from the installed
  ReaImGui version, ending the 0.5.1/0.6.7 flip-flop.
- **Decided: probe the live instance instead of theorizing** —
  `reaper.exe -nonewinst <script.lua>` executes a script in the running REAPER;
  all four Windows bugs were pinned this way in one session with David clicking
  nothing.

## 2026-07-21 — Review sweep: 0.6.8 + 0.7.0 + 0.8.0 staged, unpublished

- **Three versions committed, none published or live-tested.** See `HANDOFF.md`
  for the full state, ship order (migration 0028 → deploy take → publish.bat),
  and smoke-test watch-list.
- **Decided: sanitize at choke points, not call sites.** Server strings reach
  shell scripts (async curl) only through `safe_url` (validated in the four
  `http_*` helpers) and `safe_filename` (both download sites). JSON nulls are
  dropped at decode for object keys instead of `jval()` at every read — `jval`
  remains only for array elements.
- **Decided: cut/loop proposals reuse the comment pipe.** New
  `reaper_create_proposal` RPC + `/api/reaper/projects/:id/proposals` route in
  the take repo (commit `583fa4a`); proposals arrive as comments with
  `proposal_*` fields on the existing comments GET. Panel posts from the time
  selection; 409 = no current rough (distinct from 403 paid-gate).
- **Decided: test harness in-repo.** `tools/check.js` (luaparse + wasmoon
  Lua 5.4 VM) runs from both publish scripts and aborts a release on failure.
  This is the only pre-REAPER verification path on a machine with no Lua.
- **The take repo is public on GitHub** — cloned as the `../take` sibling
  publish.bat expects. Vercel-author gotcha honored (commits authored as
  davidrussell112688@gmail.com).

## 2026-06-09 — ReaPack "could not resolve host" was a malformed `<source>`, not DNS

- **Root cause:** ReaPack index `<source>` must hold the absolute download URL as
  the element's **text content** (canonical `reapack-index` form):
  `<source main="main">https://takeaudio.com/reaper/Take.lua</source>`. Two broken
  variants we shipped both produced `Could not resolve host: Take.lua`: (a) bare
  filename `<source ...>Take.lua</source>` — curl gets `Take.lua` as a URL; (b)
  URL in a `file=` attr with empty content `<source file="https://.../Take.lua"/>`
  (commit 5eac92c) — empty download URL, ReaPack falls back to the bare package
  name.
- **False trail:** Earlier this was misdiagnosed as "GitHub DNS issues" — commit
  a0a2ce6 moved hosting off GitHub to takeaudio.com for nothing. It was never DNS.
- **Decided:** Fixed all THREE drifting copies to canonical form
  (`take/apps/web/public/reaper`, `take/apps/reaper`, standalone `take-reaper`).
  Canonical install URL is `https://takeaudio.com/reaper/index.xml`; both READMEs
  now point there (was split GitHub-raw vs takeaudio).
- **Recovery note:** A stale cached index in REAPER survives plain Synchronize —
  remove the Take repo in ReaPack and re-import the URL to force a fresh fetch.

## 2026-06-09 — Session workflow: auto-wrap-up + push-by-default

- **Decided:** At the end of every session, automatically run the session-wrap
  skill (~/.agents/skills/session-wrap/SKILL.md). Push to origin as part of the
  wrap-up by default (no need to ask). Rationale: it's a single-developer repo
  committing direct to main; there's nothing to gate.
- **Triggers:** "session end", "wrapping up", "let's stop here", "wrap up", or
  any clear end-of-session signal.

## 2026-06-08 — REAPER auth: one-click Connect over manual API keys

- **Decided:** Add a one-click browser **Connect** flow (OAuth device-pairing).
  User clicks Connect → approves in their logged-in browser → the panel receives
  and stores a token silently. No key to copy or paste.
- **Why:** David refused to ship something where users hand-manage API keys.
  Real users grab the wrong string (one pasted an invite URL into the token
  field, which is what caused the persistent `unauthorized`).
- **Rejected:** (a) Accept the invite link and exchange it server-side — invite
  links are single-use/expiring, weak long-term fit. (b) Keep tokens but make
  them painless — still has a manual paste step.
- **Kept:** The manual token field remains as a fallback alongside Connect
  (David's call), so nothing existing breaks.

## 2026-06-08 — Surgical og fix to unblock the deploy

- **Decided:** Commit only the two og-route files (`@vercel/og` → `next/og`) to
  unblock the Vercel build; leave David's ~14 files of unrelated working-tree WIP
  uncommitted.
- **Why:** `take` `main` had been undeployable (phantom `@vercel/og`), freezing
  prod at `e6db0c8`. The fix was sitting uncommitted in David's tree. Committing
  his whole WIP batch to a production SaaS unreviewed was not acceptable.

## 2026-06-08 — Migration applied via Supabase MCP, not CLI

- **Decided:** Apply migration 0022 (`reaper_pairings`) to prod via the Supabase
  tool. **Caveat:** this may not record the file version `20260608210000` in the
  remote migration history. If `supabase db push` is run later, repair with
  `supabase migration repair --status applied 20260608210000`.

## 2026-06-11 — 0.6.7: EndChild fix + sync

- **ReaImGui 0.9+ asserts if `EndChild` is skipped when `BeginChild` returns false.** The `if BeginChild then ... EndChild end` pattern (added in 0.5.1 for older ReaImGui) now triggers `ImGui_EndChild assert (:NNN)` when a child has no visible area. Fixed in 0.6.7 by unconditionally calling `EndChild` — content still only renders when `BeginChild` is true.
- **All three copies now at 0.6.7**: `take/apps/reaper`, `take/apps/web/public/reaper`, `take-reaper`. Verified byte-identical via md5. takeaudio.com deployed.

## 2026-06-11 — Audited, fixes deferred

- Full audit of Take.lua v0.6.4 + publish pipeline; API contract vs web app
  verified clean, all three Take.lua/index.xml copies byte-identical.
- Report lives in the take repo: `AUDIT-2026-06-11.md`. Top fixes for this
  repo: `jval()` JSON-null guard, parameterized publish script that copies
  into the web app, async curl, render-temp-dir cleanup, `reaper.atexit`.
