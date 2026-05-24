-- @description Take for Reaper
-- @version 0.4.0
-- @author Dead Pixel Design
-- @about
--   A docked panel that connects this Reaper session to your Take projects.
--   Paste an API token (create one at take-ebon.vercel.app -> Reaper access), browse the
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
local ctx = reaper.ImGui_CreateContext("Take")

local state = {
  base_url = reaper.GetExtState(EXT, "base_url"),
  token = reaper.GetExtState(EXT, "token"),
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
}
if state.base_url == "" then state.base_url = "https://take-ebon.vercel.app" end

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

-- Pull the http status (last line) out of ExecProcess's "<exitcode>\n<stdout>".
local function status_from(out)
  out = out or ""
  local nl = out:find("\n")
  return tonumber((out:sub((nl or 0) + 1)):match("%d+")) or 0
end

local function http_get_json(path)
  local out_file = tmp_path("resp.json")
  local url = state.base_url .. path
  local cmd = "curl -s -H " .. q("Authorization: Bearer " .. state.token)
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
  local cmd = "curl -s -X POST"
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
  local cmd = "curl -s -L -o " .. q(dest) .. " -w " .. q("%{http_code}") .. " " .. q(url)
  return status_from(reaper.ExecProcess(cmd, 120000))
end

-- PUT a file to a (pre-signed) upload URL, streamed. Returns http_status.
-- The response body is diverted to a file (-o) so stdout is only the http_code;
-- otherwise status_from would parse a digit out of the JSON body.
local function http_upload(url, filepath, content_type)
  local out_file = tmp_path("upload_resp.txt")
  local cmd = "curl -s -X PUT -T " .. q(filepath)
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

  -- 42230 renders synchronously, but allow a brief settle in case the file
  -- handle lags behind the action returning.
  local deadline = reaper.time_precise() + 10.0
  repeat
    local file, ext = find_rendered(dir)
    if file then return file, ext end
  until reaper.time_precise() > deadline
  return nil
end

-- --------------------------------------------------------------------------
-- Actions
-- --------------------------------------------------------------------------
local function load_projects()
  if state.token == "" then state.status = "Add a token in Settings first."; return end
  state.status = "Loading projects…"
  local http, body = http_get_json("/api/reaper/projects")
  if http == 401 then state.status = "Token rejected. Check it in Settings."; return end
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

-- Voice memos (spec §2.5, paid §2.11). request signed URL -> PUT the WAV ->
-- finalize as a voice comment. ext/content-type come from the recorded file +
-- the request response; the voice-memos bucket accepts wav.
local function post_voice_memo(file, ext, timestamp_ms)
  local pid = state.project.id
  local req_http, req_body = http_post_json(
    "/api/reaper/projects/" .. pid .. "/voice/request", { ext = ext })
  if req_http == 401 then state.status = "Token rejected. Check it in Settings."; return end
  if req_http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if req_http == 400 then state.status = "Recording format not accepted (" .. ext .. ")."; return end
  if req_http ~= 200 then state.status = "Voice request failed (" .. req_http .. ")."; return end
  local req = json_decode(req_body)
  if not req or not req.signedUrl then state.status = "No upload URL returned."; return end

  local up = http_upload(req.signedUrl, file, req.contentType or MIME[ext] or "audio/wav")
  if up ~= 200 then state.status = "Upload failed (" .. up .. ")."; return end

  local payload = { path = req.path }
  if timestamp_ms then payload.timestampMs = timestamp_ms end
  local fin_http = select(1, http_post_json(
    "/api/reaper/projects/" .. pid .. "/voice/finalize", payload))
  if fin_http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if fin_http ~= 200 then state.status = "Finalize failed (" .. fin_http .. ")."; return end

  load_comments()
  state.status = "Voice memo posted."
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
    os.remove(file)
    state.status = "Nothing recorded (silent). Check your mic input."
    return
  end

  local ext = (file:match("%.([^.]+)$") or "wav"):lower()
  state.status = "Uploading voice memo…"
  post_voice_memo(file, ext, v.timestamp_ms)
  os.remove(file)
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

  state.status = "Rendering…"
  local file, ext = render_to_temp(render_settings, pattern)
  if not file then
    state.status = "No render produced. Set REAPER's render format to WAV, AIFF, FLAC, or MP3."
    return
  end

  state.status = "Uploading " .. name .. "…"
  local req_http, req_body = http_post_json("/api/reaper/push/" .. kind .. "/request", {
    projectId = state.project.id,
    ext = ext,
    sizeBytes = file_size(file),
    mimeType = MIME[ext],
  })
  if req_http == 401 then state.status = "Token rejected. Check it in Settings."; return end
  if req_http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if req_http ~= 200 then state.status = "Push request failed (" .. req_http .. ")."; return end
  local req = json_decode(req_body)
  if not req or not req.signedUrl then state.status = "No upload URL returned."; return end

  local up = http_upload(req.signedUrl, file, MIME[ext])
  if up ~= 200 then state.status = "Upload failed (" .. up .. ")."; return end

  local body = { projectId = state.project.id, path = req.path }
  body[kind == "stem" and "stemId" or "roughId"] = (kind == "stem") and req.stemId or req.roughId
  for k, v in pairs(extra or {}) do body[k] = v end

  local fin_http = select(1, http_post_json("/api/reaper/push/" .. kind .. "/finalize", body))
  if fin_http == 403 then state.status = "This project's owner isn't on a paid plan."; return end
  if fin_http ~= 200 then state.status = "Finalize failed (" .. fin_http .. ")."; return end

  os.remove(file)
  if on_done then on_done() end
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

  do_push("stem", 0, "take_stem", name, { name = name, timecodeOffsetMs = 0 }, function()
    state.status = "Pushed stem: " .. name .. "."
    open_project(state.project) -- refresh the stem list
  end)

  for i = 0, count - 1 do
    reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO", saved_solo[i] or 0)
  end
  reaper.UpdateArrange()
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
local function draw_settings()
  local changed
  changed, state.base_url = reaper.ImGui_InputText(ctx, "Server URL", state.base_url)
  if changed then reaper.SetExtState(EXT, "base_url", state.base_url, true) end
  changed, state.token = reaper.ImGui_InputText(ctx, "API token", state.token,
    reaper.ImGui_InputTextFlags_Password())
  if changed then reaper.SetExtState(EXT, "token", state.token, true) end
  if reaper.ImGui_Button(ctx, "Done") then state.show_settings = false; load_projects() end
end

local function draw_projects()
  if reaper.ImGui_Button(ctx, "Refresh") then load_projects() end
  reaper.ImGui_Separator(ctx)
  for _, p in ipairs(state.projects) do
    if reaper.ImGui_Selectable(ctx, p.name .. "##" .. p.id) then open_project(p) end
  end
end

local function draw_project()
  if reaper.ImGui_Button(ctx, "< Projects") then state.view = "projects" end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, state.project and state.project.name or "")
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Render & push as rough") then push_rough() end
  reaper.ImGui_Separator(ctx)

  for _, s in ipairs(state.stems) do
    reaper.ImGui_Text(ctx, s.name)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Import##" .. s.id) then import_stem(s) end
  end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Push selected track as stem")
  local changed
  changed, state.push_name = reaper.ImGui_InputText(ctx, "Name (optional)", state.push_name)
  if reaper.ImGui_Button(ctx, "Push stem") then push_stem() end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Comments")
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Refresh##comments") then load_comments() end
  if #state.comments == 0 then
    reaper.ImGui_TextWrapped(ctx, "No comments yet.")
  else
    for _, c in ipairs(state.comments) do
      local who = c.author_name or "?"
      local at = c.timestamp_ms and (" @" .. fmt_ts(c.timestamp_ms)) or ""
      local text = c.is_voice and "[voice memo]" or (c.body or "")
      reaper.ImGui_TextWrapped(ctx, who .. at .. ": " .. text)
    end
  end
  changed, state.comment_body = reaper.ImGui_InputText(ctx, "New comment", state.comment_body)
  changed, state.comment_at_cursor = reaper.ImGui_Checkbox(ctx, "At edit cursor", state.comment_at_cursor)
  if reaper.ImGui_Button(ctx, "Post comment") then post_comment() end
  reaper.ImGui_SameLine(ctx)
  if state.recording then
    if reaper.ImGui_Button(ctx, "Stop & post voice memo") then stop_and_post_voice() end
  else
    if reaper.ImGui_Button(ctx, "Record voice memo") then start_voice_record() end
  end
end

local function loop()
  local visible, open = reaper.ImGui_Begin(ctx, "Take", true)
  if visible then
    if reaper.ImGui_Button(ctx, state.show_settings and "Close settings" or "Settings") then
      state.show_settings = not state.show_settings
    end
    reaper.ImGui_Separator(ctx)

    if state.show_settings then
      draw_settings()
    elseif state.view == "project" then
      draw_project()
    else
      draw_projects()
    end

    if state.status ~= "" then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, state.status)
    end
    reaper.ImGui_End(ctx)
  end
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
