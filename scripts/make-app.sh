#!/bin/sh
# Builds the WizRec player in release mode and wraps it into build/WizRec.app.
#
#   scripts/make-app.sh            # → build/WizRec.app
#   build/WizRec.app/Contents/MacOS/WizRec "<project.cmproj>" [--autoplay] [--overlay] [--stats-log]
#
# FFmpeg is linked from Homebrew (not bundled yet; that is an M11 task), so the
# app runs on machines with `brew install ffmpeg`.
set -eu
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --product WizRec
BIN="$(swift build -c "$CONFIG" --show-bin-path)/WizRec"

ICON=Design/AppIcon/build/AppIcon.icns
[ -f "$ICON" ] || Design/AppIcon/build-icon.sh

APP=build/WizRec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WizRec"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (e.g. WizRec_WizRecAssets.bundle) go in Contents/Resources, where
# the modules' locators look first (Bundle.module would look at the .app root, which breaks codesign).
for b in "$(dirname "$BIN")"/*.bundle; do
    [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

VERSION=${VERSION:-0.1.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# Bundle id is a placeholder until Devs Wizard confirms its domain (see CLAUDE.md "Open decisions").
# Type identifiers are our own imported declarations; the role is Editor (M2) and the
# rank Alternate, so WizRec never claims to be the default app for these files.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>WizRec</string>
    <key>CFBundleIdentifier</key><string>com.devswizard.WizRec</string>
    <key>CFBundleName</key><string>WizRec</string>
    <key>CFBundleDisplayName</key><string>WizRec</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Devs Wizard. GPL-3.0-or-later.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Project Package</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSTypeIsPackage</key><true/>
            <key>LSItemContentTypes</key><array><string>com.devswizard.wizrec.cmproj</string></array>
            <key>CFBundleTypeExtensions</key><array><string>cmproj</string></array>
            <key>NSDocumentClass</key><string>ProjectDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Project File</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.devswizard.wizrec.tscproj</string></array>
            <key>CFBundleTypeExtensions</key><array><string>tscproj</string></array>
            <key>NSDocumentClass</key><string>ProjectDocument</string>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.devswizard.wizrec.source-id</string>
            <key>UTTypeDescription</key><string>WizRec media bin item</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.devswizard.wizrec.effect</string>
            <key>UTTypeDescription</key><string>WizRec library effect</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.devswizard.wizrec.transition</string>
            <key>UTTypeDescription</key><string>WizRec library transition</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.devswizard.wizrec.cmproj</string>
            <key>UTTypeDescription</key><string>Screen recording project package</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>cmproj</string></array></dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.devswizard.wizrec.tscproj</string>
            <key>UTTypeDescription</key><string>Screen recording project</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>tscproj</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Ad-hoc signature so the bundle (with its Info.plist) is sealed for local runs.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed" >&2
echo "built: $APP"
