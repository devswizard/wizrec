#!/bin/sh
# Refreshes Localization/Localizable.xcstrings (String Catalog) from the app's sources:
# SwiftUI literals (Text, Button, Toggle, …) and String(localized:) calls.
# Translators edit the catalog in Xcode; scripts/make-app.sh compiles it into the app.
set -eu
cd "$(dirname "$0")/.."
CAT=Localization/Localizable.xcstrings
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
[ -f "$CAT" ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$CAT"
xcrun xcstringstool extract --SwiftUI --modern-localizable-strings Sources/WizRecApp/*.swift -o "$OUT"
xcrun xcstringstool sync "$CAT" --stringsdata "$OUT"/*.stringsdata
echo "updated: $CAT ($(xcrun xcstringstool print "$CAT" | wc -l | tr -d ' ') lines)"
