#!/bin/bash
# Compile and assemble VideoEditor.app. Re-run after editing any .swift file.
set -e
cd "$(dirname "$0")"

APP="VideoEditor.app"
ARCH="$(uname -m)"

echo "==> Compiling (${ARCH})…"
swiftc -parse-as-library -O -target "${ARCH}-apple-macosx14.0" \
  VideoEditorApp.swift \
  ContentView.swift \
  AppModel.swift \
  Support.swift \
  ScreenRecorder.swift \
  WebcamRecorder.swift \
  RecordingManager.swift \
  CaptureView.swift \
  WorkspaceManager.swift \
  ProjectFile.swift \
  RecentWorkspaces.swift \
  ClipModel.swift \
  EditorView.swift \
  TimelineStripView.swift \
  MediaBrowserView.swift \
  FramePanel.swift \
  PlayerView.swift \
  ExportManager.swift \
  PiPCompositor.swift \
  BackgroundRemovalCompositor.swift \
  -o VideoEditor

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp VideoEditor "$APP/Contents/MacOS/VideoEditor"
chmod +x "$APP/Contents/MacOS/VideoEditor"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VideoEditor</string>
  <key>CFBundleDisplayName</key><string>VideoEditor</string>
  <key>CFBundleIdentifier</key><string>local.videoeditor.app</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>VideoEditor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>VideoEditor shows a live monitor of the OBS Virtual Camera while you record.</string>
  <key>NSMicrophoneUsageDescription</key><string>VideoEditor does not record audio itself; macOS may ask when a virtual camera device is opened.</string>
  <key>NSLocalNetworkUsageDescription</key><string>VideoEditor connects to the OBS WebSocket server to start and stop recording and streaming.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

# Sign with a stable identity so macOS keeps its mind about privacy permissions.
# Ad-hoc signing gives the app a new identity on every build, which makes Screen
# Recording (and anything else TCC guards) have to be granted again each time.
IDENTITY="VideoEditor Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "   signed as: $IDENTITY"
else
  echo "   identity '$IDENTITY' not found — falling back to ad-hoc."
  echo "   Screen Recording permission will reset on every rebuild. See the README."
  codesign --force --sign - "$APP" 2>/dev/null || echo "   (ad-hoc signing skipped)"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"

echo "==> Done: $PWD/$APP"
