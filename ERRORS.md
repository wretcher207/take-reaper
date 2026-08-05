# ERRORS — Take for Reaper

Approaches that took more than 2 attempts. Check before retrying similar tasks.

## 2026-08-05 — Windows async curl: detached .bat never ran (two stacked causes)

- **What didn't work:** Assuming the 0.6.6 detached-transfer design was portable.
  On its first-ever Windows run, every network button returned http == -1
  ("curl couldn't run"). Fixing the paths alone didn't help; fixing the launcher
  alone didn't help. Four live probes (`reaper.exe -nonewinst probe.lua` against
  the running instance) isolated the causes.
- **What worked (both required):** (a) `reaper.ExecProcess` with a **positive**
  timeout KILLS the child when it expires — 10ms is shorter than cmd.exe's
  startup, so the batch never launched; a **negative** timeout is REAPER's real
  fire-and-forget. `/bin/sh` on macOS forks within 10ms, which is why the Mac
  never saw this. (b) cmd's built-ins (`move`) reject the forward-slash paths
  `tmp_path` produces — everything the .bat touches must be backslashed. The
  `rmdir` call at cleanup already knew this; `http_run` didn't.
- **Next time:** ExecProcess fire-and-forget = negative timeout, never a tiny
  positive one. Any path handed to a cmd built-in gets `:gsub("/", "\\")`. And
  `reaper.exe -nonewinst <script.lua>` runs a probe inside the live instance —
  the fastest way to test ExecProcess behavior for real.

## 2026-08-05 — The EndChild assert is VERSION-DEPENDENT; both prior "fixes" were era-specific

- **What didn't work:** Treating either convention as universal. The guarded
  `if BeginChild then ... EndChild end` (0.5.1, re-affirmed below on 2026-06-09)
  asserts on ReaImGui 0.9. The unconditional EndChild (0.6.7 fix) asserts on
  ReaImGui 0.10+ — `BeginChild == false` no longer pushes a child, EndChild then
  fails `child_window->Flags & ImGuiWindowFlags_ChildWindow` AND destroys the
  ImGui context (the panel dies, not just one frame). Trigger in practice: the
  status child gets fully clipped when the upload progress line reflows the
  layout — so it only crashed mid-transfer.
- **What worked:** Resolve the convention ONCE at startup from
  `select(3, reaper.ImGui_GetVersion())` (returns the ReaImGui version, e.g.
  "0.10.0.5") and route all five child sites through `end_child(visible)`:
  guarded on >= 0.10, unconditional on 0.9.x. Verified live on 0.10.0.5.
- **Next time:** Before "fixing" a Begin/End pairing assert, write a 10-line
  probe that clips a child to zero and logs `BeginChild`'s return + whether
  `EndChild` throws, on the installed ReaImGui. The two entries below this one
  in the log flip-flopped on the same assert because neither checked which
  contract the running binary actually enforced.

## 2026-06-09 — ReaPack "Could not resolve host: Take.lua" misread as DNS

- **What didn't work:** Treating the error as a network/DNS problem. That led to
  commit `a0a2ce6` moving ReaPack hosting off GitHub onto `takeaudio.com` ("to
  avoid GitHub DNS issues") — pointless, the host was never the problem. Then
  commit `5eac92c` rewrote `<source>` into a `file="<URL>"` attribute with empty
  element content, which **kept** the exact same error.
- **What worked:** Putting the absolute URL back as the `<source>` element's text
  content (canonical `reapack-index` form). curl was choking on the bare filename
  `Take.lua` as a hostname the whole time — the index never held a resolvable URL.
- **Next time:** "Could not resolve host: <a filename>" from ReaPack/curl is a
  malformed `<source>`, not DNS or the network. Check the `<source>` tag holds a
  full `https://` URL as its text content before touching hosting. And remember
  the index lives in three drifting copies — fix all three.

## 2026-06-08 — "No response from server" (http == 0) on macOS

- **What didn't work:** The first curl fix resolved the executable by absolute
  path **only on Windows** (`System32\curl.exe`). On macOS it fell through to
  bare `curl`, which is exactly the case that was broken — so it changed nothing
  for a Mac user and the error persisted.
- **What worked:** Resolve curl by absolute path on **every** OS. Root cause was
  REAPER inheriting an empty launchd PATH (`launchctl getenv PATH` empty), so
  bare `curl` never launched. `/usr/bin/curl` exists on every Mac.
- **Next time:** When a DAW/GUI-app shells out and gets "no output," suspect an
  empty/over-trimmed PATH before suspecting the network. Test
  `launchctl getenv PATH` and the endpoint with a direct `curl` first.

## 2026-06-08 — Local typecheck passed, Vercel build failed

- **What didn't work:** Trusting `pnpm typecheck` locally. It passed because the
  working tree had an uncommitted fix and local `node_modules` differed from a
  clean install.
- **What worked:** Reading the Vercel build logs. The failure was a phantom
  dependency — `@vercel/og` imported but never in `package.json`, so the clean
  CI install couldn't find it. Fix was `next/og` (Next 16 built-in).
- **Next time:** "Works locally, fails in CI" on a fresh deploy → suspect an
  undeclared/phantom dependency or an uncommitted local fix. Diff committed HEAD
  vs working tree.

## 2026-06-08 — Don't trust a token field by what the user says

- The user insisted the API token was swapped, but `take_resp.json` kept saying
  `unauthorized`. The token field actually held an **invite URL**
  (`https://takeaudio.com/invite/...`), not a `take_` token. Reading the live
  request/response off disk settled it. When auth fails, inspect the literal
  value being sent, not the user's description of it.

## 2026-06-09 — ImGui_EndChild assertion: child_window->Flags & ImGuiWindowFlags_ChildWindow

- **What didn't work:** Calling `reaper.ImGui_EndChild(ctx)` unconditionally after
  `BeginChild`. When the parent window has zero available space, `BeginChild`
  returns `false` and no child window is pushed — `EndChild` then asserts.
- **What worked:** Guard with `if reaper.ImGui_BeginChild(...) then ... EndChild end`.
  All 5 `BeginChild`/`EndChild` pairs in Take.lua needed the guard.
- **Next time:** Every `BeginChild` in ReaImGui must have its `EndChild` inside
  an `if` that checks the return value. This is the standard Dear ImGui pattern.
