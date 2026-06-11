# LEARNINGS — Take for Reaper

## 2026-06-09

- **A ReaPack `<source>` must carry the absolute download URL as the element's
  text content** — the canonical form `reapack-index` (and ReaTeam) emit:
  `<source main="main">https://takeaudio.com/reaper/Take.lua</source>`. ReaPack
  feeds whatever it resolves as the URL straight to curl. Two broken variants both
  yield `Could not resolve host: <name>`: (a) a bare filename
  `<source ...>Take.lua</source>` — curl treats `Take.lua` as a hostname; (b) the
  URL stashed in a `file=` attribute with empty content
  `<source file="https://.../Take.lua"/>` — empty URL, ReaPack falls back to the
  bare package name. **The "could not resolve host" error is never DNS here** — it
  means the index never produced a resolvable URL.

- **This repo's index is mirrored in three places that drift:**
  `take/apps/web/public/reaper/index.xml` (live, Vercel-served at
  `takeaudio.com/reaper`), `take/apps/reaper/index.xml` (dev source), and
  standalone `take-reaper/index.xml` (GitHub). Keep all three on the canonical
  form. The one canonical install URL is `https://takeaudio.com/reaper/index.xml`;
  both READMEs point there now.

- **A stale ReaPack index survives a plain "Synchronize."** To force a fresh
  fetch after fixing the index: ReaPack → Manage repositories → remove the repo →
  re-import the URL → Synchronize.

## 2026-06-08

- **REAPER's `ExecProcess` on macOS inherits an empty PATH.** When REAPER is
  launched from Finder/Dock, its environment comes from launchd, where
  `launchctl getenv PATH` is often empty. `ExecProcess` doesn't go through a
  shell, so a bare `curl` has nothing to resolve against → it never launches →
  the call reads back as `http == 0` ("No response from server"). Same root
  cause as the Windows case. **Fix: resolve curl by absolute path on every OS**
  (`/usr/bin/curl` on macOS, `System32\curl.exe` on Windows), falling back to
  bare `curl`. See `curl_bin()` in Take.lua.

- **REAPER keeps ExtState in memory and only flushes to
  `reaper-extstate.ini` on exit.** Editing that .ini while REAPER is running
  does nothing to the live value and gets overwritten on the next flush. To read
  or clear a live token you must quit REAPER (forces a flush) or trigger a fresh
  request from the script. A value read from the .ini mid-session may be stale.

- **The script writes its HTTP responses to disk** at
  `<resource>/Scripts/take_resp.json` (and `take_upload_resp.txt`). Reading those
  files is the fastest way to see what the server actually returned, without
  asking the user to retype an error.

- **Device-pairing auth (OAuth device grant) on top of `api_tokens`.** Flow:
  REAPER `POST /api/reaper/pair/start` → secret `device_code` + browser
  `verify_url`; user approves at login-gated `/reaper/authorize`; REAPER polls
  `GET /api/reaper/pair/poll` which mints an `api_tokens` row **once** and returns
  the plaintext token a single time (status flips to `claimed`). No plaintext
  token is ever stored. Table: `reaper_pairings` (migration 0022).

- **`reaper_projects` gates on a paid owner.** It only returns projects whose
  owner has a `subscriptions` row with status `active`/`trialing`. The prod
  `subscriptions` table is currently empty, so the Reaper project list comes back
  empty even with valid auth. That's the paid moat, not a bug.

- **`next/og` is the Next 16 built-in** replacement for `@vercel/og`
  (`ImageResponse`). It needs no dependency.

- **ReaImGui `BeginChild` returns a boolean visibility flag.** When the parent
  window collapses to zero available space, `BeginChild` returns `false` and no
  child window is pushed onto the ImGui stack. Calling `EndChild` in that state
  triggers `Assertion failed: child_window->Flags & ImGuiWindowFlags_ChildWindow`.
  Always guard with `if BeginChild(...) then ... EndChild() end`.

## 2026-06-11 — Audit findings (v0.6.4)

- **`JSON_NULL` sentinel is truthy** — every `field or fallback` guard on server data is dead code since 0.6.4. `import_stem`'s `timecode_offset_ms or 0` (Take.lua:788) does arithmetic on a table if the server sends null. Needs a `jval()` unwrap helper at every object-field read.
- **The publish .bat ships nothing.** ReaPack reads `takeaudio.com/reaper/index.xml` (served from take's `apps/web/public/reaper/`), not this repo. Releases require copying Take.lua + index.xml into the web app and redeploying; 0.6.3/0.6.4 went out by hand with no script.
- **`reaper.EnumerateFiles` lists files only**, so `cleanup_stale_temps` can never match `take_render_*` directories — they leak forever. Use `reaper.EnumerateSubdirectories`.
- **Synchronous `reaper.ExecProcess` curl calls freeze the whole REAPER UI** for the duration (upload timeout is 300 s). The detached-spawn + poll-a-status-file pattern `poll_pairing` uses is the fix; curl also needs `--connect-timeout/--max-time` so timeouts report as network errors, not "curl couldn't run".
- Full findings list with fixes: `../take/AUDIT-2026-06-11.md` (issues #2, #3, #7–#11, #14, #15, #21–#28 are this repo).

## 2026-06-11 (cont.) — #7 async HTTP is feasible (ExecProcess detach)

- **`reaper.ExecProcess` blocks until the whole process group's stdout pipe hits EOF — a bare `&` does NOT make it return early.** Backgrounded child inherits the stdout pipe, so ExecProcess waits for the child even though the shell exited. Measured: `sh -c "sleep 2 &"` blocked 2025ms.
- **Redirect all three std streams and it returns immediately while the process runs on:** `sh -c "sleep 2 </dev/null >/dev/null 2>&1 &"` → 19ms. Real detached curl: ExecProcess returned in 87ms; curl then finished in the background writing http_code=200 + body.
- **Async HTTP pattern for #7:** `/bin/sh -c "curl -s -o BODY -w %{http_code} URL >STATUS 2>/dev/null </dev/null &"` → poll STATUS from the defer loop; non-empty = done, read code+body. This kills the upload UI-freeze. Build the upload path of `do_push` first as a defer-loop state machine. (Verified live in REAPER 7.74 on macOS via screencapture + osascript action-list run loop.)
