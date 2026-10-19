# Releasing WizRec

How a WizRec release is built, signed, notarized and packed. The scripts live in
`scripts/release/` and `scripts/release.sh`; `scripts/make-app.sh` builds the bundle itself.

WizRec is GPL-3.0-or-later. It is distributed as a notarized direct download (DMG), not
through the Mac App Store, whose terms conflict with the GPL.

## Status (2026-10-19)

Releases are ad-hoc signed only. Still waiting on the user: the GitHub remote, a Developer ID
certificate and notary credentials, the final bundle ID, and approval for Sparkle. The
scripts and workflows below already work without them and pick them up from the environment
(or repository secrets/variables) once they exist; nothing needs editing.

## Prerequisites

```sh
brew install ffmpeg pkg-config librsvg   # librsvg: rsvg-convert for the app icon
```

## Quick start

```sh
scripts/release.sh                       # ad-hoc signed build/WizRec-0.1.0.dmg, local testing only
```

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
| `WIZREC_BUNDLE_ID` | `make-app.sh` | `CFBundleIdentifier`; default is the placeholder `com.devswizard.WizRec` until the bundle ID is decided |
| `WIZREC_SIGN_IDENTITY` | `sign.sh` | Codesign identity in the keychain; unset → ad-hoc (`-`) |
| `NOTARIZE=1` | `release.sh` | Notarize and staple app and DMG. Without `WIZREC_SIGN_IDENTITY` it is skipped with a warning (ad-hoc builds cannot be notarized) |
| `WIZREC_NOTARY_PROFILE` | `notarize.sh` | `notarytool` keychain profile name; required when notarizing |
| `SPARKLE=1`, `SPARKLE_BIN` | `appcast.sh` | Appcast generation (planned, see below) |
| `DRY_RUN=1` | `sign.sh`, `notarize.sh` | Print commands only |

## Steps

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/make-app.sh` (`CONFIG=release`) | `swift build -c release`, wraps `build/WizRec.app`, copies SwiftPM resource bundles (fonts) into `Contents/Resources` |
| 2 | `scripts/release/bundle-dylibs.sh` | Copies Homebrew FFmpeg **and every transitive dylib** (x264, x265, LAME, dav1d, libvpx, opus, SVT-AV1, OpenSSL, …) into `Contents/Frameworks`, rewrites install names to `@rpath/…`, adds `@executable_path/../Frameworks`, copies each library's licence files into `Contents/Resources/Licenses/<formula>/` with `MANIFEST.txt`, fails if anything still points into `/opt/homebrew` |
| 3 | `scripts/release/sign.sh` | Signs the dylibs, then the app. Real identity: hardened runtime, timestamp, `WizRec.entitlements` (camera, microphone). No identity: ad-hoc |
| 4 | `scripts/release/notarize.sh` | `notarytool submit --wait` with a keychain profile, then `stapler staple` and `spctl` |
| 5 | `scripts/release/make-dmg.sh` | UDZO image with the app, an `/Applications` link, `LICENSE.txt` and `THIRD_PARTY_NOTICES.md` |
| 6 | `sign.sh` + `notarize.sh` on the DMG | Only with a real identity |
| 7 | `scripts/release/appcast.sh` | Only with `SPARKLE=1` (see below) |

## Secrets

Nothing secret is stored in the repository, passed on a command line or printed.

- **Signing identity.** `WIZREC_SIGN_IDENTITY` names a certificate already in the keychain.
  In CI, a temporary keychain is created from repository secrets (`.github/workflows/release.yml`).
- **Notarization.** `WIZREC_NOTARY_PROFILE` names a `notarytool` keychain profile, created once:

  ```sh
  xcrun notarytool store-credentials wizrec-notary --apple-id <apple-id> --team-id <TEAMID>
  ```

  It prompts for an app-specific password and keeps it in the keychain.
- **Sparkle key.** The EdDSA private key stays in the maintainer's keychain (`generate_keys`).

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

## Sparkle (planned, behind `SPARKLE=1`)

[Sparkle 2](https://sparkle-project.org) (MIT) is the update mechanism. Status: the release
script can already write an appcast; the app does not contain the updater yet.

Plan:

1. **Dependency.** Add `https://github.com/sparkle-project/Sparkle` (SwiftPM, MIT, GPL-compatible)
   to `WizRecApp` only. Needs the lead's approval (new dependency).
2. **App.** An `SPUStandardUpdaterController` owned by the app delegate; menu item
   *WizRec ▸ Check for Updates…*; preference "Check automatically" (off until the user opts in).
   Info.plist: `SUFeedURL` (the appcast URL), `SUPublicEDKey` (public key, not secret),
   `SUEnableInstallerLauncherService` not needed (not sandboxed).
3. **Build flag.** Compile the updater only when `WIZREC_SPARKLE` is defined
   (`swiftSettings: [.define("WIZREC_SPARKLE", .when(configuration: .release))]` or an
   environment-driven package condition), so debug builds and CI never phone home.
4. **Bundling.** `Sparkle.framework` goes to `Contents/Frameworks`; `sign.sh` already signs
   `*.framework` there (Sparkle's XPC services must be signed inside out — use Sparkle's
   documented `codesign` order when this lands).
5. **Publishing.** `SPARKLE_BIN=<Sparkle>/bin SPARKLE=1 scripts/release.sh` copies the DMG
   to `build/updates/` and runs `generate_appcast`, which signs each item with the EdDSA key
   from the keychain. Upload `appcast.xml` and the DMG to the release host
   (`WIZREC_DOWNLOAD_PREFIX`).

## CI

- `.github/workflows/ci.yml`: build and test on every push to `main` and on pull requests
  (macOS arm64, Homebrew `ffmpeg` + `pkg-config`, newest stable Xcode). It also checks that
  the shell scripts parse. Golden, perf, capture, speech and whisper suites stay off; tests
  needing the user's projects or Camtasia skip. The asset audit runs as part of `swift test`.
  Nothing runs until the repository has a GitHub remote.
- `.github/workflows/release.yml`: on a `v*` tag or by hand. Builds an ad-hoc signed DMG and
  uploads it as a workflow artifact. When the repository has the secrets
  `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY` (and, for notarization,
  `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`), it signs with a temporary keychain
  and notarizes. Without them it never fails for lack of credentials. The repository
  variable (not secret) `WIZREC_BUNDLE_ID`, when set, overrides the placeholder bundle ID.
