#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
swift build -c release --jobs 2
build_root="$(swift build -c release --show-bin-path)"
app="$task_root/.build/app/CodexBar Personal.app"
if [[ -d "$app" ]]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_root/CodexBarPersonal" "$app/Contents/MacOS/CodexBarPersonal"
for resources in "$build_root"/*.bundle; do
  [[ -d "$resources" ]] || continue
  ditto "$resources" "$app/Contents/Resources/$(basename "$resources")"
done
chmod +x "$app/Contents/MacOS/CodexBarPersonal"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.yuri.CodexBarPersonal</string>
<key>CFBundleExecutable</key><string>CodexBarPersonal</string>
<key>CFBundleName</key><string>CodexBar Personal</string>
<key>CFBundleDisplayName</key><string>CodexBar Personal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/MacOS/CodexBarPersonal"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
