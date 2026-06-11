# MEMORY — Take for Reaper (decision log)

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
