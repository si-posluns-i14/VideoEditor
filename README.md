# VideoEditor

A native macOS app with two halves:

1. **A recorder** — capture the screen and the webcam at the same time, natively, with
   system audio and microphone. No OBS, no virtual camera, no extra software.
2. **A simple video editor** — import clips, scrub them, trim them, reorder them, and
   splice them into one file. Cut and join only: no transitions, no filters, no colour
   correction — with two deliberate exceptions, picture-in-picture and background removal.

Everything for a project lives in **one ordinary folder you pick**. No hidden library
bundle, no render caches in `~/Library`.

Built with Swift and SwiftUI against Apple's own frameworks only (ScreenCaptureKit,
AVFoundation, AVKit, Vision, Core Image). No Xcode project, no Swift Package Manager, no
third-party dependencies — just `swiftc` from the Command Line Tools.

---

## Running it

Double-click `VideoEditor.app`, or drag it to the Dock → right-click → **Options → Keep
in Dock**.

**First run:** the app is built locally and ad-hoc signed, so macOS may say it's from an
unidentified developer. Right-click the app → **Open** → **Open**. You only do this once.

The bundle is **self-contained and relocatable** — move it to `/Applications` or anywhere
else. It does not depend on this source folder staying where it is.

---

## The workspace

On launch you pick or create a workspace folder. Inside it:

```
MyProject/
  Media/                    every clip you import is COPIED here
  Exports/                  every render lands here
  VideoEditorProject.json  the whole project, in plain readable JSON
```

- Clip paths in the JSON are **relative to `Media/`**, so you can zip the folder, move it
  to another Mac, and reopen it there with everything intact.
- "Add Clip" copies by default. There is also **Add Clip (reference only, do not copy)**
  in the Add menu for very large files — but a referenced clip breaks if you later move
  the original, which is exactly the problem the copy behaviour exists to avoid.
- The project file autosaves ~2 seconds after you stop changing things, and on quit.
- If a file listed in the project is gone from `Media/`, the clip shows as
  **"Missing clip"** rather than crashing. Put the file back and reopen the workspace.
- **Recent Workspaces** (up to 10) appear on the welcome screen and under File → Open
  Recent.

The only things stored outside the workspace folder are the recent-workspaces list and your
recording preferences (`UserDefaults`, under `local.videoeditor.app`). Recording device
choices live there rather than in the project file because they are specific to this Mac.

A workspace made by the old StreamCutter build is migrated in place the first time you open
it: `StreamCutterProject.json` is renamed to `VideoEditorProject.json`, clips and all.

---

## Capture mode and Timeline mode

The switch at the top of the window moves between the app's two halves:

- **Capture** — a large camera preview, the capture settings beside it, and one record
  button. ⌘1.
- **Timeline** — the clip list, the scrubbable preview with trim markers, the clip
  inspector and export. ⌘2.

Opening a workspace lands you in Capture if it has no clips yet, and in Timeline if it
does. After a take finishes, Capture offers an **Assemble in Timeline** button. The switch
is disabled while recording, because tearing down the camera preview mid-take would abort
the recording.

## Part A — recording

VideoEditor captures the screen and the webcam itself. There is nothing to install and
nothing to connect to — no OBS, no virtual camera, no extra driver.

Everything is recorded and exported as **H.264 in an .mp4**, which is what every editor,
browser and platform accepts without argument. The single exception is a transparent
export, which needs an alpha channel and so comes out as ProRes 4444 in a `.mov` — .mp4
cannot carry transparency.

- **Screen** uses Apple's ScreenCaptureKit: pick a display, optionally capture **system
  audio** (whatever your Mac is playing), and choose 24, 30 or 60 fps. Recording is at
  native Retina resolution, and VideoEditor's own window is excluded so the preview does
  not mirror into infinity.
- **Webcam** uses AVFoundation: pick a camera, optionally record the **microphone**, and
  watch a live preview before and during the take.
- Either can be turned off. If one fails to start, the other still records and the panel
  says what went wrong.

Press **Start Recording** (⌘R) and both run together. On stop you get **two separate
files** in the workspace's `Media/` folder:

```
Take - Screen.mp4
Take - Self-View.mp4
```

They are appended to the timeline straight away as one more pair: the screen on the **Clip**
row, the webcam on the **Self-View** row directly beneath it, both starting together. Nothing is
baked in at record time, so you can trim them separately, reorder them, split them, drop the
overlay, or move either to the other row. Record as many takes as you like — each becomes
another column.

### Permissions

Both are ordinary macOS privacy permissions, and macOS asks the first time you record:

- **Screen & System Audio Recording** — System Settings → Privacy & Security. Without it
  the screen half of a recording fails with a message pointing you here; there is a button
  in the panel that opens the right pane.
- **Camera** and **Microphone** — System Settings → Privacy & Security.

These used to reset on every rebuild, because an ad-hoc signature changes with the binary
and macOS then treats the app as a different one. The app is now signed with a **stable
self-signed certificate** ("VideoEditor Local Signing") held in your login keychain, so its
designated requirement stays the same across builds:

```
identifier "local.videoeditor.app" and certificate root = H"102bec…"
```

Grant the permissions once and they survive every `./build.sh`. If the certificate is
missing, `build.sh` falls back to ad-hoc signing and says so — everything still builds, the
permissions just go back to resetting each time.

### Undoing the signing setup

Everything it touched on your Mac, and how to reverse it:

| What | Undo |
| --- | --- |
| Certificate + private key in the login keychain | `security delete-identity -c "VideoEditor Local Signing"` — or delete it in Keychain Access → login → Certificates, which removes the key and the trust setting with it |
| Trust setting (code signing only, your user account) | `security remove-trusted-cert signing-cert.pem` — unnecessary if you deleted the certificate |
| "Always Allow" for `codesign` on that key | Goes away with the key |
| Screen Recording / Camera / Microphone grants | `tccutil reset ScreenCapture local.videoeditor.app` (and `Camera`, `Microphone`), or switch them off in System Settings |
| Recent workspaces and recording preferences | `defaults delete local.videoeditor.app` |

`signing-cert.pem` in this folder is the public certificate, kept only so the
`remove-trusted-cert` command above has something to point at. The private key exists only
in your keychain — it was never left on disk.


## Part B — the timeline

Timeline mode has four parts: the **workspace browser** on the left, the **preview** in the
middle, the **inspector and export** on the right, and the **timeline** across the bottom.

### The two rows

```
Clip:       [ clip 1 ][ clip 2 ][ clip 3 ]
Self-View:  [ clip 1 ][ clip 2 ]
```

The **Clip** row is what fills the frame; the **Self-View** row is the webcam, composited
over whatever is underneath it at that moment. The rows are entirely independent — nothing
is tied to anything else.

**The two rows are independent lanes on one ruler.** Each clip carries its own start time,
so a row can hold any number of clips of any length, with gaps wherever you leave them —
three clips under one long self-view, one clip under three self-views, or nothing at all on
a row for a stretch. Drag a clip along its row to move it, or drag either end to change its length; both snap
to the playhead, to the ruler's zero, and to the edges of every other clip on either row.

Where only one row has something playing, that one is shown on its own: a clip fills the
frame, and a self-view keeps its usual place and size over black. A gap on both rows is
black.

| | While both play | Where only one plays |
| --- | --- | --- |

| | While both play | Afterwards |
| --- | --- | --- |
| Clip only | — | Clip fills the frame |
| Self-view only | — | Self-view keeps its place and size, **over black** |
| Both | Clip full frame, self-view as picture-in-picture | — |

The self-view never changes size or position just because there is nothing under it. The
same holds when a clip is missing from `Media/`: the self-view still plays, over black.

Cards are drawn to scale. The **zoom** slider in the timeline header changes the scale, and
**Gaps** packs a row end to end when you want the old behaviour back.

- **Trim** by grabbing either end of a card and dragging.
- **Move** by dragging a card along its row — including straight past its neighbours. A
  clip dropped beyond another lands after it; whatever it overlaps is pushed clear.
- **Move several at once**: select them, then drag any one and the whole group travels
  together, keeping its spacing.
- **Re-host** a self-view by dragging it onto a different column.
- Right-click → Move to Self-View Row / Move to Clip Row to change a clip's row, or Detach
  from Clip to unhook a self-view.
- A self-view that has lost its host is shown dimmed at the end of the row rather than
  disappearing.

### Undoing

**⌘Z** undoes timeline edits and **⇧⌘Z** redoes them, with the menu naming the step
("Undo Split Clip", "Undo Move Clip", and so on). Trims, splits, reorders, row changes,
additions and deletions are all covered, up to 60 steps deep, and the history resets when
you open a different workspace. A continuous drag of a trim handle collapses into one step
rather than a hundred. If a text field has focus, ⌘Z goes to the field instead, as it
should.

Undo covers the *timeline*, not the workspace folder: it never deletes or restores files on
disk.

### Selecting

Click a clip to select it. **Shift-click** extends the selection along that row,
**⌘-click** adds or removes one clip, and **dragging across empty timeline** rubber-bands
a selection — the rectangle picks up everything it touches, on one row or both. Ranges stay within a row, since the two rows are
separate sequences. The last clip clicked is the *anchor* — it is what the inspector and
the Clip preview follow, and it carries a thin inner outline when more than one clip is
selected.

Delete acts on the whole selection, as a single undo step. Right-clicking inside a
multi-selection offers "Delete N Clips"; right-clicking outside it acts on just that clip.
Dragging still moves one clip at a time.

### Cut, copy and paste

**⌘X**, **⌘C** and **⌘V** work on the selection. Paste drops the clips in at the playhead,
on the rows they came from and keeping their spacing relative to each other. If the gap
there is big enough they slot into it; if not, whatever follows slides right by exactly the
shortfall.

As with undo, a focused text field gets ⌘X/⌘C/⌘V first, so editing the take or export name
behaves normally.

### Deleting

Right-click any clip on the timeline → **Delete** removes it from the timeline, leaving the
file in `Media/`. **⌘⌫** does the same to the selected clip, as does the Delete key while
the timeline has focus. Both are undoable.

To remove the file itself, right-click it in the workspace browser → **Move File to Trash…**.
That asks first, warns you if the timeline is using it, and goes to the Trash rather than
vanishing — it is a file operation, so undo does not cover it.

### Adding, moving and overlaps

Dropping a clip onto a row **inserts** it: everything from that point onwards slides right
to make room. Drop inside an existing clip and it lands after that clip rather than on top
of it — drops never overlap anything.

Clips on a row can never overlap. Dragging stops at the neighbouring clip, and trimming a
clip outwards stops at the neighbour too rather than running over it. This is not just
tidiness: the export places clips in order, so a clip hidden underneath another would
silently vanish from the finished video.

**Gaps** in the header packs a row end to end when you want the space back.

### Scrubbing and splitting

The **ruler** above the rows scrubs the whole assembled sequence — drag it and the preview
follows, with the red playhead showing where you are. The preview is the real composite,
picture-in-picture included.

**Split (⌘B)** cuts the clip under the playhead in two. It applies inside the clip itself,
not in a stretch where a longer self-view is carrying the frame on its own. A self-view riding on it is cut at
the same instant and its tail is re-hosted onto the new clip, so the rows stay in step. If
the self-view had already ended before the playhead, the second half simply has none.

### Preview: Sequence or Clip

- **Sequence** plays the assembled timeline. This is where the ruler, the playhead and
  Split apply.
- **Clip** plays the selected clip on its own, with the in/out trim handles and
  **Set In** / **Set Out** (`[` and `]`). Each clip keeps its own trim.

Background removal is *not* applied to the preview — it is far too slow to run per frame
while scrubbing — so a clip with it switched on previews unmodified and is processed at
export.

### The workspace browser

The left sidebar — present in **both** Capture and Timeline mode — lists what is actually in
the workspace folder: every video in `Media/` and every render in `Exports/`, whether or not
the timeline uses it. Files already on the timeline carry a tick. **Import…** copies new
files in.

To get a file onto the timeline: **drag it from the browser onto either row**, drop it at
the position you want, or double-click to append it to the Clip row. Right-click offers
both rows explicitly. Dropping onto a Self-View slot attaches the clip to that column;
dropping on the dashed box at the end of a row appends. Files dragged in from Finder are
copied into `Media/` first.

Dragging a clip that is already on the timeline moves it instead: along its row to reorder,
or onto a different column to re-host a self-view.

### Export

Exports are named after the workspace folder by default — a project called `Interview Cut`
renders `Interview Cut.mp4` — and you can change the name per export. Repeats get numbered
rather than overwriting.

Export builds an `AVMutableComposition`, inserting only each clip's trimmed range in row
order, compositing each self-view into its host's corner, and renders into `Exports/` with
a progress bar and a **Reveal in Finder** button. Output is H.264 `.mp4` at Highest /
Medium / Low quality.

**Known limitation:** cuts are made at your exact trim points, which do not necessarily
land on a keyframe. A single soft or black frame at a join is normal for a plain
cut-and-join tool.

## Part C — framing and picture-in-picture

### Aspect ratio

The **Frame** section on the right (and the aspect menu in the timeline header) sets the
shape of the exported video:

| Preset | For |
| --- | --- |
| Original | Whatever the clips already are |
| 16:9 — Landscape | YouTube, Vimeo, standard video |
| 9:16 — Vertical | YouTube Shorts, TikTok, Reels, Stories |
| 1:1 — Square | Instagram and LinkedIn feed |
| 4:5 — Portrait | Instagram portrait — the tallest the feed allows |
| 4:3 — Classic | Older cameras and slide decks |
| 21:9 — Cinematic | Ultrawide / letterboxed film look |

**Fill frame (crop)** cuts the overflow away; **Fit inside (letterbox)** keeps everything
and pads the sides. The output resolution is the largest frame of that aspect that fits
inside the source, so re-framing never enlarges the picture — a 3024×1964 screen recording
cropped to 9:16 comes out 1104×1964, not a blurry upscale.

### Seeing and moving the crop

With **Show what gets cropped** on, the preview shows the whole source frame with
everything outside the crop dimmed and the surviving window outlined in yellow, labelled
with the output size. **Drag that box** to reposition the crop, or use the **X** and **Y**
sliders — 0% is left/top, 100% is right/bottom, and only the axis actually being cropped
does anything. **Centre** puts it back.

Switch the toggle off and the preview shows the cropped result exactly as it will export.

### The self-view

Anything on the Self-View row is picture-in-picture, placed freely rather than snapped to a
corner. Select it and the inspector gives you:

- **Size** — the overlay's width as a share of the frame, from 8% up to 100%. At the top of
  the range it fills the frame, which is how you cut to camera.
- **X** and **Y** — anywhere in the frame, continuously.
- **Snap to** — four corners and centre, for when you just want it parked.
- **Corners** — square, or rounded with a radius slider. Rounding is masked in Core Image,
  so a rounded self-view switches the export onto the Core Image path; square costs
  nothing.

The position is relative to the **exported** frame, so it follows whatever aspect ratio you
pick: with the crop guide showing, the self-view is drawn inside the crop, where it will
actually land, rather than against the uncropped source.

Both clips start from time zero of their own trimmed ranges, and the overlay stops when the
shorter of the two ends. The self-view's audio, if it has any, is mixed in on its own track.

## Part D — background removal

Per clip, in the inspector — usually the self-view: **Remove Background**. It uses Apple's Vision framework
(`VNGeneratePersonSegmentationRequest`) entirely on-device — no internet, no external
service — and replaces everything that is not a person with either a solid colour or
transparency.

- The thumbnail in the inspector previews the effect on the current frame. The effect
  itself is applied **only at export**, so scrubbing stays responsive.
- Quality is **Balanced** or **Accurate**. Accurate is slower with cleaner edges.
- **Transparent** output needs an alpha channel, so that export is written as **ProRes
  4444 in a `.mov`**, not `.mp4` — H.264 cannot hold transparency. The app switches format
  automatically and tells you in the Export panel.
- Background removal makes exports noticeably slower. Hair and fast motion are the hardest
  cases for the built-in model; the edges will not be perfect.

---

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| ⌘N / ⌘O | New / Open Workspace |
| ⇧⌘W | Close Workspace |
| ⌘S | Save project now |
| ⇧⌘R | Show workspace in Finder |
| ⌘1 / ⌘2 | Capture mode / Timeline mode |
| ⌘B | Split the clip under the playhead |
| ⌘Z / ⇧⌘Z | Undo / redo a timeline edit |
| ⌘X / ⌘C / ⌘V | Cut / copy / paste clips |
| ⌘⌫ | Delete the selected clip from the timeline |
| ⌘R | Start / stop recording |
| ⌘I | Add Clip (⇧⌘I for reference-only) |
| `[` / `]` | Set in point / out point at the playhead |
| ⌘E | Export |
| Space | Play / pause |

---

## Rebuilding

```bash
./build.sh
```

Takes about 45 seconds. It compiles every `.swift` file with `swiftc`, assembles
`VideoEditor.app`, ad-hoc signs it and re-registers it with Launch Services. Xcode is not
required and is not installed on this machine — Command Line Tools ship `swiftc` and the
full macOS SDK.

### Source layout

```
VideoEditorApp.swift              app entry point, menu commands
ContentView.swift                  welcome screen, three-pane split, export panel
AppModel.swift                     workspace + clips + playback state
Support.swift                      formatting helpers, @State shim, codable colour
Record/    ScreenRecorder.swift    ScreenCaptureKit stream -> AVAssetWriter
           WebcamRecorder.swift    AVCaptureSession camera + mic, serialized
           RecordingManager.swift  runs both as one session, hands files to the editor
           CaptureView.swift       capture mode UI
Workspace/ WorkspaceManager.swift  folder creation, clip import, export naming
           ProjectFile.swift       VideoEditorProject.json read/write
           RecentWorkspaces.swift  recent list
Editor/    ClipModel.swift         Clip + ClipData (track, pairing, trim, overlay placement),
                                   plus the aspect-ratio presets and FrameSpec
           FramePanel.swift        aspect controls and the draggable crop guide
           EditorView.swift        preview, transport, trim controls, inspector
           TimelineStripView.swift two-row sequence, ruler, playhead, drag and drop
           MediaBrowserView.swift  the workspace folder, listed
           PlayerView.swift        AVPlayerView wrapper + scrub bar
           ExportManager.swift     TimelineBuilder + AVAssetExportSession
           PiPCompositor.swift     geometry + layer-instruction PiP
           BackgroundRemovalCompositor.swift  custom AVVideoCompositing using Vision
```

(All files sit flat in this folder; the grouping above is conceptual.)

### Two things worth knowing if you edit the source

- **`@SCState`, not `@State`.** The macOS 26 SDK declares `State` as a SwiftUI *macro*
  backed by the `SwiftUIMacros` compiler plugin, which ships with Xcode but not with the
  Command Line Tools — so `@State` fails to compile here. `Support.swift` defines
  `typealias SCState = SwiftUI.State`, the original property wrapper, which behaves
  identically. If you ever move this into Xcode you can change it back.
- **Never reconfigure a live `AVCaptureSession` off its own queue.** `CameraEngine`
  funnels every session call through one serial queue; doing it from the main thread while
  `startRunning()` enumerates the inputs crashes inside AVFoundation. Attaching the preview
  layer counts as a configuration change too, which is why `CaptureView` mounts the
  preview once and only fades it, rather than swapping it in when the camera goes live —
  attaching it mid-recording aborts the take with `AVErrorSessionConfigurationChanged`.
- **An empty `AVMutableCompositionTrack` breaks export.** Audio tracks are created only
  when there is real audio to put in them — both the main one and the self-view's — and any
  zero-length track is stripped before the composition is handed over. Otherwise a silent
  clip makes the export fail with a bare "operation could not be completed".
- **`Text("\(Int(x))")` localises the number**, so 1104 renders as "1,104". Pixel
  dimensions use `Text(verbatim:)`.
- **A video composition's instructions must tile the composition exactly.** They have to
  start at zero, leave no gaps and end on its last frame. Accumulating column durations in
  seconds drifts a millisecond or two against the tracks' own rounding — and while an
  export and `AVAssetImageGenerator` both shrug that off, `AVPlayer` quietly treats the
  composition as invalid and draws nothing at all: right rate, advancing time, tracks
  enabled, black screen. `TimelineBuilder.normalise` stretches the list to fit before the
  plan is handed out. `AVVideoComposition.isValid(for:timeRange:validationDelegate:)` is
  what names the problem.
- **Never attach a drag gesture to the thing the drag moves.** This bit twice: the crop
  guide, and the timeline's trim handles, which sit on a card whose width the drag changes.
  Both now measure in a fixed named coordinate space.
- **Original note, kept because the reasoning is the same:** The crop guide's gesture
  first sat on the crop rectangle itself; because the rectangle moves as you drag, it
  shifted out from under the gesture, which changed the reported translation, which moved it
  again — it drifted across the frame on its own. The gesture now sits on the fixed preview
  area and only checks that the drag *started* inside the rectangle.
- **A segmented `Picker` in the toolbar writes its own selection back.** The Capture /
  Timeline switch is two plain Buttons for exactly this reason: as a `Picker` bound to the
  model it silently pushed the app into the other mode a few seconds after launch, once the
  toolbar realised.
- **`AVAssetTrack.asset` is a weak reference.** `TimelineBuilder` deliberately holds each
  `AVURLAsset` alongside its tracks. Drop that and every export fails with a bare
  AVFoundation "unknown error".

### Debug hooks

Two environment variables, useful when testing without clicking through the UI:

```bash
open -n VideoEditor.app --args --workspace /path/to/MyProject
open -n VideoEditor.app --args --workspace /path/to/MyProject --autorecord 6
open -n VideoEditor.app --args --workspace /path/to/MyProject --autosplit 3.5
open -n VideoEditor.app --args --workspace /path/to/MyProject --undotest 1
open -n VideoEditor.app --args --workspace /path/to/MyProject --selecttest 1
open -n VideoEditor.app --args --workspace /path/to/MyProject --reportstate 1
open -n VideoEditor.app --args --workspace /path/to/MyProject --autoexport 1
```

`--workspace` opens that folder immediately, `--autorecord <seconds>` records for that long
and stops, `--autosplit <seconds>` seeks there and splits, `--trimtest <seconds>` nudges the
`--undotest` exercises undo and redo, `--selecttest` exercises shift/⌘ selection and batch
delete, `--dragtest` drags a clip past its neighbours and moves a group, `--clipboardtest`
exercises cut/copy/paste, `--autoexport` starts an export, and
`--reportstate` dumps the model. They write to `/tmp/videoeditor-debug.log`, and
`--reportstate` also traces mode changes to `/tmp/videoeditor-trace.log`. Each also works as an environment variable
(`VIDEOEDITOR_WORKSPACE`, and so on). Launch through `open` rather than running the binary
directly, or macOS attributes the camera and screen permissions to the parent process
instead of the app.

---

## Notes and limits

- **macOS 14 or newer**, Apple silicon or Intel (built for whichever machine runs
  `build.sh`).
- The app is **not sandboxed**, so it reads and writes your chosen workspace folder
  directly — no security-scoped bookmarks needed. macOS may still ask for access the first
  time the workspace sits in Desktop, Documents or Downloads.
- **Recording permissions reset on every rebuild** — see Part A. Nothing else about the app
  changes; only macOS's view of its identity does.
- No transitions, text, filters, colour correction, speed changes or audio mixing beyond
  what each clip already carries. That is deliberate.
- If you later want a signed, notarised app you can hand to other people, that is a
  separate job: an Apple Developer ID plus `codesign` and `notarytool`.
