# LEARNINGS — Take for Reaper

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
