# Releasing WizRec

How a WizRec release is built, signed, notarized and packed. The scripts live in
`scripts/release/` and `scripts/release.sh`; `scripts/make-app.sh` builds the bundle itself.

WizRec is GPL-3.0-or-later. It is distributed as a notarized direct download (DMG), not
through the Mac App Store, whose terms conflict with the GPL.

## Status (2026-10-20)

- **Bundle ID** `com.devswizard.WizRec` (decided 2026-10-20; `WIZREC_BUNDLE_ID` overrides).
- **Sparkle 2** is in the app (approved 2026-10-20). The updater is off unless the build sets
  a feed URL and public key (see "Sparkle").
- **Signing.** No Developer ID exists yet. Local releases are ad-hoc or signed with the
  self-signed "WizRec Dev" identity (no hardened runtime, no notarization); they run on this
  Mac, and elsewhere only after the user overrides Gatekeeper.
- **Still waiting on the user:** the GitHub remote, a Developer ID Application certificate
  and a notary profile, and the update host (feed + download URLs) and Sparkle key pair. The
  scripts and workflows already work without them and pick them up from the environment (or
  repository secrets/variables) once they exist; nothing needs editing.

## Prerequisites

```sh
brew install ffmpeg pkg-config librsvg   # librsvg: rsvg-convert for the app icon
```

## Quick start

```sh
scripts/release.sh                       # ad-hoc signed build/WizRec-0.1.0.dmg, local testing only
VERIFY=1 WIZREC_SIGN_IDENTITY="WizRec Dev" scripts/release.sh   # self-signed + smoke test
scripts/release/verify-dmg.sh build/WizRec-0.1.0.dmg            # smoke-test an existing DMG
```

`verify-dmg.sh` mounts the image read-only (hidden from Finder), checks the bundle ID, the
strict signature, the embedded `Sparkle.framework` and that nothing links into Homebrew, then
launches the app from the image with `--quit-after 5` and expects a clean exit. Measured
2026-10-20: 21 MB DMG, launch-and-quit in 6–7 s, both ad-hoc and "WizRec Dev". On macOS 27
with `diskutil image` (APFS, ULFO): 20.9 MB (UDZO via hdiutil: 22.1 MB), launch-and-quit
in 5–7 s, no deprecation warnings; every make/verify tool combination passes.

A signed, notarized release (maintainer machine):

```sh
VERSION=0.2.0 \
WIZREC_SIGN_IDENTITY="Developer ID Application: Devs Wizard (TEAMID)" \
NOTARIZE=1 WIZREC_NOTARY_PROFILE=wizrec-notary \
scripts/release.sh
```

Add `DRY_RUN=1` to print the `codesign`/`notarytool` commands without running them.

## Environment

Every input is optional; with none set the result is an ad-hoc signed DMG.

| Variable | Used by | Meaning |
|---|---|---|
| `VERSION` | `release.sh`, `make-app.sh` | Marketing version (default `0.1.0`) |
| `WIZREC_BUNDLE_ID` | `make-app.sh`, `verify-dmg.sh` | `CFBundleIdentifier`; default `com.devswizard.WizRec` |
| `WIZREC_SIGN_IDENTITY` | `sign.sh` | Codesign identity in the keychain; unset → ad-hoc (`-`). `Developer ID Application: …` → hardened runtime, timestamp, entitlements. Any other identity (self-signed "WizRec Dev") → plain signature, because library validation needs a Team ID |
| `WIZREC_HARDENED=1` | `sign.sh` | Force hardened runtime for a non-Developer-ID identity |
| `WIZREC_SPARKLE_FEED` | `make-app.sh` (`sparkle-info.sh`) | Appcast URL (`https://` only) → `SUFeedURL`. Set both Sparkle values or neither; one alone or an invalid value fails the build |
| `WIZREC_SPARKLE_PUBKEY` | `make-app.sh` (`sparkle-info.sh`) | EdDSA public key (base64, 32 bytes) → `SUPublicEDKey` |
| `NOTARIZE=1` | `release.sh` | Notarize and staple app and DMG. Without `WIZREC_SIGN_IDENTITY` it is skipped with a warning (ad-hoc builds cannot be notarized) |
| `WIZREC_NOTARY_PROFILE` | `notarize.sh` | `notarytool` keychain profile name; required when notarizing |
| `SPARKLE=1` | `release.sh` | Write a signed appcast after the DMG (`appcast.sh`) |
| `WIZREC_DOWNLOAD_PREFIX` | `appcast.sh` | `https://…/` URL the DMG is served from (required with `SPARKLE=1`) |
| `SPARKLE_KEY_FILE`, `SPARKLE_ACCOUNT` | `appcast.sh` | Private key from a file (CI) instead of the login keychain; keychain account name |
| `SPARKLE_BIN`, `SPARKLE_OUT` | `appcast.sh` | Sparkle tools (default: SwiftPM artifact `.build/artifacts/sparkle/Sparkle/bin`); output folder (default `build/updates`) |
| `VERIFY=1` | `release.sh` | Run `verify-dmg.sh` on the finished DMG |
| `WIZREC_DMG_TOOL` | `make-dmg.sh`, `verify-dmg.sh` | `auto` (default), `diskutil` or `hdiutil`. `auto` uses `diskutil image` where it exists (macOS 27 deprecates `hdiutil create/attach/detach`) and falls back to `hdiutil` (older macOS, CI runners without it) |
| `DRY_RUN=1` | `sign.sh`, `notarize.sh` | Print commands only |

## Steps

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/make-app.sh` (`CONFIG=release`) | `swift build -c release`, wraps `build/WizRec.app`, copies SwiftPM resource bundles (fonts) into `Contents/Resources`, embeds `Sparkle.framework` in `Contents/Frameworks` (+ `@executable_path/../Frameworks` run path, Sparkle licence), writes the Sparkle keys into Info.plist when set |
| 2 | `scripts/release/bundle-dylibs.sh` | Copies Homebrew FFmpeg **and every transitive dylib** (x264, x265, LAME, dav1d, libvpx, opus, SVT-AV1, OpenSSL, …) into `Contents/Frameworks`, rewrites install names to `@rpath/…`, adds `@executable_path/../Frameworks`, copies each library's licence files into `Contents/Resources/Licenses/<formula>/` with `MANIFEST.txt`, fails if anything still points into `/opt/homebrew` |
| 3 | `scripts/release/sign.sh` | Signs the dylibs, then Sparkle inside out (`Installer.xpc`, `Downloader.xpc` keeping its entitlements, `Autoupdate`, `Updater.app`, the framework), then the app. Developer ID: hardened runtime, timestamp, `WizRec.entitlements` (camera, microphone). Self-signed: plain. No identity: ad-hoc |
| 4 | `scripts/release/notarize.sh` | `notarytool submit --wait` with a keychain profile, then `stapler staple` and `spctl` |
| 5 | `scripts/release/make-dmg.sh` | Read-only image with the app, an `/Applications` link, `LICENSE.txt` and `THIRD_PARTY_NOTICES.md`: `diskutil image create from` (APFS, lzfse `ULFO`) where available, else `hdiutil create` (HFS+, zlib `UDZO`); checksum-verified with `hdiutil verify` (not deprecated) |
| 6 | `sign.sh` + `notarize.sh` on the DMG | Only with a real identity |
| 7 | `scripts/release/verify-dmg.sh` | Only with `VERIFY=1`: mount, check, launch `--quit-after 5` |
| 8 | `scripts/release/appcast.sh` | Only with `SPARKLE=1` (see below) |

## Secrets

Nothing secret is stored in the repository, passed on a command line or printed.

- **Signing identity.** `WIZREC_SIGN_IDENTITY` names a certificate already in the keychain.
  In CI, a temporary keychain is created from repository secrets (`.github/workflows/release.yml`).
- **Notarization.** `WIZREC_NOTARY_PROFILE` names a `notarytool` keychain profile, created once:

  ```sh
  xcrun notarytool store-credentials wizrec-notary --apple-id <apple-id> --team-id <TEAMID>
  ```

  It prompts for an app-specific password and keeps it in the keychain.
- **Sparkle key.** The EdDSA private key stays in the maintainer's login keychain
  (`generate_keys`), or, for CI, in the repository secret `SPARKLE_ED_PRIVATE_KEY`. Only
  the public key goes into the app.

## Licences of bundled libraries

Homebrew's `ffmpeg` is built with GPL components (x264, x265), which is compatible with
WizRec's GPL-3.0-or-later. Each release must ship:

- the GPL-3.0 text (`LICENSE`, also in the DMG);
- `THIRD_PARTY_NOTICES.md` (FFmpeg, LAME, the other codec libraries, fonts);
- `Contents/Resources/Licenses/` from `bundle-dylibs.sh` (per-library licence files and the
  manifest with each formula's version and SPDX licence);
- a way to get the corresponding source: WizRec's own source (the public repository at the
  release tag), and for each bundled library its upstream source at the manifest version
  (Homebrew formula URLs). The GPL's written-offer duty is met by linking these in the
  release notes.

Before each release, compare `MANIFEST.txt` with `THIRD_PARTY_NOTICES.md`: a new formula
in the manifest needs a notices entry, and any `UNKNOWN` licence must be resolved by hand.

## Architecture

Release builds are arm64 only: the bundled dylibs come from the arm64 Homebrew prefix. A
universal build needs an x86_64 FFmpeg (a second Homebrew prefix or our own FFmpeg build)
merged with `lipo`; not planned for 0.x.

## Sparkle (updates)

[Sparkle 2](https://sparkle-project.org) (MIT) is the update mechanism. It is a SwiftPM
dependency of the `WizRecApp` target only (`Package.swift`, pinned in `Package.resolved`).

**In the app.** `AppUpdater` (WizRecApp) owns an `SPUStandardUpdaterController` and the menu
item *WizRec ▸ Check for Updates…*. `UpdaterConfiguration` (PlayerKit, unit-tested) decides
from Info.plist whether it may start: it needs an `https` `SUFeedURL` and a 32-byte base64
`SUPublicEDKey`, and the app must run from a `.app` bundle. Otherwise nothing starts, nothing
touches the network, the menu item is disabled, and one line goes to stderr. Scripted runs
(`--quit-after`) never start it. Sparkle itself asks the user on the second launch whether to
check automatically, so update checks are opt-in.

**Build-time configuration.** The feed URL and the public key come from the environment:

```sh
WIZREC_SPARKLE_FEED=https://<host>/wizrec/appcast.xml \
WIZREC_SPARKLE_PUBKEY=<base64 public key> \
scripts/release.sh
```

`scripts/release/sparkle-info.sh` validates them and prints the Info.plist entries; with
neither set the build has no updater keys. In CI they are repository **variables** (public
values), not secrets.

**Key generation (once, maintainer machine).** Sparkle's tools come with the SwiftPM
artifact after `swift build`:

```sh
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
$SPARKLE_BIN/generate_keys            # creates the key pair in the login keychain, prints the public key
$SPARKLE_BIN/generate_keys -p         # prints the public key again
$SPARKLE_BIN/generate_keys -x sparkle-private.key   # export for CI or a backup; never commit it
```

Keep an offline backup of the private key: losing it means existing installs can no longer
verify updates. For CI, store the exported file's content as the secret
`SPARKLE_ED_PRIVATE_KEY`, then delete the file.

**Appcast generation.**

```sh
VERSION=0.2.0 \
WIZREC_SPARKLE_FEED=https://<host>/wizrec/appcast.xml WIZREC_SPARKLE_PUBKEY=<public key> \
WIZREC_DOWNLOAD_PREFIX=https://<host>/wizrec/ SPARKLE=1 \
scripts/release.sh
```

`scripts/release/appcast.sh` copies the DMG into `build/updates/` (keep earlier DMGs there
for the release history) and runs `generate_appcast`, which signs each item with the private
key from the keychain (or `SPARKLE_KEY_FILE`, read from stdin) and refuses to sign when the
app's `SUPublicEDKey` does not match the key. Upload `appcast.xml` to the feed URL and the DMG
under the download prefix. Sparkle compares `CFBundleVersion` (the commit count of `HEAD`),
so build releases from `main`. Checked 2026-10-20 end to end with a throwaway key:
self-signed build, appcast item with `sparkle:edSignature`, `sign_update --verify` OK.

**Signing order.** `sign.sh` re-signs Sparkle's helpers inside out before the app (see
step 3). With a Developer ID the hardened runtime applies to them too, as Sparkle documents
for non-sandboxed apps.

**Offline builds.** After the first resolve, SwiftPM keeps Sparkle's binary artifact in
`.build/artifacts` and its cache, and `swift build` works without network.

## CI

- `.github/workflows/ci.yml`: build and test on every push to `main` and on pull requests
  (macOS arm64, Homebrew `ffmpeg` + `pkg-config`, newest stable Xcode, Sparkle resolved from
  `Package.resolved` with retries). It also checks that
  the shell scripts parse. Golden, perf, capture, speech and whisper suites stay off; tests
  needing the user's projects or Camtasia skip. The asset audit runs as part of `swift test`.
  Actions use their Node 24 majors (`checkout@v7`, `cache@v6`, `upload-artifact@v7`).
- `.github/workflows/release.yml`: on a `v*` tag or by hand. Builds an ad-hoc signed DMG and
  uploads it as a workflow artifact. When the repository has the secrets
  `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY` (and, for notarization,
  `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`), it signs with a temporary keychain
  and notarizes. Without them it never fails for lack of credentials. Every run smoke-tests
  the DMG (`VERIFY=1`). Repository **variables** (public): `WIZREC_BUNDLE_ID` (overrides the
  default), `WIZREC_SPARKLE_FEED`, `WIZREC_SPARKLE_PUBKEY`, `WIZREC_DOWNLOAD_PREFIX`. With the
  secret `SPARKLE_ED_PRIVATE_KEY` as well, it writes a signed `appcast.xml` and uploads it
  with the DMG. The workflow never publishes or pushes anything.

## Setting up the GitHub remote (user)

The repository has no remote yet. Once the user creates it (e.g. `devswizard/wizrec`):

1. Add it as `origin` and push `main` (decide the git-history rewrite first, see
   `coordination/DECISIONS.md` 2026-10-20).
2. Actions run on their own: `ci.yml` on pushes and pull requests, `release.yml` on `v*` tags.
3. Signing (when a Developer ID exists): secrets `MACOS_CERT_P12` (base64 `.p12`),
   `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`; notarization: `NOTARY_APPLE_ID`,
   `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (app-specific password).
4. Updates: variables `WIZREC_SPARKLE_FEED`, `WIZREC_SPARKLE_PUBKEY`,
   `WIZREC_DOWNLOAD_PREFIX`; secret `SPARKLE_ED_PRIVATE_KEY`.

## Publishing a release (GitHub)

No Apple Developer account: releases are ad-hoc signed and never notarized.

1. Bump the version if needed, commit, then tag and push: `git tag v0.1.0 && git push
   origin v0.1.0`.
2. The Release workflow builds the DMG (FFmpeg and Sparkle inside, so users install
   nothing else), runs the DMG smoke test, and attaches `WizRec-<version>.dmg` and
   `SHA256SUMS.txt` to a **draft** GitHub Release using `docs/release-notes-template.md`.
3. Fill in "What's new" on the draft and publish it.
