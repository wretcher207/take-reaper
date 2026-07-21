# Take for Reaper

The stem-and-rough sharing layer that lives inside your DAW.

Tagline: *What's your take?*

## The problem

You send stems via Dropbox. Your collaborator listens to the wrong version. You're now talking about two different songs.

You get feedback in Slack, in email, in a voice memo app. It lives nowhere near the audio it refers to.

You bounce a rough, upload it, wait for reactions, and find out three days later the kick drum at 1:42 was rushing.

You've solved this with discipline and naming conventions and folder structures that fall apart the moment someone opens the wrong file.

## What Take does

Take gives your song-in-progress a home. The project is the container. Stems and roughs stack underneath. Comments pin to specific timestamps on the audio. Your collaborator sees them right where you left them.

From inside Reaper you can:

- Browse your Take projects without leaving your session
- Pull stems from a project onto your timeline at their correct timecode
- Push a track as a new stem
- Push your master as a new rough
- Read comments and drop text or voice memos, pinned to the edit cursor

The Reaper panel talks to the Take web app over HTTPS. Your collaborator doesn't need to be in Reaper. They see everything in the browser.

## Connect

1. Go to [takeaudio.com/settings/reaper](https://takeaudio.com/settings/reaper), create an API token, and copy the full token once.
2. In the Take panel inside Reaper, open **Settings**.
3. Paste `https://takeaudio.com` into **Server URL**.
4. Paste the full `take_...` token into **API token**, then click **Done**.
5. Your paid projects appear. Click one to see its stems and roughs.

The ReaPack URL installs the script. It is not the Server URL.

## Pull

Click **Import** next to any stem. Take downloads the original WAV and drops it on a new track at its stored timecode. Nothing leaves your DAW.

**Import all** pulls every stem you don't already have. Stems whose files are already in your session are labeled **(in session)**.

## Push

Select a track, optionally type a name, click **Push stem**. Take renders that track and uploads it as a new stem on the project.

Click **Render and push as rough** at the top of a project. Take renders your master mix and uploads it as the current rough.

These reuse your project's render format. Set it once in **File > Render**. WAV, AIFF, FLAC, or MP3. WAV is the default.

The web app generates the compressed playback copy after upload. A pushed file shows as "processing" for a moment before it plays. The status area shows live transfer progress while an upload or download runs.

## Comment and voice memo

The **Comments** section lists the discussion on the current rough. It refreshes itself every 30 seconds while a project is open, so collaborator feedback shows up as you work.

Timeline comments have **Jump** and **Marker** actions. Jump moves Reaper's edit cursor to the comment time. Marker drops a Reaper project marker named `Take: ...` at that timestamp. **Drop timeline markers** adds markers for every timestamped Take comment, and **Clear Take markers** removes only markers with the `Take:` prefix.

Type into **New comment** and press **Post comment**. With **At edit cursor** checked, it pins to that timecode on the rough. Unchecked, it's a project-level note.

**Record voice memo** arms a throwaway track placed past the end of your project. Nothing on your timeline is touched. Your other tracks' record-arm state is saved and restored when you stop.

**Stop and post voice memo** uploads the recording as a voice comment. The edit cursor position at record time becomes the comment's timecode.

For posted voice memo comments, **Voice** downloads the memo through a short-lived Take URL and opens it with your system audio player.

Pick which audio input the memo records from under **Settings > Voice memos** (defaults to input 1). The choice is remembered between sessions.

## Install

Requires the **ReaImGui** extension. Install it via ReaPack from the default ReaTeam repository if you don't have it.

1. Reaper > Extensions > ReaPack > Import repositories
2. Paste this URL: `https://takeaudio.com/reaper/index.xml`
3. Install **Take.lua** from the "Take" category
4. Bind it to a keyboard shortcut or find it in the Actions list

The panel checks once per launch whether a newer Take version is on ReaPack and shows a nudge to synchronize.

## Pricing

Free: web app, text comments, stem and rough uploads, 5GB storage.

$12/month: Reaper integration, voice memos, cut and loop proposals, 100GB storage, 12-month history, public wrap pages.

Project owner pays. Collaborators ride along.
