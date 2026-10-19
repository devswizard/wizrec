#!/bin/sh
# Renders AppIcon.svg into AppIcon.icns, a 1024 px preview, and an Xcode
# AppIcon.appiconset. Needs rsvg-convert (brew install librsvg) and iconutil.
set -eu
cd "$(dirname "$0")"

SVG=AppIcon.svg
OUT=build
rm -rf "$OUT"
mkdir -p "$OUT/AppIcon.iconset" "$OUT/AppIcon.appiconset"

# Each size is rendered from the vector source rather than downscaled.
# 32 px and below use the simplified glyph; the full artwork turns to noise there.
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
            256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    px=${spec%%:*}
    name=${spec#*:}
    src=$SVG
    [ "$px" -le 32 ] && src=AppIcon-small.svg
    rsvg-convert -w "$px" -h "$px" "$src" -o "$OUT/AppIcon.iconset/icon_$name.png"
    cp "$OUT/AppIcon.iconset/icon_$name.png" "$OUT/AppIcon.appiconset/icon_$name.png"
done

iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
cp "$OUT/AppIcon.iconset/icon_512x512@2x.png" "$OUT/AppIcon-1024.png"

cat > "$OUT/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "built: $OUT/AppIcon.icns, $OUT/AppIcon-1024.png, $OUT/AppIcon.appiconset"
