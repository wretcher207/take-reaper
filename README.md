# Take for Reaper

The Reaper-side of [Take](https://take-ebon.vercel.app). A docked ImGui panel that browses your Take projects and moves audio both ways without leaving the DAW.

This repo is the ReaPack distribution for the Take Reaper script.

## Install

1. Reaper → **Extensions → ReaPack → Import repositories**
2. Paste this URL:

   ```
   https://raw.githubusercontent.com/wretcher207/take-reaper/main/index.xml
   ```

3. **Extensions → ReaPack → Browse packages**, find **Take.lua** under the "Take" category, right-click → **Install**, then **Apply**.
4. Run it from the Actions list (search "Take") or bind it to a key.

Requires the **ReaImGui** extension (install via ReaPack from the default ReaTeam repo if you don't have it) and `curl` (built into Windows 10+, macOS, and Linux).

## Connect

1. At [take-ebon.vercel.app](https://take-ebon.vercel.app) → **Reaper access**, create an API token (copy it once).
2. In the Take panel, open **Settings**, paste the token, and click **Done**. The server URL is already set; only change it if you're self-hosting.
3. Your paid projects appear. Click one to see its stems.

Reaper only sees projects whose owner is on a paid plan — that's the upgrade lever. It's also the only client that downloads original WAVs; the web app streams compressed copies.

## Pull

In a project, click **Import** next to a stem. Take downloads the original and drops it on a new track at its stored timecode.

## Push

- **Push selected track as stem** — select a track, optionally type a name, click **Push stem**. Take renders that track and uploads it as a new stem.
- **Render & push as rough** — renders the master mix and uploads it as a new rough, which becomes the project's current rough.

Pushes reuse this project's REAPER render format (File → Render → WAV/AIFF/FLAC/MP3; WAV is the default). The web app generates the compressed playback copy after upload, so a pushed file shows as "processing" for a moment before it plays on the web.
