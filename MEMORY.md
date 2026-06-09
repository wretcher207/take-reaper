# MEMORY — Take for Reaper (decision log)

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
