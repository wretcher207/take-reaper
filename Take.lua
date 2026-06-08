-- @description Take for Reaper
-- @version 0.6.0
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
          if cp < 0x80 then
            buf[#buf + 1] = string.char(cp)
          elseif cp < 0x800 then
            buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
          else
            buf[#buf + 1] = string.char(
              0xE0 + math.floor(cp / 0x1000),
              0x80 + (math.floor(cp / 0x40) % 0x40),
              0x80 + (cp % 0x40))
          end
          i = i + 4
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
    if s:sub(i, i + 3) == "null" then i = i + 4; return nil end
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
    while i <= n do
      skip_ws()
      arr[#arr + 1] = parse_value()
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
      obj[key] = parse_value()
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

local function open_file(path)
  local os_name = reaper.GetOS() or ""
  local cmd
  if os_name:find("Win") then
    cmd = "cmd /c start \"\" " .. q(path)
  elseif os_name:find("OSX") then
    cmd = "open " .. q(path)
  else
    cmd = "xdg-open " .. q(path)
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

-- Clean up stale temp files from previous sessions on startup. Any render/voice
-- temp from a prior run is dead weight — the only live temps are created
-- during the current session. Also catches curl resp/req JSON bodies.
local function cleanup_stale_temps()
  local base = reaper.GetResourcePath() .. "/Scripts/"
  local prefixes = { "take_render_", "take_voice_", "take_resp.json", "take_req.json", "take_upload_resp.txt" }
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
end
cleanup_stale_temps()

-- Pull the http status code out of ExecProcess's "<exitcode>\n<stdout>".
-- curl -w "%{http_code}" writes exactly three digits to stdout; anchor on that
-- so stray numbers in error text don't produce a false match.
local function status_from(out)
  out = out or ""
  local code = out:match("\n(%d%d%d)\n*$")
  return tonumber(code) or 0
end

local function http_get_json(path)
  local out_file = tmp_path("resp.json")
  local url = state.base_url .. path
  local cmd = curl_bin() .. " -s -H " .. q("Authorization: Bearer " .. state.token)
    .. " -o " .. q(out_file)
    .. " -w " .. q("%{http_code}")
    .. " " .. q(url)
  local http = status_from(reaper.ExecProcess(cmd, 20000))
  return http, read_file(out_file) or ""
end

local function http_post_json(path, tbl)
  local body_file = tmp_path("req.json")
  local bf = io.open(body_file, "wb")
  if not bf then return 0, "" end
  bf:write(json_encode(tbl))
  bf:close()

  local out_file = tmp_path("resp.json")
  local url = state.base_url .. path
  local cmd = curl_bin() .. " -s -X POST"
    .. " -H " .. q("Authorization: Bearer " .. state.token)
    .. " -H " .. q("Content-Type: application/json")
    .. " --data-binary " .. q("@" .. body_file)
    .. " -o " .. q(out_file)
    .. " -w " .. q("%{http_code}")
    .. " " .. q(url)
  local http = status_from(reaper.ExecProcess(cmd, 60000))
  return http, read_file(out_file) or ""
end

-- Download a (pre-signed) URL to dest. Returns http_status.
local function http_download(url, dest)
  local cmd = curl_bin() .. " -s -L -o " .. q(dest) .. " -w " .. q("%{http_code}") .. " " .. q(url)
  return status_from(reaper.ExecProcess(cmd, 120000))
end

-- PUT a file to a (pre-signed) upload URL, streamed. Returns http_status.
-- The response body is diverted to a file (-o) so stdout is only the http_code;
-- otherwise status_from would parse a digit out of the JSON body.
local function http_upload(url, filepath, content_type)
  local out_file = tmp_path("upload_resp.txt")
  local cmd = curl_bin() .. " -s -X PUT -T " .. q(filepath)
    .. " -H " .. q("Content-Type: " .. content_type)
    .. " -o " .. q(out_file)
    .. " -w " .. q("%{http_code}")
    .. " " .. q(url)
  return status_from(reaper.ExecProcess(cmd, 300000))
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

  -- 42230 renders synchronously, but large sessions with heavy plugins can
  -- take a moment for the file handle to settle. Poll for up to 30 seconds.
  local deadline = reaper.time_precise() + 30.0
  repeat
    local file, ext = find_rendered(dir)
    if file then return file, ext end
  until reaper.time_precise() > deadline
  return nil
end

local function cleanup_render(path)
  if not path then return end
  safe_remove(path)
end

-- --------------------------------------------------------------------------
-- Actions
-- --------------------------------------------------------------------------
local function load_projects()
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  state.status = "Loading projects…"
  local http, body = http_get_json("/api/reaper/projects")
  if http == 0 then
    state.status = "No response — curl couldn't run from REAPER. Restart REAPER; if it persists, update Take in ReaPack."
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

local function fmt_ts(ms)
  if not ms then return "" end
  local total = math.floor(ms / 1000)
  return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function comment_key(c)
  return tostring((c and c.id) or (c and c.created_at) or "comment")
end

local function comment_lane(c)
  local pinned = c and c.pinned_to or "project"
  if pinned == "rough_ts" then return "ROUGH" end
  if pinned == "stem_ts" then return "STEM" end
  if pinned == "stem" then return "STEM" end
  return "PROJECT"
end

local function comment_text(c)
  if c and c.is_voice then return "[voice memo]" end
  return (c and c.body) or ""
end

local function short_text(s, max_len)
  s = tostring(s or ""):gsub("%s+", " ")
  max_len = max_len or 54
  if #s <= max_len then return s end
  return s:sub(1, max_len - 3) .. "..."
end

local function comment_marker_name(c)
  local who = (c and c.author_name) or "Take"
  local at = (c and c.timestamp_ms) and (" @" .. fmt_ts(c.timestamp_ms)) or ""
  local text = comment_text(c)
  if text == "" then text = "comment" end
  return "Take: " .. who .. at .. " - " .. short_text(text, 80)
end

local function load_comments()
  if not state.project then return end
  local http, body = http_get_json("/api/reaper/projects/" .. state.project.id .. "/comments")
  if http ~= 200 then state.comments = {}; return end
  local data = json_decode(body)
  state.comments = (data and data.comments) or {}
end

local function open_project(p)
  state.status = "Loading " .. p.name .. "…"
  local http, body = http_get_json("/api/reaper/projects/" .. p.id)
  if http ~= 200 then state.status = "Couldn't open project (" .. http .. ")."; return end
  local data = json_decode(body)
  state.project = data and data.project or p
  state.stems = (data and data.stems) or {}
  state.view = "project"
  load_comments()
  state.status = #state.stems .. " stem(s), " .. #state.comments .. " comment(s)."
end

local function post_comment()
  if not state.project then state.status = "Open a project first."; return end
  if state.comment_body == "" or state.comment_body:match("^%s*$") then
    state.status = "Type a comment first."; return
  end
  local payload = { body = state.comment_body }
  -- At the edit cursor -> a timestamp on the current rough (server resolves it).
  if state.comment_at_cursor then
    payload.timestampMs = math.floor((reaper.GetCursorPosition() or 0) * 1000)
  end
  state.status = "Posting comment…"
  local http = select(1, http_post_json("/api/reaper/projects/" .. state.project.id .. "/comments", payload))
  if http == 401 then state.status = "Token rejected. Check it in Settings."; return end
  if http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if http ~= 200 then state.status = "Couldn't post comment (" .. http .. ")."; return end
  state.comment_body = ""
  load_comments()
  state.status = "Comment posted."
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

local function add_comment_marker(c)
  local ms = c and tonumber(c.timestamp_ms)
  if not ms then
    state.status = "Only timeline comments can become markers."
    return false
  end
  local color = 0
  if reaper.ColorToNative then color = reaper.ColorToNative(237, 111, 92) + 0x1000000 end
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
    if not is_region and name and name:sub(1, 6) == "Take: " then
      reaper.DeleteProjectMarker(0, index, false)
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
    if c.timestamp_ms then
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
  local http, body = http_get_json("/api/reaper/projects/" .. state.project.id .. "/voice/" .. c.id)
  if http == 401 then state.status = "Token rejected. Check it in Settings."; return end
  if http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if http ~= 200 then state.status = "Couldn't open voice memo (" .. http .. ")."; return end
  local data = json_decode(body)
  if not data or not data.url then state.status = "No voice memo URL returned."; return end

  local filename = tostring(data.filename or ("voice_" .. comment_key(c) .. ".wav")):gsub("[/\\]", "_")
  local dest = tmp_path("voice_" .. filename)
  local dl = http_download(data.url, dest)
  if dl ~= 200 then state.status = "Voice memo download failed (" .. dl .. ")."; return end
  open_file(dest)
  state.status = "Opened voice memo."
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

  reaper.InsertTrackAtIndex(v.count, false)
  v.track = reaper.GetTrack(0, v.count)
  reaper.GetSetMediaTrackInfo_String(v.track, "P_NAME", "Take voice memo (temp)", true)
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECINPUT", 0) -- mono hardware input 1
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECMON", 0)   -- no input monitoring (no feedback)
  reaper.SetMediaTrackInfo_Value(v.track, "I_RECMODE", 0)  -- record input

  reaper.SetEditCurPos((reaper.GetProjectLength(0) or 0) + 1.0, false, false)
  reaper.Main_OnCommand(1013, 0) -- Transport: Record

  state.voice = v
  state.recording = true
  state.status = "Recording… speak, then Stop & post."
end

local function stop_and_post_voice()
  if not state.recording or not state.voice then return end
  local v = state.voice

  reaper.Main_OnCommand(1016, 0) -- Transport: Stop (finalizes the recorded file)
  state.recording = false

  local file
  if v.track and reaper.GetTrackNumMediaItems(v.track) > 0 then
    local item = reaper.GetTrackMediaItem(v.track, 0)
    local take = item and reaper.GetActiveTake(item)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then file = reaper.GetMediaSourceFileName(src, "") end
    end
  end

  -- Tear down + restore BEFORE the upload so the session is clean either way.
  if v.track then reaper.DeleteTrack(v.track) end
  for i = 0, (v.count or 1) - 1 do
    local t = reaper.GetTrack(0, i)
    if t then reaper.SetMediaTrackInfo_Value(t, "I_RECARM", v.saved_arm[i] or 0) end
  end
  reaper.SetEditCurPos(v.cursor or 0, false, false)
  reaper.UpdateArrange()
  state.voice = nil

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
  if post_voice_memo(file, ext, v.timestamp_ms) then
    safe_remove(file)
  end
end

local function import_stem(stem)
  state.status = "Pulling " .. stem.name .. "…"
  local http, body = http_get_json("/api/reaper/stems/" .. stem.id .. "/original")
  if http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if http ~= 200 then state.status = "Couldn't pull stem (" .. http .. ")."; return end
  local data = json_decode(body)
  if not data or not data.url then state.status = "No download URL returned."; return end

  local dest = tmp_path((data.filename or (stem.name .. ".wav")):gsub("[/\\]", "_"))
  local dl = http_download(data.url, dest)
  if dl ~= 200 then state.status = "Download failed (" .. dl .. ")."; return end

  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", stem.name, true)
  reaper.SetOnlyTrackSelected(track)

  local offset_ms = data.timecode_offset_ms or stem.timecode_offset_ms or 0
  reaper.SetEditCurPos((offset_ms or 0) / 1000, false, false)
  reaper.InsertMedia(dest, 0) -- 0 = add to currently selected track at edit cursor
  reaper.UpdateArrange()
  state.status = "Imported " .. stem.name .. "."
end

-- Shared push: render -> request signed URL -> upload -> finalize.
-- kind: "stem" | "rough". on_done() runs after a successful push.
local function do_push(kind, render_settings, pattern, name, extra, on_done)
  if not state.project then state.status = "Open a project first."; return end
  if state.token == "" then state.status = "Add a token in Settings first."; return end

  local function fail_after_render(file, message)
    cleanup_render(file)
    state.status = message
    return false
  end

  state.status = "Rendering…"
  local file, ext = render_to_temp(render_settings, pattern)
  if not file then
    state.status = "Render didn't produce an accepted file. Check your render format — WAV, AIFF, FLAC, or MP3."
    return false
  end

  state.status = "Uploading " .. name .. "…"
  local req_http, req_body = http_post_json("/api/reaper/push/" .. kind .. "/request", {
    projectId = state.project.id,
    ext = ext,
    sizeBytes = file_size(file),
    mimeType = MIME[ext],
  })
  if req_http == 401 then return fail_after_render(file, "Token rejected. Check it in Settings.") end
  if req_http == 403 then return fail_after_render(file, "This project's owner isn't on a paid plan.") end
  if req_http ~= 200 then return fail_after_render(file, "Push request failed (" .. req_http .. ").") end
  local req = json_decode(req_body)
  if not req or not req.signedUrl then return fail_after_render(file, "No upload URL returned.") end

  local up = http_upload(req.signedUrl, file, MIME[ext])
  if up ~= 200 then return fail_after_render(file, "Upload failed (" .. up .. ").") end

  local body = { projectId = state.project.id, path = req.path }
  body[kind == "stem" and "stemId" or "roughId"] = (kind == "stem") and req.stemId or req.roughId
  for k, v in pairs(extra or {}) do body[k] = v end

  local fin_http = select(1, http_post_json("/api/reaper/push/" .. kind .. "/finalize", body))
  if fin_http == 403 then return fail_after_render(file, "This project's owner isn't on a paid plan.") end
  if fin_http ~= 200 then return fail_after_render(file, "Finalize failed (" .. fin_http .. ").") end

  cleanup_render(file)
  if on_done then on_done() end
  return true
end

local function push_stem()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then state.status = "Select a track to push first."; return end
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if track_name == "" then track_name = "Stem" end
  local name = state.push_name ~= "" and state.push_name or track_name

  -- Render just this track by soloing it and rendering the master mix (the
  -- reliable one-file path). REAPER's "stems" render mode is media/selection
  -- dependent and can produce nothing. Save every track's solo state, solo only
  -- this one for the render, then restore — so the session is left untouched.
  local count = reaper.CountTracks(0)
  local saved_solo = {}
  for i = 0, count - 1 do
    local t = reaper.GetTrack(0, i)
    saved_solo[i] = reaper.GetMediaTrackInfo_Value(t, "I_SOLO")
    reaper.SetMediaTrackInfo_Value(t, "I_SOLO", (t == track) and 1 or 0)
  end

  local pushed = false
  local ok, err = pcall(function()
    pushed = do_push("stem", 0, "take_stem", name, { name = name, timecodeOffsetMs = 0 })
  end)

  for i = 0, count - 1 do
    reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO", saved_solo[i] or 0)
  end
  reaper.UpdateArrange()

  if not ok then
    state.status = "Push failed: " .. tostring(err)
    return
  end
  if pushed then
    open_project(state.project) -- refresh the stem list
    state.status = "Pushed stem: " .. name .. "."
  end
end

local function push_rough()
  local label = state.push_name ~= "" and state.push_name or nil
  local stem_ids = {}
  for _, s in ipairs(state.stems) do stem_ids[#stem_ids + 1] = s.id end
  local extra = { activeStemIds = stem_ids, timecodeOffsetMs = 0 }
  if label then extra.label = label end

  do_push("rough", 0, "take_rough", label or "rough", extra, function()
    state.status = "Pushed a new rough." .. (label and (" (" .. label .. ")") or "")
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
  reaper.ImGui_BeginChild(ctx, "empty_" .. text, 0, 48)
  muted_text(text)
  reaper.ImGui_EndChild(ctx)
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
  local at = ms and (" @" .. fmt_ts(ms)) or ""

  reaper.ImGui_TextColored(ctx, COLORS.coral, lane)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.ink, who .. at)
  reaper.ImGui_TextWrapped(ctx, comment_text(c))

  if ms then
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

local function draw_status()
  if state.status == "" then return end
  local color = COLORS.muted
  local lowered = state.status:lower()
  if lowered:find("failed") or lowered:find("couldn't") or lowered:find("rejected")
      or lowered:find("check") or lowered:find("no ") then
    color = COLORS.danger
  elseif lowered:find("posted") or lowered:find("pushed") or lowered:find("imported") then
    color = COLORS.success
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_BeginChild(ctx, "status", 0, 44)
  reaper.ImGui_TextColored(ctx, color, state.status)
  reaper.ImGui_EndChild(ctx)
end

-- One-click Connect (the OAuth device grant). Ask the server for a pairing, open
-- the browser for the user to approve, then poll until it hands back a token. The
-- user never sees or pastes a key.
local function start_pairing()
  state.pairing = nil
  local http, body = http_post_json("/api/reaper/pair/start", {})
  if http == 0 then
    state.status = "No response — curl couldn't run from REAPER. Restart REAPER; if it persists, update Take in ReaPack."
    return
  end
  if http ~= 200 then
    state.status = "Couldn't start Connect (server said " .. tostring(http) .. ")."
    return
  end
  local ok, data = pcall(json_decode, body)
  if not ok or type(data) ~= "table" or not data.device_code or not data.verify_url then
    state.status = "Couldn't start Connect (unexpected response)."
    return
  end
  state.pairing = {
    device_code = data.device_code,
    deadline = reaper.time_precise() + (tonumber(data.expires_in) or 600),
    next_poll = reaper.time_precise() + (tonumber(data.interval) or 2),
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
  p.next_poll = now + 2

  local http, body = http_get_json("/api/reaper/pair/poll?device_code=" .. p.device_code)
  if http ~= 200 then return end -- transient; keep waiting until the deadline
  local ok, data = pcall(json_decode, body)
  if not ok or type(data) ~= "table" then return end

  if data.status == "approved" and data.token then
    state.pairing = nil
    state.token = trim(data.token)
    reaper.SetExtState(EXT, "token", state.token, true)
    state.show_settings = false
    state.status = "Connected."
    load_projects()
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
    if primary_button("Connect", content_width()) then start_pairing() end
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
  if primary_button("Done", content_width()) then state.show_settings = false; load_projects() end
end

local function draw_projects()
  section_title("Projects", #state.projects > 0 and (#state.projects .. " available") or "")
  if primary_button("Refresh projects", content_width()) then load_projects() end
  if state.token == "" then
    empty_state("Add your token in Settings to load paid projects.")
    return
  end
  if #state.projects == 0 then
    empty_state("No projects loaded yet.")
    return
  end

  reaper.ImGui_BeginChild(ctx, "project_list", 0, 220)
  for i, p in ipairs(state.projects) do
    local label = tostring(i) .. ". " .. p.name .. "##" .. p.id
    if reaper.ImGui_Selectable(ctx, label) then open_project(p) end
  end
  reaper.ImGui_EndChild(ctx)
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
    reaper.ImGui_BeginChild(ctx, "stem_list", 0, 128)
    for _, s in ipairs(state.stems) do
      reaper.ImGui_TextWrapped(ctx, s.name)
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Import##" .. s.id) then import_stem(s) end
    end
    reaper.ImGui_EndChild(ctx)
  end

  section_title("Push stem", "selected track")
  local changed
  reaper.ImGui_SetNextItemWidth(ctx, content_width())
  changed, state.push_name = reaper.ImGui_InputText(ctx, "Name (optional)", state.push_name)
  if primary_button("Push selected track", content_width()) then push_stem() end

  section_title("Comments", #state.comments > 0 and (#state.comments .. " in this project") or "")
  if reaper.ImGui_Button(ctx, "Refresh comments") then load_comments() end
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
    reaper.ImGui_BeginChild(ctx, "comment_list", 0, 150)
    for _, c in ipairs(state.comments) do
      draw_comment_item(c)
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_SetNextItemWidth(ctx, content_width())
  changed, state.comment_body = reaper.ImGui_InputText(ctx, "New comment", state.comment_body)
  local cursor_label = "At edit cursor @" .. fmt_ts(math.floor((reaper.GetCursorPosition() or 0) * 1000))
  changed, state.comment_at_cursor = reaper.ImGui_Checkbox(ctx, cursor_label, state.comment_at_cursor)
  if primary_button("Post comment") then post_comment() end
  reaper.ImGui_SameLine(ctx)
  if state.recording then
    if reaper.ImGui_Button(ctx, "Stop and post voice memo") then stop_and_post_voice() end
  else
    if reaper.ImGui_Button(ctx, "Record voice memo") then start_voice_record() end
  end
end

local function loop()
  push_theme()
  if state.pairing then poll_pairing() end
  local visible, open = reaper.ImGui_Begin(ctx, "Take", true)
  if visible then
    reaper.ImGui_TextColored(ctx, COLORS.ink, "Take")
    reaper.ImGui_SameLine(ctx)
    muted_text(state.recording and "recording voice memo" or "Reaper collaboration panel")
    if reaper.ImGui_Button(ctx, state.show_settings and "Close settings" or "Settings") then
      state.show_settings = not state.show_settings
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

reaper.defer(loop)
