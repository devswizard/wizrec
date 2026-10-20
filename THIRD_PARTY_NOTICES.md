# Third-party notices

WizRec is © 2026 Devs Wizard and released under the GNU General Public License v3.0 or
later ([LICENSE](LICENSE)). It includes or links the components below, each under its own
licence. All are compatible with GPL-3.0-or-later.

Camtasia is a trademark of TechSmith Corporation, used only to describe file compatibility.
WizRec contains no TechSmith code, binaries or assets.

## Libraries bundled in release builds

Release builds (`scripts/release.sh`) copy these dynamic libraries from Homebrew into
`WizRec.app/Contents/Frameworks`, unmodified. Each library's licence files and an exact
manifest (file, formula, version, SPDX licence) are in
`WizRec.app/Contents/Resources/Licenses/`. Source code for each is available from its
project at the version in that manifest, and from the Homebrew formula that built it.
Versions below are those of the 2026-10-19 build environment.

| Library | Files | Version | Licence | Source |
|---|---|---|---|---|
| FFmpeg (libavcodec, libavformat, libavutil, libswresample, libswscale) | `libav*.dylib`, `libsw*.dylib` | 9.0.2 | GPL-3.0-or-later as built by Homebrew (enables GPL components); FFmpeg's own code is LGPL-2.1-or-later | https://ffmpeg.org/ |
| x264 | `libx264.165.dylib` | r3222 | GPL-2.0-or-later | https://www.videolan.org/developers/x264.html |
| x265 | `libx265.217.dylib` | 4.3 | GPL-2.0-or-later | https://github.com/Multicorewareinc/x265 |
| LAME (MP3 encoder) | `libmp3lame.0.dylib` | 4.0 | LGPL-2.0-or-later | https://lame.sourceforge.io/ |
| mpg123 | `libmpg123.0.dylib` | 1.33.7 | LGPL-2.1-only | https://www.mpg123.de/ |
| dav1d | `libdav1d.7.dylib` | 1.5.4 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |
| libvpx | `libvpx.12.dylib` | 1.17.0 | BSD-3-Clause | https://www.webmproject.org/code/ |
| Opus | `libopus.0.dylib` | 1.6.1 | BSD-3-Clause | https://www.opus-codec.org/ |
| SVT-AV1 | `libSvtAv1Enc.4.dylib` | 4.2.0 | BSD-3-Clause | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| OpenSSL | `libssl.4.dylib`, `libcrypto.4.dylib` | 4.0.3 | Apache-2.0 | https://openssl-library.org |
| XZ Utils (liblzma) | `liblzma.5.dylib` | 5.8.4 | 0BSD (liblzma) | https://tukaani.org/xz/ |

If a future build bundles a library that is not listed here, `bundle-dylibs.sh` records it
in the manifest; add it to this table before publishing (see `docs/RELEASING.md`).

Development builds (`swift build`, `scripts/make-app.sh`) link the same libraries from the
local Homebrew installation instead of bundling them.

## Fonts

Bundled in `Sources/WizRecAssets/Resources/Fonts/` and in the app, unmodified, from the
[google/fonts](https://github.com/google/fonts) repository (`ofl/` folder, branch `main`,
downloaded 2026-10-19). Each family is licensed under the
[SIL Open Font License 1.1](https://openfontlicense.org); its licence file sits next to the
font. Variable fonts were renamed only to drop the `[wght]` brackets from the file name.

| Family | Bundled file | Upstream path | Copyright | SHA-256 |
|---|---|---|---|---|
| Montserrat | `Montserrat-wght.ttf` | `ofl/montserrat/Montserrat[wght].ttf` | The Montserrat Project Authors | `0f7b311b2f3279e4eef9b2f968bcdbab6e28f4daeb1f049f4f278a902bcd82f7` |
| Montserrat | `Montserrat-OFL.txt` | `ofl/montserrat/OFL.txt` | | `8b7141c03fa4f8d44e6345d5d4931709290f0f67875e452e95ac1fd3a027802e` |
| Lato | `Lato-Regular.ttf` | `ofl/lato/Lato-Regular.ttf` | Łukasz Dziedzic, Reserved Font Name "Lato" | `d636e4683231f931eda222d588e944d082bfd3bdba02f928bee461c0f185b251` |
| Lato | `Lato-Bold.ttf` | `ofl/lato/Lato-Bold.ttf` | Łukasz Dziedzic, Reserved Font Name "Lato" | `8a0aace75d33794eece4b28187bfc1df0bbd2888b5d8a56e01788c8d65d16be1` |
| Lato | `Lato-OFL.txt` | `ofl/lato/OFL.txt` | | `74ba064d03f1f1c4a952da936c3eb71866c34404916734de3cae73b34357e59e` |
| Bebas Neue | `BebasNeue-Regular.ttf` | `ofl/bebasneue/BebasNeue-Regular.ttf` | The Bebas Neue Project Authors | `08e4623805102d819f58601e46e345648846075e363b2ceb23313c2d1c83ec73` |
| Bebas Neue | `BebasNeue-OFL.txt` | `ofl/bebasneue/OFL.txt` | | `72082f6cb4d04be2ecf7cc7d9e1e7d73787f0af8a5a278a47cade70c16b78341` |
| Caveat | `Caveat-wght.ttf` | `ofl/caveat/Caveat[wght].ttf` | The Caveat Project Authors | `0bdb6b660482d31531b3945849fba5916b3ef8695da7024a9e6b9ee3c4157988` |
| Caveat | `Caveat-OFL.txt` | `ofl/caveat/OFL.txt` | | `1f9d81d094273d82f3898a1ee8b598a717d050ecbf5ff7bede105b704880157b` |

`WizRecAssetsTests` checks the font hashes, so a modified or replaced file fails the tests.

## Original assets

Everything else in `Sources/WizRecAssets` (backgrounds, transitions, callout presets, cursor
and click-effect artwork) and `Design/AppIcon` is original work by Devs Wizard, under
GPL-3.0-or-later.

## Optional tools the user installs (not bundled)

WizRec can transcribe captions with [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
(MIT). It is never linked or shipped: WizRec runs the user's own `whisper-cli` executable
(e.g. `brew install whisper.cpp`) as a separate process, with model files the user puts in
`~/Library/Application Support/WizRec/models/`. Tested 2026-10-20 with:

| Item | File | Version | Licence | Size, bytes | SHA-256 |
|---|---|---|---|---|---|
| whisper.cpp CLI | `whisper-cli` (Homebrew `whisper.cpp`) | 1.9.5 | MIT | | |
| Speech model | `ggml-small.bin` (ggml-org/whisper.cpp models) | small | MIT | 487601967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |
| Silero VAD model | `ggml-silero-v5.1.2.bin` (huggingface.co/ggml-org/whisper-vad) | 5.1.2 | MIT | 885098 | `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf` |

When a `ggml-silero-*.bin` file is present, WizRec passes it to `whisper-cli --vad` (setting
`captions.whisper.vad`, on by default); it is not offered as a transcription model.

## Planned

- **Sparkle** (MIT), the update framework, once it is added (`docs/RELEASING.md`).
