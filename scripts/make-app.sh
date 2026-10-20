#!/bin/sh
# Builds the WizRec player in release mode and wraps it into build/WizRec.app.
#
#   scripts/make-app.sh            # → build/WizRec.app
#   build/WizRec.app/Contents/MacOS/WizRec "<project.cmproj>" [--autoplay] [--overlay] [--stats-log]
#
# FFmpeg is linked from Homebrew here, so this bundle runs on machines with
# `brew install ffmpeg`; scripts/release.sh bundles it for distribution.
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
# Sparkle (MIT, app updates): SwiftPM builds it as a framework next to the binary. It goes to
# Contents/Frameworks (symlinks preserved) and the executable finds it through the
# @executable_path/../Frameworks run path. scripts/release/sign.sh re-signs it inside out.
SPARKLE_FW="$(dirname "$BIN")/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
fi
if ! otool -l "$APP/Contents/MacOS/WizRec" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/WizRec"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (e.g. WizRec_WizRecAssets.bundle) go in Contents/Resources, where
# the modules' locators look first (Bundle.module would look at the .app root, which breaks codesign).
for b in "$(dirname "$BIN")"/*.bundle; do
    [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# String Catalog → <lang>.lproj/Localizable.strings(dict) for every translated language
# (refresh the catalog with scripts/update-strings.sh). English is the development language.
if [ -f Localization/Localizable.xcstrings ]; then
    xcrun xcstringstool compile Localization/Localizable.xcstrings -o "$APP/Contents/Resources"
fi
mkdir -p "$APP/Contents/Resources/en.lproj"
LOCALIZATIONS=""
for l in "$APP"/Contents/Resources/*.lproj; do
    LOCALIZATIONS="$LOCALIZATIONS<string>$(basename "$l" .lproj)</string>"
done

VERSION=${VERSION:-0.1.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# Bundle id: com.devswizard.WizRec (DECISIONS 2026-10-20); WIZREC_BUNDLE_ID overrides it.
BUNDLE_ID=${WIZREC_BUNDLE_ID:-com.devswizard.WizRec}
# Sparkle feed + EdDSA public key from WIZREC_SPARKLE_FEED / WIZREC_SPARKLE_PUBKEY; empty when
# unset (the updater then stays off). Fails on a half or invalid configuration.
SPARKLE_KEYS=$(scripts/release/sparkle-info.sh)
# Type identifiers are our own imported declarations; the role is Editor (M2) and the
# rank Alternate, so WizRec never claims to be the default app for these files.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array>$LOCALIZATIONS</array>
    <key>NSCameraUsageDescription</key><string>WizRec records your camera when you include it in a recording.</string>
    <key>NSMicrophoneUsageDescription</key><string>WizRec records your microphone when you include it in a recording.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>WizRec transcribes your clips' audio to create captions. Audio is processed on this Mac.</string>
    <key>CFBundleExecutable</key><string>WizRec</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
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
$SPARKLE_KEYS
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
