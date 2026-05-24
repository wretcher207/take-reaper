# Take for Reaper

The Reaper-side of Take. A docked ImGui panel that browses your Take projects and moves audio both ways without leaving the DAW.

Status: **push, pull, comment, and voice memo live** (v0.4.0). Token auth → project list → project detail → pull a stem onto a track at its timecode, push back (render the selected track as a new stem, or the master as a new rough), and read/drop comments — text or a recorded voice memo, posted "at edit cursor" pins to that timecode on the current rough.

## Connect

1. At [take-ebon.vercel.app](https://take-ebon.vercel.app) → **Reaper access**, create an API token (copy it once).
2. In the Take panel, open **Settings**, paste the token (and the server URL if you're not on take-ebon.vercel.app), then **Done**.
3. Your paid projects appear. Click one to see its stems.

Reaper only sees projects whose owner is on a paid plan — that's the upgrade lever. It's also the only client that downloads original WAVs; the web app streams compressed copies.

## Pull

In a project, click **Import** next to a stem. Take downloads the original and drops it on a new track at its stored timecode.

## Push

- **Push selected track as stem** — select a track, optionally type a name, click **Push stem**. Take renders that track and uploads it as a new stem on the project.
- **Render & push as rough** — click the button at the top of a project. Take renders the master mix and uploads it as a new rough, which becomes the project's current rough.

Pushes reuse **this project's REAPER render format**. Set it once in **File → Render** to WAV, AIFF, FLAC, or MP3 (WAV is REAPER's default). If your render format is something else, Take will say so. The web app generates the compressed playback copy after upload, so a pushed file shows as "processing" for a moment before it plays on the web.

## Comment & voice memo

In a project, the **Comments** section lists the discussion. Type into **New comment** and **Post comment** — with **At edit cursor** checked, it pins to that timecode on the current rough; unchecked, it's a project-level note.

**Record voice memo** records from your default audio input onto a throwaway track placed past the end of the project (nothing on your timeline is touched), then **Stop & post voice memo** uploads it as a voice comment. Record-arm on your tracks is saved and restored, and the edit cursor at record-time becomes the comment timecode (when **At edit cursor** is checked). Make sure your mic is on REAPER's first audio input.

Needs `curl` (built into Windows 10+, macOS, and Linux) and the **ReaImGui** extension.

## Install (for dev)

1. Reaper → Extensions → ReaPack → Import repositories
2. Paste the raw URL of this directory's `index.xml`
3. Install **Take.lua** under the "Take" category
4. Bind it to a keyboard shortcut or run it from the Actions list

Requires the **ReaImGui** extension (install via ReaPack from the default ReaTeam repo if you don't already have it).
