-- @description Take for Reaper
-- @version 0.8.1
-- @author Dead Pixel Design
-- @about
--   A docked panel that connects this Reaper session to your Take projects.
--   Paste an API token (create one at takeaudio.com/settings/reaper), browse the
--   projects you collaborate on, pull stems onto tracks at their timecode, and
--   push back: render the selected track as a new stem, or render the master as
--   a new rough. Read the project's comments and drop your own from the panel —
--   text or a recorded voice memo — pinned to the edit cursor on the current
--   rough. Reaper is the only client that touches original WAVs, and it's
--   paid-only — the owner of the project must be on a paid plan.
--
--   Pushes use this project's REAPER render format. Set it to WAV, AIFF, FLAC,
--   or MP3 in the Render dialog (File > Render) once; Take reuses it.

if not reaper.ImGui_GetVersion then
  reaper.MB("Take requires the ReaImGui extension. Install it via ReaPack first.", "Take", 0)
  return
end

local EXT = "TAKE"
local DEFAULT_BASE_URL = "https://takeaudio.com"
local ctx = reaper.ImGui_CreateContext("Take")

-- Read our own "-- @version" header so the update check has one source of
-- truth (no second constant to forget when bumping).
local VERSION = (function()
  local path = debug.getinfo(1, "S").source:match("^@(.+)$")
  local f = path and io.open(path, "rb")
  if not f then return nil end
  local head = f:read(400) or ""
  f:close()
  return head:match("%-%- @version%s+(%S+)")
end)()

-- Seed math.random (render temp-dir suffixes). Unseeded Lua repeats the same
-- sequence every REAPER launch, so two same-second pushes could collide.
math.randomseed(os.time())

-- ReaImGui 0.10 changed BeginChild's contract AGAIN: a false return now means
-- no child window was pushed, and calling EndChild anyway asserts
-- ("child_window->Flags & ImGuiWindowFlags_ChildWindow") and destroys the whole
-- ImGui context (verified live on 0.10.0.5, 2026-08-05 — the status child gets
-- fully clipped mid-upload when the progress line reflows the layout). On 0.9
-- the contract was the opposite — EndChild must ALWAYS be called, even after a
-- false BeginChild (the 0.6.7 fix, MEMORY 2026-06-11). Both users exist in the
-- wild, so pick the convention once from the running ReaImGui's own version and
-- route every child through end_child(visible).
local END_CHILD_ALWAYS = (function()
  local _, _, rv = reaper.ImGui_GetVersion()
  local maj, min = tostring(rv or ""):match("^(%d+)%.(%d+)")
  maj, min = tonumber(maj) or 0, tonumber(min) or 0
  return maj == 0 and min < 10
end)()
local function end_child(visible)
  if visible or END_CHILD_ALWAYS then reaper.ImGui_EndChild(ctx) end
end

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$")
end

local state = {
  base_url = trim(reaper.GetExtState(EXT, "base_url")),
  token = trim(reaper.GetExtState(EXT, "token")),
  view = "projects", -- "projects" | "project"
  projects = {},
  project = nil, -- { id, name }
  stems = {},
  comments = {},
  comment_body = "",
  comment_at_cursor = true,
  push_name = "",
  status = "",
  show_settings = false,
  recording = false,
  voice = nil, -- in-flight voice-memo record state (temp track, saved arm, cursor)
  pairing = nil, -- in-flight one-click Connect (device_code, deadline, next_poll)
  scroll_comments = false, -- set after post_comment to auto-scroll to bottom
  job = nil, -- in-flight async network job (a coroutine pumped by loop())
  voice_input = tonumber(reaper.GetExtState(EXT, "voice_input")) or 0, -- mono input for memos (0-based)
  stem_presence = {}, -- stem_id -> true when its file is already in this session
  presence_next = 0, -- next stem-presence rescan (throttled from the draw)
  comments_next_poll = 0, -- next live comment auto-refresh
  transfer = nil, -- in-flight transfer progress ({kind="up"|"down", path|prog, total})
  update_available = nil, -- newer version string found on the ReaPack index
  update_checked = false, -- the once-per-launch index check has run
  propose_note = "", -- optional note attached to a cut/loop proposal
  loop_count = 2, -- proposed loop repeat count (server clamps to 2..8)
}
if state.base_url == ""
    or state.base_url == "https://take-ebon.vercel.app"
    or state.base_url:find("raw.githubusercontent.com", 1, true) then
  state.base_url = DEFAULT_BASE_URL
  reaper.SetExtState(EXT, "base_url", state.base_url, true)
else
  state.base_url = state.base_url:gsub("/+$", "")
end

-- Formats Take accepts (matches the web upload policy).
local ACCEPTED = { wav = true, aif = true, aiff = true, flac = true, mp3 = true }
local MIME = {
  wav = "audio/wav", aif = "audio/aiff", aiff = "audio/aiff",
  flac = "audio/flac", mp3 = "audio/mpeg",
}

-- --------------------------------------------------------------------------
-- Minimal JSON decoder (objects, arrays, strings, numbers, bool, null).
-- --------------------------------------------------------------------------
local JSON_NULL = {} -- sentinel for JSON null; distinct from Lua nil to keep arrays dense

-- JSON_NULL is a truthy table, so a raw sentinel read would break `x or
-- default` fallbacks and do arithmetic on a table → ReaScript error. Object
-- fields are protected at decode time (null-valued keys are dropped, reading
-- them yields plain nil); JSON_NULL only survives inside arrays, where it keeps
-- them dense. jval() collapses it back to nil when reading array elements.
local function jval(v)
  if v == JSON_NULL then return nil end
  return v
end

local function json_decode(s)
  local i, n = 1, #s
  local parse_value

  local function skip_ws()
    while i <= n do
      local c = s:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
    end
  end

  local function parse_string()
    i = i + 1 -- opening quote
    local buf = {}
    while i <= n do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1; return table.concat(buf) end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        if e == "n" then buf[#buf + 1] = "\n"
        elseif e == "t" then buf[#buf + 1] = "\t"
        elseif e == "r" then buf[#buf + 1] = "\r"
        elseif e == "b" then buf[#buf + 1] = "\b"
        elseif e == "f" then buf[#buf + 1] = "\f"
        elseif e == "/" then buf[#buf + 1] = "/"
        elseif e == '"' then buf[#buf + 1] = '"'
        elseif e == "\\" then buf[#buf + 1] = "\\"
        elseif e == "u" then
          local hex = s:sub(i + 2, i + 5)
          local cp = tonumber(hex, 16) or 0
          i = i + 4
          -- UTF-16 surrogate pair (emoji land here): combine \uD8xx\uDCxx into
          -- one codepoint, else each half encodes as 3 bytes of mojibake.
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i + 2, i + 3) == "\\u" then
            local lo = tonumber(s:sub(i + 4, i + 7), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              i = i + 6
            end
          end
          if cp < 0x80 then
            buf[#buf + 1] = string.char(cp)
          elseif cp < 0x800 then
            buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
          elseif cp < 0x10000 then
            buf[#buf + 1] = string.char(
              0xE0 + math.floor(cp / 0x1000),
              0x80 + (math.floor(cp / 0x40) % 0x40),
              0x80 + (cp % 0x40))
          else
            buf[#buf + 1] = string.char(
              0xF0 + math.floor(cp / 0x40000),
              0x80 + (math.floor(cp / 0x1000) % 0x40),
              0x80 + (math.floor(cp / 0x40) % 0x40),
              0x80 + (cp % 0x40))
          end
        else buf[#buf + 1] = e end
        i = i + 2
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
    return table.concat(buf)
  end

  local function parse_literal()
    if s:sub(i, i + 3) == "true" then i = i + 4; return true end
    if s:sub(i, i + 4) == "false" then i = i + 5; return false end
    if s:sub(i, i + 3) == "null" then i = i + 4; return JSON_NULL end
    local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    if num then i = i + #num; return tonumber(num) end
    i = i + 1
    return nil
  end

  local function parse_array()
    local arr = {}
    i = i + 1
    skip_ws()
    if s:sub(i, i) == "]" then i = i + 1; return arr end
    local idx = 0
    while i <= n do
      skip_ws()
      idx = idx + 1
      arr[idx] = parse_value()
      skip_ws()
      local c = s:sub(i, i)
      i = i + 1
      if c == "]" then break end
    end
    return arr
  end

  local function parse_object()
    local obj = {}
    i = i + 1
    skip_ws()
    if s:sub(i, i) == "}" then i = i + 1; return obj end
    while i <= n do
      skip_ws()
      local key = parse_string()
      skip_ws()
      i = i + 1 -- colon
      skip_ws()
      -- Drop null-valued keys: obj.field reads then behave exactly like a
      -- missing field (Lua nil), so `or`-defaults and truthiness guards work
      -- without a jval() at every site. JSON_NULL still pads arrays dense.
      local val = parse_value()
      if val ~= JSON_NULL then obj[key] = val end
      skip_ws()
      local c = s:sub(i, i)
      i = i + 1
      if c == "}" then break end
    end
    return obj
  end

  parse_value = function()
    skip_ws()
    local c = s:sub(i, i)
    if c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif c == '"' then return parse_string()
    else return parse_literal() end
  end

  local okp, result = pcall(parse_value)
  if okp then return result end
  return nil
end

-- --------------------------------------------------------------------------
-- Minimal JSON encoder (strings, integers, booleans, arrays, flat objects).
-- --------------------------------------------------------------------------
local function json_encode(v)
  if v == JSON_NULL then return "null" end
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    if v == math.floor(v) and v >= -9007199254740992 and v <= 9007199254740992 then
      return string.format("%d", v)
    end
    return tostring(v)
  elseif t == "string" then
    return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
  elseif t == "table" then
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    if count == #v then
      local parts = {}
      for idx = 1, #v do parts[idx] = json_encode(v[idx]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

-- --------------------------------------------------------------------------
-- Files + HTTP via curl (ships with Windows 10+, macOS, Linux).
-- --------------------------------------------------------------------------
local function tmp_path(name)
  return reaper.GetResourcePath() .. "/Scripts/take_" .. name
end

local function q(s) return '"' .. tostring(s):gsub('"', '') .. '"' end

-- Resolve the curl executable once. REAPER's ExecProcess does not reliably
-- inherit the user's shell PATH, so a bare "curl" can fail to launch and return
-- no output (read back as http == 0, "No response from server") even though curl
-- is installed and the URL is correct. This bites macOS just as hard as Windows:
-- when REAPER is launched from Finder/Dock its PATH comes from launchd, which is
-- often empty, so a bare "curl" has nothing to resolve against. We therefore
-- prefer a known absolute path on every OS and only fall back to bare "curl" if
-- none of the candidates exist, so a PATH that already worked keeps working.
-- NOTE: do NOT quote the resolved path. None of the candidate paths contain a
-- space, and a Windows command line that both starts and ends with a quote trips
-- cmd.exe's outer-quote stripping (when ExecProcess routes through cmd), which
-- mangles the exe path and re-breaks the launch we're trying to fix.
local CURL
local function curl_bin()
  if CURL then return CURL end
  local os_name = reaper.GetOS() or ""
  if os_name:find("Win") then
    local sysroot = os.getenv("SystemRoot") or os.getenv("windir") or "C:\\Windows"
    local sys_curl = sysroot .. "\\System32\\curl.exe"
    local f = io.open(sys_curl, "rb")
    if f then f:close(); CURL = sys_curl; return CURL end
  else
    -- macOS ships curl at /usr/bin/curl; Homebrew (Apple Silicon / Intel) and
    -- most Linux distros cover the rest. First one that exists wins.
    local candidates = { "/usr/bin/curl", "/opt/homebrew/bin/curl", "/usr/local/bin/curl", "/bin/curl" }
    for _, path in ipairs(candidates) do
      local f = io.open(path, "rb")
      if f then f:close(); CURL = path; return CURL end
    end
  end
  CURL = "curl"
  return CURL
end

-- Resolve the file/URL opener by absolute path for the same reason as curl_bin:
-- REAPER's ExecProcess inherits an empty PATH (launchd on macOS), so a bare
-- "open"/"xdg-open" never launches and the browser/file silently fails to open.
-- Checking the path also sidesteps GetOS returning "macOS-arm64" (no "OSX").
local function open_file(path)
  local os_name = reaper.GetOS() or ""
  local cmd
  if os_name:find("Win") then
    cmd = "cmd /c start \"\" " .. q(path)
  else
    local opener
    for _, p in ipairs({ "/usr/bin/open", "/usr/bin/xdg-open", "/bin/open" }) do
      local f = io.open(p, "rb")
      if f then f:close(); opener = p; break end
    end
    opener = opener or (os_name:find("OSX") and "open" or "xdg-open")
    cmd = opener .. " " .. q(path)
  end
  reaper.ExecProcess(cmd, 1000)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local size = f:seek("end") or 0
  f:close()
  return size
end

local function safe_remove(path)
  if path and path ~= "" then pcall(os.remove, path) end
end

local IS_WIN = (reaper.GetOS() or ""):find("Win") ~= nil

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data); f:close()
  return true
end

-- Single-quote a string so it survives as one argument to `sh -c`.
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Server-provided strings (pre-signed URLs, filenames) end up inside shell
-- command lines — async jobs literally write them into a .bat/.sh that a shell
-- executes. Inside the double quotes q() adds, sh still expands $, backticks,
-- and backslashes, and a control character (newline) would split the script
-- into a new command on both OSes. So: validate every URL against a strict
-- shape (legit http(s) URLs never need these characters raw — they arrive
-- percent-encoded), and scrub filenames down to a safe charset. This closes a
-- command-injection hole where a hostile collaborator's stem filename, or a
-- malicious server behind a user-edited base_url, could run arbitrary code.
local function safe_url(u)
  u = tostring(u or "")
  if not u:match("^https?://") then return nil end
  if u:find("[%s%c\"'`$\\<>|]") then return nil end
  return u
end

local function safe_filename(name)
  name = tostring(name or ""):gsub("[^%w%._%- ()]", "_")
  if name == "" then name = "file" end
  return name
end

local function fmt_bytes(n)
  n = tonumber(n) or 0
  if n >= 1024 * 1024 * 1024 then return string.format("%.2f GB", n / (1024 * 1024 * 1024)) end
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  if n >= 1024 then return string.format("%.0f KB", n / 1024) end
  return math.floor(n) .. " B"
end

-- true when version string a is strictly newer than b ("0.10.1" > "0.9.9").
local function version_newer(a, b)
  local ai = {}; for d in tostring(a or ""):gmatch("%d+") do ai[#ai + 1] = tonumber(d) end
  local bi = {}; for d in tostring(b or ""):gmatch("%d+") do bi[#bi + 1] = tonumber(d) end
  if #ai == 0 or #bi == 0 then return false end
  for i = 1, math.max(#ai, #bi) do
    local x, y = ai[i] or 0, bi[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- Remove a directory and everything in it. Used for the per-render temp dirs
-- (take_render_*), which hold the rendered file plus .reapeaks sidecars and any
-- secondary-format outputs. EnumerateFiles lists files only, so collect them all
-- (don't remove mid-enumeration, which can skip entries) then drop the dir. Lua's
-- os.remove can't rmdir on Windows, so fall back to the OS rmdir there.
local function remove_dir(dir)
  if not dir or dir == "" then return end
  local names = {}
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    names[#names + 1] = fn
    i = i + 1
  end
  for _, fn in ipairs(names) do pcall(os.remove, dir .. "/" .. fn) end
  if not os.remove(dir) and (reaper.GetOS() or ""):find("Win") then
    reaper.ExecProcess('cmd /c rmdir ' .. q(dir:gsub("/", "\\")), 2000)
  end
end

-- Clean up stale temp files from previous sessions on startup. Any render/voice
-- temp from a prior run is dead weight — the only live temps are created
-- during the current session. Also catches curl resp/req JSON bodies.
local function cleanup_stale_temps()
  local base = reaper.GetResourcePath() .. "/Scripts/"
  local prefixes = { "take_render_", "take_voice_", "take_resp", "take_req", "take_upload_resp", "take_prog_", "take_job_" }
  for _, prefix in ipairs(prefixes) do
    local i = 0
    while true do
      local name = reaper.EnumerateFiles(base, i)
      if not name then break end
      i = i + 1
      if name:sub(1, #prefix) == prefix then
        pcall(os.remove, base .. name)
      end
    end
  end
  -- take_render_* are DIRECTORIES, which EnumerateFiles never lists — sweep
  -- subdirectories separately and remove each stale render dir whole.
  local di = 0
  while true do
    local sub = reaper.EnumerateSubdirectories(base, di)
    if not sub then break end
    di = di + 1
    if sub:sub(1, #"take_render_") == "take_render_" then
      remove_dir(base .. sub)
    end
  end
end
cleanup_stale_temps()

-- Pull the http status code out of ExecProcess's "<exitcode>\n<stdout>".
-- curl -w "%{http_code}" writes exactly three digits to stdout; anchor on that
-- so stray numbers in error text don't produce a false match. Returns -1 when
-- ExecProcess gave no output at all (curl never launched) — distinct from
-- curl's "000" (curl ran but couldn't connect), which parses to 0.
local function status_from(out)
  if not out or out == "" then return -1 end
  local code = out:match("\n(%d%d%d)\n*$")
  return tonumber(code) or 0
end

-- Run a curl command and return its http status. Dual-mode:
--   * On the main thread (button handlers, loop, pairing) it blocks via
--     ExecProcess exactly as before — quick GETs stay dead-simple.
--   * Inside a job coroutine it spawns curl DETACHED so REAPER's UI keeps
--     painting, then yields each frame until the command finishes. Detaching
--     is what fixes #7: a blocking ExecProcess froze the panel for the whole
--     upload (minutes on a slow line); detached it returns in ~ms.
-- Every caller passes `-o <file> -w "%{http_code}"`, so curl's stdout is just
-- the 3-digit code. Sync mode reads it out of ExecProcess's "<exit>\n<code>";
-- async mode redirects that stdout into a file and reads it back when done.
local JOB_SEQ = 0
local function http_run(cmd, timeout_ms, progress_file)
  local co, ismain = coroutine.running()
  if not co or ismain then
    return status_from(reaper.ExecProcess(cmd, timeout_ms))
  end

  JOB_SEQ = JOB_SEQ + 1
  local jid = os.time() .. "_" .. JOB_SEQ
  local code_tmp = tmp_path("job_" .. jid .. ".code")
  local done = tmp_path("job_" .. jid .. ".done")
  -- Normally curl's stderr is discarded; a caller showing upload progress
  -- passes progress_file so the panel can read the meter back mid-transfer.
  local stderr_sh = progress_file and q(progress_file) or "/dev/null"
  local script
  if IS_WIN then
    -- In a .bat a literal % must be doubled, so curl's "%{http_code}" needs
    -- escaping that the command-line (sync) path doesn't. The atomic rename
    -- (move) is the completion signal: `done` only appears once curl finished.
    -- Three Windows-only constraints, each fatal alone (found 2026-08-05, the
    -- first live Windows run):
    --   * ExecProcess with a positive timeout KILLS the child when it expires,
    --     and 10ms is shorter than cmd.exe's startup, so the batch never ran.
    --     A negative timeout is REAPER's real fire-and-forget.
    --   * cmd's built-ins (move) reject forward-slash paths, so every path the
    --     batch touches is backslashed (io.open on our side takes either).
    --   * cmd.exe by absolute path — same PATH-resolution defense as curl_bin.
    local bs = function(p) return (p:gsub("/", "\\")) end
    local stderr_bat = progress_file and q(bs(progress_file)) or "nul"
    script = tmp_path("job_" .. jid .. ".bat")
    write_file(script,
      "@echo off\r\n" ..
      cmd:gsub("%%", "%%%%") .. " > " .. q(bs(code_tmp)) .. " 2>" .. stderr_bat .. "\r\n" ..
      "move /y " .. q(bs(code_tmp)) .. " " .. q(bs(done)) .. " >nul 2>nul\r\n")
    local cmdexe = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\cmd.exe"
    reaper.ExecProcess(cmdexe .. ' /c start "" /b cmd /c ' .. q(bs(script)), -2)
  else
    script = tmp_path("job_" .. jid .. ".sh")
    write_file(script,
      "#!/bin/sh\n" ..
      cmd .. " > " .. q(code_tmp) .. " 2>" .. stderr_sh .. "\n" ..
      "mv " .. q(code_tmp) .. " " .. q(done) .. "\n")
    -- The trailing `&` (inside sh -c) is what actually detaches; without the
    -- stdio redirects ExecProcess still waits on the pipe and we gain nothing.
    reaper.ExecProcess("/bin/sh -c " ..
      shq("/bin/sh " .. q(script) .. " </dev/null >/dev/null 2>&1 &"), 10)
  end

  -- curl's own --max-time sits just under timeout_ms, so it self-terminates and
  -- still writes a code ("000"); the grace covers defer scheduling. If `done`
  -- never lands, the script never launched -> treat as "no response" (-1).
  local deadline = reaper.time_precise() + (timeout_ms / 1000) + 5
  while not file_exists(done) do
    if reaper.time_precise() > deadline then
      safe_remove(script); safe_remove(code_tmp)
      return -1
    end
    coroutine.yield()
  end

  local code = read_file(done) or ""
  safe_remove(script); safe_remove(done)
  if code == "" then return -1 end
  return tonumber(code:match("%d%d%d")) or 0
end

-- Start an async network job. Body runs as a coroutine pumped by loop(): it
-- executes synchronously until the first http_run, then yields while curl runs
-- detached. One job at a time — the panel drives a single operation anyway, and
-- the fixed resp/req temp filenames are only safe because jobs are serial.
local function start_job(body)
  if state.job then
    state.status = "Busy — finish the current operation first."
    return false
  end
  state.job = coroutine.create(body)
  return true
end

-- curl --connect-timeout/--max-time sit just under each ExecProcess timeout so
-- curl exits on its own (writing http_code "000" -> status 0 -> "couldn't reach
-- the server") instead of ExecProcess returning nil (status -1 -> the wrong
-- "curl couldn't run" message) while an orphaned curl keeps running.
-- Each request gets its own numbered req/resp temp file. A single shared
-- take_resp.json raced: a sync GET (pairing poll, a refresh) landing while an
-- async job's curl was still writing meant one overwrote the other and the job
-- read back the wrong body. Files persist until the next startup sweep, which
-- keeps the read-the-last-response-off-disk debugging trick working.
local REQ_SEQ = 0

-- Keep only the most recent request/response body on disk. The newest stays
-- readable for debugging (see LEARNINGS); everything older is retired once the
-- next call has safely read its own copy, so the 30s live-comment poll can't
-- pile up hundreds of temp files over a long session.
local LAST_REQ, LAST_RESP
local function retire_temps(req_file, resp_file)
  if req_file then safe_remove(LAST_REQ); LAST_REQ = req_file end
  if resp_file then safe_remove(LAST_RESP); LAST_RESP = resp_file end
end

local function http_get_json(path)
  local url = safe_url(state.base_url .. path)
  if not url then return 0, "" end
  REQ_SEQ = REQ_SEQ + 1
  local out_file = tmp_path("resp_" .. REQ_SEQ .. ".json")
  local cmd = curl_bin() .. " -s --connect-timeout 10 --max-time 18"
    .. " -H " .. q("Authorization: Bearer " .. state.token)
    .. " -o " .. q(out_file)
    .. " -w " .. q("%{http_code}")
    .. " " .. q(url)
  local http = http_run(cmd, 20000)
  local body = read_file(out_file) or ""
  retire_temps(nil, out_file)
  return http, body
end

local function http_post_json(path, tbl)
  local url = safe_url(state.base_url .. path)
  if not url then return 0, "" end
  REQ_SEQ = REQ_SEQ + 1
  local body_file = tmp_path("req_" .. REQ_SEQ .. ".json")
  local bf = io.open(body_file, "wb")
  if not bf then return 0, "" end
  bf:write(json_encode(tbl))
  bf:close()

  local out_file = tmp_path("resp_" .. REQ_SEQ .. ".json")
  local cmd = curl_bin() .. " -s --connect-timeout 10 --max-time 55 -X POST"
    .. " -H " .. q("Authorization: Bearer " .. state.token)
    .. " -H " .. q("Content-Type: application/json")
    .. " --data-binary " .. q("@" .. body_file)
    .. " -o " .. q(out_file)
    .. " -w " .. q("%{http_code}")
    .. " " .. q(url)
  local http = http_run(cmd, 60000)
  local body = read_file(out_file) or ""
  retire_temps(body_file, out_file)
  return http, body
end

-- Download a (pre-signed) URL to dest. Returns http_status. total (optional,
-- bytes) improves the progress line from "12.4 MB" to a percentage.
local function http_download(url, dest, total)
  url = safe_url(url)
  if not url then return 0 end
  state.transfer = { kind = "down", path = dest, total = tonumber(total) }
  local cmd = curl_bin() .. " -s --connect-timeout 10 --max-time 110 -L -o " .. q(dest)
    .. " -w " .. q("%{http_code}") .. " " .. q(url)
  local http = http_run(cmd, 120000)
  state.transfer = nil
  return http
end

-- PUT a file to a (pre-signed) upload URL, streamed. Returns http_status.
-- The response body is diverted to a file (-o) so stdout is only the http_code;
-- otherwise status_from would parse a digit out of the JSON body. Instead of
-- -s we use -# (progress bar) with stderr routed to a file, which is what the
-- panel reads back to show a live percentage — uploads always run inside a
-- job, so the sync path (where stderr is discarded) never carries -#.
local function http_upload(url, filepath, content_type)
  url = safe_url(url)
  if not url then return 0 end
  REQ_SEQ = REQ_SEQ + 1
  local out_file = tmp_path("upload_resp_" .. REQ_SEQ .. ".txt")
  local prog_file = tmp_path("prog_" .. REQ_SEQ .. ".txt")
  state.transfer = { kind = "up", prog = prog_file, total = file_size(filepath) }
  local cmd = curl_bin() .. " -# --connect-timeout 10 --max-time 290 -X PUT -T " .. q(filepath)
    .. " -H " .. q("Content-Type: " .. content_type)
    .. " -o " .. q(out_file)
    .. " -w " .. q("%{http_code}")
    .. " " .. q(url)
  local http = http_run(cmd, 300000, prog_file)
  state.transfer = nil
  safe_remove(prog_file)
  return http
end

-- --------------------------------------------------------------------------
-- Render (push side). Uses the project's current render format; we only set
-- bounds + what-to-render, into a fresh temp dir, then read back whatever file
-- landed (so per-stem filename wildcards don't matter). Restores prior config.
-- --------------------------------------------------------------------------
local function find_rendered(dir)
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    local ext = fn:match("%.([^.]+)$")
    if ext and ACCEPTED[ext:lower()] then
      return dir .. "/" .. fn, ext:lower()
    end
    i = i + 1
  end
  return nil
end

-- render_settings is a RENDER_SETTINGS bitmask; both push paths use 0 (master
-- mix) — stem push solos the target track first so the mix is just that track.
local function render_to_temp(render_settings, pattern)
  local dir = tmp_path("render_" .. os.time() .. "_" .. math.random(1000, 9999))
  reaper.RecursiveCreateDirectory(dir, 0)

  local s_bounds = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
  local s_settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  local s_srate = reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
  local s_chans = reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)
  local _, s_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
  local _, s_pat = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)

  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true) -- entire project
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", render_settings, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, true) -- project sample rate
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", pattern, true)

  -- Render using the most recent settings, auto-closing the render dialog.
  reaper.Main_OnCommand(42230, 0)

  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", s_bounds, true)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", s_settings, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", s_srate, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", s_chans, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", s_file, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", s_pat, true)

  -- 42230 renders synchronously, so when it returns the output already exists.
  -- If an accepted file is there, use it. If files exist but none are accepted
  -- (render format is OGG/Opus/video), bail immediately — don't spin a core for
  -- 30s waiting for a file that will never appear. Only when the dir is still
  -- empty do we briefly poll, to tolerate a slow file-handle flush on big sessions.
  local file, ext = find_rendered(dir)
  if file then return file, ext end
  if reaper.EnumerateFiles(dir, 0) ~= nil then return nil end -- rendered, unaccepted format
  local deadline = reaper.time_precise() + 3.0
  repeat
    file, ext = find_rendered(dir)
    if file then return file, ext end
  until reaper.time_precise() > deadline
  return nil
end

local function cleanup_render(path)
  if not path then return end
  -- The render lives alone in its own take_render_* dir; remove the whole dir
  -- (rendered file + .reapeaks sidecar + any secondary-format outputs), not just
  -- the one file, so nothing leaks in Scripts/. Fall back to the file alone if
  -- the path isn't a render-dir child (defensive — never rmdir anything else).
  local dir = path:match("^(.*)[/\\][^/\\]+$")
  if dir and dir:find("take_render_", 1, true) then
    remove_dir(dir)
  else
    safe_remove(path)
  end
end

-- --------------------------------------------------------------------------
-- Actions
-- --------------------------------------------------------------------------
local function load_projects()
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  state.status = "Loading projects…"
  local http, body = http_get_json("/api/reaper/projects")
  if http == -1 then
    state.status = "No response — curl couldn't run from REAPER. Restart REAPER; if it persists, update Take in ReaPack."
    return
  end
  if http == 0 then
    state.status = "Couldn't reach the server. Check the Server URL in Settings and your internet connection."
    return
  end
  if http == 401 then
    if body:find("Authentication Required", 1, true) then
      state.status = "That server is Vercel-protected. Use " .. DEFAULT_BASE_URL .. "."
    else
      state.status = "Token rejected. Check it in Settings."
    end
    return
  end
  if http == 404 and body:find("DEPLOYMENT_NOT_FOUND", 1, true) then
    state.status = "Old server URL is dead. Use " .. DEFAULT_BASE_URL .. "."
    return
  end
  if http ~= 200 then state.status = "Couldn't load projects (" .. http .. ")."; return end
  local data = json_decode(body)
  state.projects = (data and data.projects) or {}
  state.view = "projects"
  state.status = #state.projects == 0
    and "No paid projects. Reaper needs a project whose owner is on a paid plan."
    or (#state.projects .. " project(s).")
end

-- Once per launch (from loop, when the job slot is idle): pull the ReaPack
-- index this panel installs from and nudge if a newer version is listed.
-- Newest version sits first in the index, so the first match is enough.
local function check_for_update()
  if not VERSION then return end
  local dest = tmp_path("resp_update.xml")
  local http = http_download(state.base_url .. "/reaper/index.xml", dest)
  if http ~= 200 then return end
  local newest = (read_file(dest) or ""):match('<version name="([%d%.]+)"')
  if newest and version_newer(newest, VERSION) then
    state.update_available = newest
  end
end

local function fmt_ts(ms)
  if not ms then return "" end
  local total = math.floor(ms / 1000)
  return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function comment_key(c)
  return tostring((c and c.id) or (c and c.created_at) or "comment")
end

-- Cut/loop proposals arrive as comments with proposal_* fields attached
-- (comments GET, since server migration 0028). Range in ms, or nil when the
-- comment isn't a proposal.
local function proposal_range(c)
  local s = tonumber(c and c.proposal_start_ms)
  local e = tonumber(c and c.proposal_end_ms)
  if not s or not e or e <= s then return nil end
  return s, e
end

local function comment_lane(c)
  local kind = c and c.proposal_kind
  if kind == "cut" then return "CUT" end
  if kind == "loop" then return "LOOP" end
  local pinned = c and c.pinned_to or "project"
  if pinned == "rough_ts" then return "ROUGH" end
  if pinned == "stem_ts" then return "STEM" end
  if pinned == "stem" then return "STEM" end
  return "PROJECT"
end

local function comment_text(c)
  if c and c.is_voice then return "[voice memo]" end
  return jval(c and c.body) or ""
end

local function short_text(s, max_len)
  s = tostring(s or ""):gsub("%s+", " ")
  max_len = max_len or 54
  if #s <= max_len then return s end
  return s:sub(1, max_len - 3) .. "..."
end

-- "Cut 0:12-0:31" / "Loop 0:12-0:31 x4", or nil for a plain comment.
local function proposal_label(c)
  local s, e = proposal_range(c)
  if not s then return nil end
  local label = (c.proposal_kind == "loop" and "Loop " or "Cut ") .. fmt_ts(s) .. "-" .. fmt_ts(e)
  local n = tonumber(c.proposal_loop_count)
  if c.proposal_kind == "loop" and n then label = label .. " x" .. n end
  return label
end

local function comment_marker_name(c)
  local who = (c and c.author_name) or "Take"
  local pl = proposal_label(c)
  local ts = jval(c and c.timestamp_ms)
  local at = pl and (" " .. pl) or (ts and (" @" .. fmt_ts(ts)) or "")
  local text = comment_text(c)
  if text == "" then text = pl and "proposal" or "comment" end
  return "Take: " .. who .. at .. " - " .. short_text(text, 80)
end

-- silent: the 30s auto-refresh passes true so a transient failure doesn't
-- overwrite the status line, and arriving comments get a short notice.
local function load_comments(silent)
  if not state.project then return end
  local http, body = http_get_json("/api/reaper/projects/" .. state.project.id .. "/comments")
  -- A transient 5xx or a revoked token (401) shouldn't blank the panel — keep
  -- whatever's already shown and say so, rather than silently wiping the list.
  if http ~= 200 then
    if not silent then
      state.status = "Couldn't refresh comments (" .. http .. "). Showing the last load."
    end
    return
  end
  local data = json_decode(body)
  local fresh = (data and data.comments) or {}
  if silent and #state.comments > 0 and #fresh > #state.comments then
    state.status = (#fresh - #state.comments) .. " new comment(s)."
  end
  state.comments = fresh
end

-- Which stems already live in this session? Imported files are prefixed with
-- the stem id, so match media source filenames against the ids. Cheap (native
-- API calls only); rescanned on a 2s throttle from the stems draw.
local function refresh_stem_presence()
  local present = {}
  local n = reaper.CountMediaItems(0)
  for i = 0, n - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item)
    local src = take and reaper.GetMediaItemTake_Source(take)
    local fn = src and reaper.GetMediaSourceFileName(src, "")
    if fn and fn ~= "" then
      for _, s in ipairs(state.stems) do
        if s.id and fn:find(tostring(s.id), 1, true) then present[s.id] = true end
      end
    end
  end
  state.stem_presence = present
end

local function open_project(p)
  state.status = "Loading " .. tostring(p.name or "project") .. "…"
  state.comments = {}
  state.scroll_comments = false
  state.comments_next_poll = 0 -- restart the live-refresh clock for this project
  local http, body = http_get_json("/api/reaper/projects/" .. p.id)
  if http ~= 200 then state.status = "Couldn't open project (" .. http .. ")."; return end
  local data = json_decode(body)
  state.project = data and data.project or p
  state.stems = (data and data.stems) or {}
  state.view = "project"
  refresh_stem_presence()
  load_comments()
  state.status = #state.stems .. " stem(s), " .. #state.comments .. " comment(s)."
end

local function post_comment()
  if not state.project then state.status = "Open a project first."; return end
  if state.comment_body == "" or state.comment_body:match("^%s*$") then
    state.status = "Type a comment first."; return
  end
  -- Capture the text now: this runs inside a job, and by the time the POST
  -- returns the user may have typed a new draft — only clear it if unchanged.
  local body_text = state.comment_body
  local payload = { body = body_text }
  -- At the edit cursor -> a timestamp on the current rough (server resolves it).
  if state.comment_at_cursor then
    payload.timestampMs = math.floor((reaper.GetCursorPosition() or 0) * 1000)
  end
  state.status = "Posting comment…"
  local http, resp_body = http_post_json("/api/reaper/projects/" .. state.project.id .. "/comments", payload)
  if http == 401 then state.status = "Token rejected. Check it in Settings."; return end
  if http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if http ~= 200 then state.status = "Couldn't post comment (" .. http .. ")."; return end
  -- The server now returns the full created comment in the "comment" field
  -- so the panel can show it immediately without waiting for the GET refresh.
  local resp = json_decode(resp_body)
  local created = resp and resp.comment
  local degraded = created and created.degraded_to_project_note
  if created and type(created) == "table" and created.id then
    state.comments[#state.comments + 1] = created
  end
  if state.comment_body == body_text then state.comment_body = "" end
  load_comments()
  -- If the GET came back empty but we just inserted a comment, keep it visible.
  if #state.comments == 0 and created and type(created) == "table" and created.id then
    state.comments[#state.comments + 1] = created
  end
  state.scroll_comments = true
  if degraded then
    state.status = "Posted as a project note (no current rough to pin to)."
  else
    state.status = "Comment posted."
  end
end

-- Post a cut/loop proposal built from REAPER's time selection. The server
-- pins it to the current rough (comment + edit_proposal, atomic) and clamps
-- loop counts to 2..8. Runs inside a job like every network button.
local function propose_edit(kind, sel_start, sel_end)
  if not state.project then state.status = "Open a project first."; return end
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  local start_ms = math.floor((sel_start or 0) * 1000)
  local end_ms = math.floor((sel_end or 0) * 1000)
  if end_ms <= start_ms then
    state.status = "Make a time selection first."
    return
  end
  local note = state.propose_note
  local payload = { kind = kind, startMs = start_ms, endMs = end_ms }
  if kind == "loop" then payload.loopCount = state.loop_count or 2 end
  if note ~= "" and not note:match("^%s*$") then payload.body = note end

  state.status = "Proposing " .. kind .. "…"
  start_job(function()
    local http, resp_body = http_post_json(
      "/api/reaper/projects/" .. state.project.id .. "/proposals", payload)
    if http == 401 then state.status = "Token rejected. Check it in Settings."; return end
    if http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
    if http == 409 then
      state.status = "No current rough — push a rough first; proposals attach to it."
      return
    end
    if http ~= 200 then state.status = "Couldn't save the proposal (" .. http .. ")."; return end
    local resp = json_decode(resp_body)
    local created = resp and resp.comment
    if created and type(created) == "table" and created.id then
      state.comments[#state.comments + 1] = created
      state.scroll_comments = true
    end
    if state.propose_note == note then state.propose_note = "" end
    load_comments()
    state.status = "Proposed " .. kind .. " " .. fmt_ts(start_ms) .. "-" .. fmt_ts(end_ms) .. "."
  end)
end

local function jump_to_comment(c)
  local ms = c and tonumber(c.timestamp_ms)
  if not ms then
    state.status = "That comment is a project note, not a timeline pin."
    return
  end
  reaper.SetEditCurPos(ms / 1000, true, false)
  state.status = "Cursor at " .. fmt_ts(ms) .. "."
end

-- Set REAPER's time selection (and cursor) to a proposal's range, so the user
-- can audition it — with Repeat on, playing a loop proposal loops it.
local function select_proposal(c)
  local s, e = proposal_range(c)
  if not s then
    state.status = "That comment has no cut/loop range."
    return
  end
  reaper.GetSet_LoopTimeRange(true, false, s / 1000, e / 1000, false)
  reaper.SetEditCurPos(s / 1000, true, false)
  state.status = "Selected " .. fmt_ts(s) .. "-" .. fmt_ts(e) .. "."
end

-- Point marker for a timeline comment; a spanning REGION for a cut/loop
-- proposal. Both carry the "Take: " prefix so Clear can find them.
local function add_comment_marker(c)
  local color = 0
  if reaper.ColorToNative then color = reaper.ColorToNative(237, 111, 92) + 0x1000000 end
  local s, e = proposal_range(c)
  if s and e then
    reaper.AddProjectMarker2(0, true, s / 1000, e / 1000, comment_marker_name(c), -1, color)
    reaper.UpdateArrange()
    state.status = "Added region " .. fmt_ts(s) .. "-" .. fmt_ts(e) .. "."
    return true
  end
  local ms = c and tonumber(c.timestamp_ms)
  if not ms then
    state.status = "Only timeline comments can become markers."
    return false
  end
  reaper.AddProjectMarker2(0, false, ms / 1000, 0, comment_marker_name(c), -1, color)
  reaper.UpdateArrange()
  state.status = "Added marker at " .. fmt_ts(ms) .. "."
  return true
end

local function clear_take_markers()
  local _, marker_count, region_count = reaper.CountProjectMarkers(0)
  local total = (marker_count or 0) + (region_count or 0)
  local removed = 0
  for i = total - 1, 0, -1 do
    local _, is_region, _, _, name, index = reaper.EnumProjectMarkers3(0, i)
    -- Proposals sync as regions, plain comments as markers — clear both.
    if name and name:sub(1, 6) == "Take: " then
      reaper.DeleteProjectMarker(0, index, is_region and true or false)
      removed = removed + 1
    end
  end
  reaper.UpdateArrange()
  return removed
end

local function sync_comment_markers()
  clear_take_markers()
  local added = 0
  for _, c in ipairs(state.comments) do
    if jval(c.timestamp_ms) then
      if add_comment_marker(c) then added = added + 1 end
    end
  end
  state.status = added == 0
    and "No timeline comments to mark."
    or ("Dropped " .. added .. " Take marker(s).")
end

-- Voice memos (spec §2.5, paid §2.11). request signed URL -> PUT the WAV ->
-- finalize as a voice comment. ext/content-type come from the recorded file +
-- the request response; the voice-memos bucket accepts wav.
local function post_voice_memo(file, ext, timestamp_ms)
  local pid = state.project.id
  local req_http, req_body = http_post_json(
    "/api/reaper/projects/" .. pid .. "/voice/request", { ext = ext })
  if req_http == 401 then state.status = "Token rejected. Check it in Settings."; return false end
  if req_http == 403 then state.status = "This project's owner isn't on a paid plan."; return false end
  if req_http == 400 then state.status = "Recording format not accepted (" .. ext .. ")."; return false end
  if req_http ~= 200 then state.status = "Voice request failed (" .. req_http .. ")."; return false end
  local req = json_decode(req_body)
  if not req or not req.signedUrl then state.status = "No upload URL returned."; return false end

  local up = http_upload(req.signedUrl, file, req.contentType or MIME[ext] or "audio/wav")
  if up ~= 200 then state.status = "Upload failed (" .. up .. "). Voice memo kept at: " .. file; return false end

  local payload = { path = req.path }
  if timestamp_ms then payload.timestampMs = timestamp_ms end
  local fin_http = select(1, http_post_json(
    "/api/reaper/projects/" .. pid .. "/voice/finalize", payload))
  if fin_http == 403 then state.status = "This project's owner isn't on a paid plan."; return false end
  if fin_http ~= 200 then state.status = "Finalize failed (" .. fin_http .. "). Voice memo kept at: " .. file; return false end

  load_comments()
  state.status = "Voice memo posted."
  return true
end

local function open_voice_memo(c)
  if not state.project then state.status = "Open a project first."; return end
  if not c or not c.is_voice then state.status = "That comment has no voice memo."; return end
  if not c.id then state.status = "Voice memo is missing a comment id."; return end

  state.status = "Opening voice memo..."
  start_job(function()
    local http, body = http_get_json("/api/reaper/projects/" .. state.project.id .. "/voice/" .. c.id)
    if http == 401 then state.status = "Token rejected. Check it in Settings."; return end
    if http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
    if http ~= 200 then state.status = "Couldn't open voice memo (" .. http .. ")."; return end
    local data = json_decode(body)
    if not data or not data.url then state.status = "No voice memo URL returned."; return end

    local filename = safe_filename(data.filename or ("voice_" .. comment_key(c) .. ".wav"))
    local dest = tmp_path("voice_" .. filename)
    local dl = http_download(data.url, dest)
    if dl ~= 200 then state.status = "Voice memo download failed (" .. dl .. ")."; return end
    open_file(dest)
    state.status = "Opened voice memo."
  end)
end

-- Record from the default audio input onto a throwaway track placed past the end
-- of the project (so nothing on the timeline is touched), then upload the take's
-- source file. Two-step: Record arms + rolls; Stop & post stops, uploads, and
-- tears the temp track down. Record-arm on existing tracks is saved/cleared so
-- only the temp track captures, and restored on stop — the session is left as it
-- was. The edit cursor at record-time becomes the comment timestamp.
local function start_voice_record()
  if not state.project then state.status = "Open a project first."; return end
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  if state.recording then return end
  -- Command 1013 TOGGLES transport record: fired while the user is already
  -- playing or recording it would stop/mangle their real session take. And the
  -- stop-side upload needs the single job slot, so don't start a memo that
  -- couldn't be posted.
  if state.job then state.status = "Busy — finish the current operation first."; return end
  if (reaper.GetPlayState() or 0) ~= 0 then
    state.status = "Stop the transport first, then record the memo."
    return
  end

  local v = {}
  v.cursor = reaper.GetCursorPosition() or 0
  v.timestamp_ms = state.comment_at_cursor and math.floor(v.cursor * 1000) or nil

  v.count = reaper.CountTracks(0)
  v.saved_arm = {}
  for i = 0, v.count - 1 do
    local t = reaper.GetTrack(0, i)
    v.saved_arm[i] = reaper.GetMediaTrackInfo_Value(t, "I_RECARM")
    reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 0)
  end

  -- Record from the input chosen in Settings (falls back to input 1 when the
  -- saved index no longer exists, e.g. after switching audio devices).
  local input = state.voice_input or 0
  if input < 0 or input >= (reaper.GetNumAudioInputs() or 0) then input = 0 end

  reaper.InsertTrackAtIndex(v.count, false)
  v.track = reaper.GetTrack(0, v.count)
  reaper.GetSetMediaTrackInfo_String(v.track, "P_NAME", "Take voice memo (temp)", true)
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECINPUT", input) -- mono hardware input
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECMON", 0)   -- no input monitoring (no feedback)
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECMODE", 0)  -- record input

  reaper.SetEditCurPos((reaper.GetProjectLength(0) or 0) + 1.0, false, false)
  reaper.Main_OnCommand(1013, 0) -- Transport: Record

  state.voice = v
  state.recording = true
  local input_name = reaper.GetInputChannelName(input)
  input_name = (input_name and input_name ~= "") and input_name or ("input " .. (input + 1))
  state.status = "Recording (" .. input_name .. ")… speak, then Stop and post."
end

-- Stop the transport, recover the recorded source file, tear down the temp
-- track, and restore every track's rec-arm + the edit cursor. Shared by the
-- normal stop-and-post path and the atexit safety net, so closing the window or
-- a script error mid-record never leaves the transport rolling or rec-arms
-- zeroed. Returns the recorded file path and the comment timestamp (or nil).
local function teardown_recording()
  local v = state.voice
  reaper.Main_OnCommand(1016, 0) -- Transport: Stop (finalizes the recorded file)
  state.recording = false

  local file
  if v and v.track and reaper.GetTrackNumMediaItems(v.track) > 0 then
    local item = reaper.GetTrackMediaItem(v.track, 0)
    local take = item and reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then file = reaper.GetMediaSourceFileName(src, "") end
    end
  end

  if v and v.track then reaper.DeleteTrack(v.track) end
  if v then
    for i = 0, (v.count or 1) - 1 do
      local t = reaper.GetTrack(0, i)
      if t then reaper.SetMediaTrackInfo_Value(t, "I_RECARM", v.saved_arm[i] or 0) end
    end
    reaper.SetEditCurPos(v.cursor or 0, false, false)
  end
  reaper.UpdateArrange()
  state.voice = nil
  return file, v and v.timestamp_ms
end

local function stop_and_post_voice()
  if not state.recording or not state.voice then return end
  -- Tear down + restore BEFORE the upload so the session is clean either way.
  local file, timestamp_ms = teardown_recording()

  if not file or file == "" then
    state.status = "No recording found. Check your audio input device."
    return
  end
  if file_size(file) < 1000 then
    safe_remove(file)
    state.status = "Nothing recorded (silent). Check your mic input."
    return
  end

  local ext = (file:match("%.([^.]+)$") or "wav"):lower()
  state.status = "Uploading voice memo…"
  start_job(function()
    if post_voice_memo(file, ext, timestamp_ms) then
      safe_remove(file)
    end
  end)
end

-- Download one stem and drop it on a new track at its timecode. Runs inside a
-- job coroutine (callers wrap it). Failure statuses are set here; returns true
-- on success so callers can set their own summary line.
local function import_stem_now(stem)
  local http, body = http_get_json("/api/reaper/stems/" .. stem.id .. "/original")
  if http == 403 then state.status = "This project's owner isn't on a paid plan."; return false end
  if http ~= 200 then state.status = "Couldn't pull stem (" .. http .. ")."; return false end
  local data = json_decode(body)
  if not data or not data.url then state.status = "No download URL returned."; return false end

  -- Prefix with the stem id so imports never collide by filename across
  -- projects, and re-importing never reuses a path the project still holds open
  -- (the Windows failure case). #15.
  local safe_name = safe_filename(data.filename or (tostring(stem.name or "stem") .. ".wav"))
  local dest = tmp_path(safe_filename(tostring(stem.id)) .. "_" .. safe_name)
  local dl = http_download(data.url, dest, data.size_bytes or data.sizeBytes)
  if dl ~= 200 then state.status = "Download failed (" .. dl .. ")."; return false end

  -- The download yielded across frames; the track ops below run synchronously
  -- in this resume, on the main thread, so REAPER calls are safe here.
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", tostring(stem.name or "Stem"), true)
  reaper.SetOnlyTrackSelected(track)

  -- Save + restore the edit cursor around the insert so a pull doesn't move the
  -- user's playhead (the voice-record path restores it too). #28.
  local saved_cursor = reaper.GetCursorPosition()
  local offset_ms = jval(data.timecode_offset_ms) or jval(stem.timecode_offset_ms) or 0
  reaper.SetEditCurPos((offset_ms or 0) / 1000, false, false)
  reaper.InsertMedia(dest, 0) -- 0 = add to currently selected track at edit cursor
  reaper.SetEditCurPos(saved_cursor, false, false)
  reaper.UpdateArrange()
  state.stem_presence[stem.id] = true
  return true
end

local function import_stem(stem)
  state.status = "Pulling " .. tostring(stem.name or "stem") .. "…"
  start_job(function()
    if import_stem_now(stem) then
      state.status = "Imported " .. tostring(stem.name or "stem") .. "."
    end
  end)
end

-- Pull every stem that isn't already in the session, one after another in a
-- single job (the job slot is serial by design).
local function import_all_stems()
  refresh_stem_presence()
  local todo = {}
  for _, s in ipairs(state.stems) do
    if s.id and not state.stem_presence[s.id] then todo[#todo + 1] = s end
  end
  if #todo == 0 then state.status = "All stems are already in this session."; return end
  start_job(function()
    local done = 0
    for n, s in ipairs(todo) do
      state.status = "Pulling " .. tostring(s.name or "stem") .. " (" .. n .. "/" .. #todo .. ")…"
      if not import_stem_now(s) then break end -- its status already says what failed
      done = done + 1
    end
    if done == #todo then state.status = "Imported " .. done .. " stem(s)." end
  end)
end

-- Network half of a push: request signed URL -> upload -> finalize. Runs inside
-- a job coroutine (each http_* call yields while curl runs detached), so the
-- render must already be done and `file` is the rendered path. on_done() runs
-- after a successful push. The render half lives in the callers because it
-- touches REAPER state (solo) that must be restored before we yield.
local function upload_and_finalize(kind, file, ext, name, extra, on_done)
  local function fail(message)
    cleanup_render(file)
    state.status = message
    return false
  end

  state.status = "Uploading " .. name .. "…"
  local req_http, req_body = http_post_json("/api/reaper/push/" .. kind .. "/request", {
    projectId = state.project.id,
    ext = ext,
    sizeBytes = file_size(file),
    mimeType = MIME[ext],
  })
  if req_http == 401 then return fail("Token rejected. Check it in Settings.") end
  if req_http == 403 then return fail("This project's owner isn't on a paid plan.") end
  if req_http ~= 200 then return fail("Push request failed (" .. req_http .. ").") end
  local req = json_decode(req_body)
  if not req or not req.signedUrl then return fail("No upload URL returned.") end

  local up = http_upload(req.signedUrl, file, MIME[ext])
  if up ~= 200 then return fail("Upload failed (" .. up .. ").") end

  local body = { projectId = state.project.id, path = req.path }
  body[kind == "stem" and "stemId" or "roughId"] = (kind == "stem") and req.stemId or req.roughId
  for k, v in pairs(extra or {}) do body[k] = v end

  local fin_http = select(1, http_post_json("/api/reaper/push/" .. kind .. "/finalize", body))
  if fin_http == 403 then return fail("This project's owner isn't on a paid plan.") end
  if fin_http ~= 200 then return fail("Finalize failed (" .. fin_http .. ").") end

  cleanup_render(file)
  if on_done then on_done() end
  return true
end

local function push_stem()
  if state.job then state.status = "Busy — finish the current operation first."; return end
  if not state.project then state.status = "Open a project first."; return end
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then state.status = "Select a track to push first."; return end
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if track_name == "" then track_name = "Stem" end
  local name = state.push_name ~= "" and state.push_name or track_name

  -- Render just this track by soloing it and rendering the master mix (the
  -- reliable one-file path). REAPER's "stems" render mode is media/selection
  -- dependent and can produce nothing. Save every track's solo state, solo only
  -- this one for the render, then restore — so the session is left untouched.
  -- Render + solo restore run synchronously up front (REAPER state must be put
  -- back before the job yields); only the upload is async.
  local count = reaper.CountTracks(0)
  local saved_solo = {}
  for i = 0, count - 1 do
    local t = reaper.GetTrack(0, i)
    saved_solo[i] = reaper.GetMediaTrackInfo_Value(t, "I_SOLO")
    reaper.SetMediaTrackInfo_Value(t, "I_SOLO", (t == track) and 1 or 0)
  end

  state.status = "Rendering…"
  local file, ext
  local ok, err = pcall(function()
    file, ext = render_to_temp(0, "take_stem")
  end)

  for i = 0, count - 1 do
    reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO", saved_solo[i] or 0)
  end
  reaper.UpdateArrange()

  if not ok then
    state.status = "Push failed: " .. tostring(err)
    return
  end
  if not file then
    state.status = "Render didn't produce an accepted file. Check your render format — WAV, AIFF, FLAC, or MP3."
    return
  end

  start_job(function()
    if upload_and_finalize("stem", file, ext, name, { name = name, timecodeOffsetMs = 0 }) then
      open_project(state.project) -- refresh the stem list
      state.status = "Pushed stem: " .. name .. "."
    end
  end)
end

local function push_rough()
  if state.job then state.status = "Busy — finish the current operation first."; return end
  if not state.project then state.status = "Open a project first."; return end
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  local label = state.push_name ~= "" and state.push_name or nil
  local stem_ids = {}
  for _, s in ipairs(state.stems) do stem_ids[#stem_ids + 1] = s.id end
  local extra = { activeStemIds = stem_ids, timecodeOffsetMs = 0 }
  if label then extra.label = label end

  state.status = "Rendering…"
  local file, ext = render_to_temp(0, "take_rough")
  if not file then
    state.status = "Render didn't produce an accepted file. Check your render format — WAV, AIFF, FLAC, or MP3."
    return
  end

  start_job(function()
    upload_and_finalize("rough", file, ext, label or "rough", extra, function()
      state.status = "Pushed a new rough." .. (label and (" (" .. label .. ")") or "")
    end)
  end)
end

-- --------------------------------------------------------------------------
-- UI
-- --------------------------------------------------------------------------
local COLORS = {
  paper = 0xEFE7D2FF,
  paper_warm = 0xECE4CFFF,
  bone = 0xF7F1DEFF,
  ink = 0x15140FFF,
  muted = 0x5A5448FF,
  faint = 0x8B8676FF,
  coral = 0xED6F5CFF,
  coral_soft = 0xF08E7CFF,
  line = 0x15140F29,
  danger = 0xB33A2EFF,
  success = 0x4F6F38FF,
}

local function push_theme()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 14, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 7)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 6)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.ink)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COLORS.paper)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COLORS.bone)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COLORS.line)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), COLORS.bone)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), COLORS.paper_warm)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0xDDD2B6FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.bone)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.paper_warm)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xDDD2B6FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), COLORS.bone)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), COLORS.paper_warm)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(), 0xDDD2B6FF)
end

local function pop_theme()
  reaper.ImGui_PopStyleColor(ctx, 13)
  reaper.ImGui_PopStyleVar(ctx, 6)
end

local function content_width()
  local w = reaper.ImGui_GetContentRegionAvail(ctx)
  return math.max(120, w or 120)
end

local function section_title(label, detail)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.ink, label)
  if detail and detail ~= "" then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, COLORS.faint, detail)
  end
  reaper.ImGui_Separator(ctx)
end

local function muted_text(text)
  reaper.ImGui_TextColored(ctx, COLORS.muted, text)
end

local function empty_state(text)
  local vis = reaper.ImGui_BeginChild(ctx, "empty_" .. text, 0, 48)
  if vis then
    muted_text(text)
  end
  end_child(vis)
end

local function primary_button(label, width)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.coral)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.coral_soft)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.coral)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.bone)
  local clicked = reaper.ImGui_Button(ctx, label, width or 0, 0)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return clicked
end

local function draw_comment_item(c)
  local key = comment_key(c)
  local lane = comment_lane(c)
  local who = (c and c.author_name) or "?"
  local ms = c and tonumber(c.timestamp_ms)
  local pl = proposal_label(c)
  local at = pl and (" " .. pl) or (ms and (" @" .. fmt_ts(ms)) or "")

  reaper.ImGui_TextColored(ctx, COLORS.coral, lane)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.ink, who .. at)
  local text = comment_text(c)
  if text ~= "" then reaper.ImGui_TextWrapped(ctx, text) end

  if pl then
    -- Cut/loop proposal: audition the range, or drop a spanning region.
    if reaper.ImGui_Button(ctx, "Select##sel_" .. key) then select_proposal(c) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Region##region_" .. key) then add_comment_marker(c) end
  elseif ms then
    if reaper.ImGui_Button(ctx, "Jump##jump_" .. key) then jump_to_comment(c) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Marker##marker_" .. key) then add_comment_marker(c) end
    if c.is_voice then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Voice##voice_" .. key) then open_voice_memo(c) end
    end
  elseif c.is_voice then
    if reaper.ImGui_Button(ctx, "Voice##voice_" .. key) then open_voice_memo(c) end
  else
    muted_text("Project note")
  end
  reaper.ImGui_Separator(ctx)
end

-- One line describing the in-flight transfer. Downloads report the growing
-- file size (plus a percentage when the total is known); uploads parse the
-- last percentage curl's progress bar wrote to its stderr file.
local function transfer_progress_text()
  local t = state.transfer
  if not t then return nil end
  if t.kind == "down" then
    local got = file_size(t.path)
    if t.total and t.total > 0 then
      return string.format("%d%% (%s of %s)",
        math.min(100, math.floor(got * 100 / t.total)), fmt_bytes(got), fmt_bytes(t.total))
    end
    return fmt_bytes(got) .. " received"
  end
  local f = io.open(t.prog, "rb")
  if f then
    local size = f:seek("end") or 0
    f:seek("set", math.max(0, size - 400))
    local tail = f:read("*a") or ""
    f:close()
    local pct
    for p in tail:gmatch("([%d%.]+)%%") do pct = p end
    if pct then return pct .. "% of " .. fmt_bytes(t.total) end
  end
  return fmt_bytes(t.total) .. " to send"
end

local function draw_status()
  if state.status == "" then return end
  local color = COLORS.muted
  local lowered = state.status:lower()
  -- Failure phrases only — a bare "no " would also flag friendly notes like
  -- "No paid projects" or "No timeline comments to mark" as errors.
  if lowered:find("failed") or lowered:find("couldn't") or lowered:find("rejected")
      or lowered:find("check") or lowered:find("timed out") or lowered:find("not accepted")
      or lowered:find("url returned") or lowered:find("isn't on a paid plan") then
    color = COLORS.danger
  elseif lowered:find("posted") or lowered:find("pushed") or lowered:find("imported")
      or lowered:find("connected") or lowered:find("proposed") then
    color = COLORS.success
  end

  reaper.ImGui_Spacing(ctx)
  local progress = transfer_progress_text()
  local vis = reaper.ImGui_BeginChild(ctx, "status", 0, progress and 58 or 44)
  if vis then
    reaper.ImGui_TextColored(ctx, color, state.status)
    if progress then reaper.ImGui_TextColored(ctx, COLORS.muted, progress) end
  end
  end_child(vis)
end

-- One-click Connect (the OAuth device grant). Ask the server for a pairing, open
-- the browser for the user to approve, then poll until it hands back a token. The
-- user never sees or pastes a key.
local function start_pairing()
  state.pairing = nil
  local http, body = http_post_json("/api/reaper/pair/start", {})
  if http == -1 then
    state.status = "No response — curl couldn't run from REAPER. Restart REAPER; if it persists, update Take in ReaPack."
    return
  end
  if http == 0 then
    state.status = "Couldn't reach the server. Check the Server URL in Settings and your internet connection."
    return
  end
  if http ~= 200 then
    state.status = "Couldn't start Connect (server said " .. tostring(http) .. ")."
    return
  end
  local ok, data = pcall(json_decode, body)
  if not ok or type(data) ~= "table" or not data.device_code
      or not safe_url(data.verify_url) then
    state.status = "Couldn't start Connect (unexpected response)."
    return
  end
  local interval = tonumber(data.interval) or 2
  state.pairing = {
    device_code = data.device_code,
    deadline = reaper.time_precise() + (tonumber(data.expires_in) or 600),
    interval = interval,
    next_poll = reaper.time_precise() + interval,
  }
  open_file(data.verify_url)
  state.status = "Waiting for you to approve Take in your browser…"
end

-- Called every frame while a pairing is in flight; throttled to the server's
-- interval. Saves the token and loads projects the moment approval lands.
local function poll_pairing()
  local p = state.pairing
  if not p then return end
  local now = reaper.time_precise()
  if now > p.deadline then
    state.pairing = nil
    state.status = "Connect timed out. Open Settings and try again."
    return
  end
  if now < p.next_poll then return end
  p.next_poll = now + (p.interval or 2) -- honor the server-provided interval (#26)

  local http, body = http_get_json("/api/reaper/pair/poll?device_code=" .. p.device_code)
  if http == 404 then
    -- The server doesn't know this pairing (expired and cleaned up, or a stale
    -- device code). Waiting longer can't fix it — fail now, not at the deadline.
    state.pairing = nil
    state.status = "Connect failed (not-found). Open Settings and try again."
    return
  end
  if http ~= 200 then return end -- transient; keep waiting until the deadline
  local ok, data = pcall(json_decode, body)
  if not ok or type(data) ~= "table" then return end

  if data.status == "approved" and data.token then
    state.pairing = nil
    state.token = trim(data.token)
    reaper.SetExtState(EXT, "token", state.token, true)
    state.show_settings = false
    state.status = "Connected."
    start_job(load_projects)
  elseif data.status == "expired" or data.status == "denied" or data.status == "not-found" then
    state.pairing = nil
    state.status = "Connect failed (" .. tostring(data.status) .. "). Open Settings and try again."
  end
  -- "pending": the user hasn't approved yet; keep waiting silently.
end

local function draw_settings()
  section_title("Connection", "Take account")
  local changed
  muted_text("Server URL")
  reaper.ImGui_TextWrapped(ctx, "Use " .. DEFAULT_BASE_URL .. " for the live Take app. This is not the ReaPack install URL.")
  reaper.ImGui_SetNextItemWidth(ctx, content_width())
  changed, state.base_url = reaper.ImGui_InputText(ctx, "##server_url", state.base_url)
  if changed then
    state.base_url = trim(state.base_url):gsub("/+$", "")
    reaper.SetExtState(EXT, "base_url", state.base_url, true)
  end
  if reaper.ImGui_Button(ctx, "Use live server") then
    state.base_url = DEFAULT_BASE_URL
    reaper.SetExtState(EXT, "base_url", state.base_url, true)
  end
  muted_text("Connect")
  if state.pairing then
    reaper.ImGui_TextWrapped(ctx, "Waiting for you to approve Take in your browser. Come back here once you have.")
    if reaper.ImGui_Button(ctx, "Cancel") then state.pairing = nil; state.status = "" end
  else
    reaper.ImGui_TextWrapped(ctx, "Click Connect, approve Take in the browser tab that opens, and you're in. No key to copy.")
    if primary_button("Connect", content_width()) then start_job(start_pairing) end
  end
  muted_text("API token (optional)")
  reaper.ImGui_TextWrapped(ctx, "Prefer to paste a key? Create one at " .. DEFAULT_BASE_URL .. "/settings/reaper and paste the full take_ token here. Connect above is easier.")
  reaper.ImGui_SetNextItemWidth(ctx, content_width())
  changed, state.token = reaper.ImGui_InputText(ctx, "##api_token", state.token,
    reaper.ImGui_InputTextFlags_Password())
  if changed then
    state.token = trim(state.token)
    reaper.SetExtState(EXT, "token", state.token, true)
  end

  section_title("Voice memos", "mic input")
  local n_inputs = reaper.GetNumAudioInputs() or 0
  if n_inputs == 0 then
    muted_text("No audio inputs available.")
  else
    local cur = state.voice_input or 0
    if cur < 0 or cur >= n_inputs then cur = 0 end
    local function input_label(i)
      local nm = reaper.GetInputChannelName(i)
      return (i + 1) .. ": " .. ((nm and nm ~= "") and nm or "Input " .. (i + 1))
    end
    reaper.ImGui_SetNextItemWidth(ctx, content_width())
    if reaper.ImGui_BeginCombo(ctx, "##voice_input", input_label(cur)) then
      for i = 0, n_inputs - 1 do
        if reaper.ImGui_Selectable(ctx, input_label(i) .. "##vi" .. i, i == cur) then
          state.voice_input = i
          reaper.SetExtState(EXT, "voice_input", tostring(i), true)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
  end

  if primary_button("Done", content_width()) then state.show_settings = false; start_job(load_projects) end
end

local function draw_projects()
  section_title("Projects", #state.projects > 0 and (#state.projects .. " available") or "")
  -- All network-touching buttons run through start_job so a slow server never
  -- freezes REAPER's UI (the 0.6.6 fix covered pushes/pulls; this covers the
  -- rest). start_job itself reports "Busy" if a transfer is already running.
  if primary_button("Refresh projects", content_width()) then start_job(load_projects) end
  if state.token == "" then
    empty_state("Add your token in Settings to load paid projects.")
    return
  end
  if #state.projects == 0 then
    empty_state("No projects loaded yet.")
    return
  end

  local vis = reaper.ImGui_BeginChild(ctx, "project_list", 0, 220)
  if vis then
    for i, p in ipairs(state.projects) do
      local label = tostring(i) .. ". " .. tostring(p.name or "Untitled") .. "##" .. tostring(p.id or i)
      if reaper.ImGui_Selectable(ctx, label) then start_job(function() open_project(p) end) end
    end
  end
  end_child(vis)
end

local function draw_project()
  if reaper.ImGui_Button(ctx, "< Projects") then state.view = "projects" end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.ink, state.project and state.project.name or "")
  if primary_button("Render and push rough", content_width()) then push_rough() end

  section_title("Stems", #state.stems > 0 and (#state.stems .. " in this project") or "")
  if #state.stems == 0 then
    empty_state("No stems in this project yet.")
  else
    if reaper.time_precise() > (state.presence_next or 0) then
      refresh_stem_presence()
      state.presence_next = reaper.time_precise() + 2
    end
    if reaper.ImGui_Button(ctx, "Import all") then import_all_stems() end
    local vis = reaper.ImGui_BeginChild(ctx, "stem_list", 0, 128)
    if vis then
      for si, s in ipairs(state.stems) do
        reaper.ImGui_TextWrapped(ctx, tostring(s.name or "Stem"))
        reaper.ImGui_SameLine(ctx)
        if s.id and state.stem_presence[s.id] then
          muted_text("(in session)")
          reaper.ImGui_SameLine(ctx)
        end
        if reaper.ImGui_Button(ctx, "Import##" .. tostring(s.id or si)) then import_stem(s) end
      end
    end
    end_child(vis)
  end

  section_title("Push stem", "selected track")
  local changed
  reaper.ImGui_SetNextItemWidth(ctx, content_width())
  changed, state.push_name = reaper.ImGui_InputText(ctx, "Name (optional)", state.push_name)
  if primary_button("Push selected track", content_width()) then push_stem() end

  section_title("Propose", "cut / loop from time selection")
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not sel_end or sel_end <= (sel_start or 0) then
    muted_text("Make a time selection in REAPER to propose a cut or loop.")
  else
    muted_text("Selection: " .. fmt_ts(math.floor(sel_start * 1000)) .. "-" .. fmt_ts(math.floor(sel_end * 1000)))
    reaper.ImGui_SetNextItemWidth(ctx, content_width())
    changed, state.propose_note = reaper.ImGui_InputText(ctx, "Note (optional)##propose", state.propose_note)
    if primary_button("Propose cut") then propose_edit("cut", sel_start, sel_end) end
    reaper.ImGui_SameLine(ctx)
    if primary_button("Propose loop") then propose_edit("loop", sel_start, sel_end) end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    changed, state.loop_count = reaper.ImGui_SliderInt(ctx, "##loop_count", state.loop_count, 2, 8, "x%d")
  end

  section_title("Comments", #state.comments > 0 and (#state.comments .. " in this project") or "")
  if reaper.ImGui_Button(ctx, "Refresh comments") then start_job(load_comments) end
  if #state.comments > 0 then
    if reaper.ImGui_Button(ctx, "Drop timeline markers") then sync_comment_markers() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Clear Take markers") then
      local removed = clear_take_markers()
      state.status = removed == 0 and "No Take markers to clear." or ("Cleared " .. removed .. " Take marker(s).")
    end
  end
  if #state.comments == 0 then
    empty_state("No comments yet.")
  else
    local vis = reaper.ImGui_BeginChild(ctx, "comment_list", 0, 220)
    if vis then
      for _, c in ipairs(state.comments) do
        draw_comment_item(c)
      end
      if state.scroll_comments then
        reaper.ImGui_SetScrollHereY(ctx, 1.0)
        state.scroll_comments = false
      end
    end
    end_child(vis)
  end
  reaper.ImGui_SetNextItemWidth(ctx, content_width())
  changed, state.comment_body = reaper.ImGui_InputText(ctx, "New comment", state.comment_body)
  local cursor_label = "At edit cursor @" .. fmt_ts(math.floor((reaper.GetCursorPosition() or 0) * 1000))
  changed, state.comment_at_cursor = reaper.ImGui_Checkbox(ctx, cursor_label, state.comment_at_cursor)
  if primary_button("Post comment") then start_job(post_comment) end
  reaper.ImGui_SameLine(ctx)
  if state.recording then
    if reaper.ImGui_Button(ctx, "Stop and post voice memo") then stop_and_post_voice() end
  else
    if reaper.ImGui_Button(ctx, "Record voice memo") then start_voice_record() end
  end
end

local function loop()
  push_theme()
  -- Pump the in-flight async network job one slice per frame. The body runs
  -- until its next http_run yields (curl running detached), so the UI keeps
  -- painting; a resume that errors or finishes clears the slot. (#7)
  if state.job then
    local ok, err = coroutine.resume(state.job)
    if not ok then
      state.status = "Operation failed: " .. tostring(err)
      state.job = nil
      state.transfer = nil -- a job that died mid-transfer must not leave the progress line stuck
    elseif coroutine.status(state.job) == "dead" then
      state.job = nil
      state.transfer = nil
    end
  end
  if state.pairing then poll_pairing() end

  -- Once per launch, when the job slot is free: is a newer Take on ReaPack?
  if not state.update_checked and not state.job then
    state.update_checked = true
    start_job(check_for_update)
  end

  -- Live comments: quietly re-pull the thread every 30s while a project is
  -- open, so collaborator feedback shows up without touching Refresh. Skipped
  -- whenever the job slot is busy or a recording/pairing is in flight.
  if state.view == "project" and state.project and not state.show_settings
      and not state.job and not state.recording and not state.pairing then
    local now = reaper.time_precise()
    if state.comments_next_poll == 0 then
      state.comments_next_poll = now + 30
    elseif now > state.comments_next_poll then
      state.comments_next_poll = now + 30
      start_job(function() load_comments(true) end)
    end
  end

  reaper.ImGui_SetNextWindowSize(ctx, 450, 700, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 360, 480, -1, -1)
  local visible, open = reaper.ImGui_Begin(ctx, "Take", true)
  if visible then
    reaper.ImGui_TextColored(ctx, COLORS.ink, "Take")
    reaper.ImGui_SameLine(ctx)
    muted_text(state.recording and "recording voice memo" or "Reaper collaboration panel")
    if reaper.ImGui_Button(ctx, state.show_settings and "Close settings" or "Settings") then
      state.show_settings = not state.show_settings
    end

    if state.update_available then
      reaper.ImGui_TextColored(ctx, COLORS.coral,
        "Take v" .. state.update_available .. " is out - ReaPack > Synchronize packages.")
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_SmallButton(ctx, "Dismiss") then state.update_available = nil end
    end

    if state.show_settings then
      draw_settings()
    elseif state.view == "project" then
      draw_project()
    else
      draw_projects()
    end

    draw_status()
    reaper.ImGui_End(ctx)
  end
  pop_theme()
  if open then reaper.defer(loop) end
end

-- Safety net: if the panel closes (window X, or a script error) mid-recording,
-- REAPER would be left rolling with the temp track still armed and every other
-- track's rec-arm zeroed. Restore the session on exit. No upload here — the
-- recorded file just stays on disk and the startup sweep clears it next run.
reaper.atexit(function()
  if state.recording then pcall(teardown_recording) end
end)

reaper.defer(loop)
