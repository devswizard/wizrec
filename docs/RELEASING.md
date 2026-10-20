# Releasing WizRec

How a WizRec release is built, signed, notarized and packed. The scripts live in
`scripts/release/` and `scripts/release.sh`; `scripts/make-app.sh` builds the bundle itself.

WizRec is GPL-3.0-or-later. It is distributed as a notarized direct download (DMG), not
through the Mac App Store, whose terms conflict with the GPL.

## Status (2026-10-20)

- **Bundle ID** `com.devswizard.WizRec` (decided 2026-10-20; `WIZREC_BUNDLE_ID` overrides).
- **Sparkle 2** is in the app (approved 2026-10-20). The feed is prepared
  (`release/sparkle.conf`, appcast `release/appcast.xml` on `main`), but the updater stays off
  until the public key is filled in (see "Sparkle: turning updates on").
- **Signing.** No Apple Developer account (DECISIONS 2026-10-20): releases are ad-hoc signed
  and never notarized; users confirm the first launch (README). The Developer ID paths below
  stay for a future account.
- **Publishing** is automated: `release/publish` on `main` → `publish.yml` (see "Publishing
  a release").
- **Still waiting on the user:** the Sparkle key pair (one command, below).

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
strict signature, the embedded `Sparkle.framework`, and the load paths (`otool -L`) and run
paths (`LC_RPATH`, `otool -l`) of **every Mach-O in the bundle**: each must be
`@rpath`/`@loader_path`/`@executable_path` or under `/usr/lib` or `/System`, so nothing points
into Homebrew, `/usr/local`, Xcode or the Command Line Tools. (`WIZREC_ALLOW_BUILD_RPATHS=1`
reports run paths as warnings instead, for DMGs built before bundle-dylibs.sh stripped them:
v0.1.0 carries Xcode's back-deploy run path, which is harmless but untidy.) It then
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
| `WIZREC_SPARKLE_FEED` | `make-app.sh` (`sparkle-info.sh`) | Appcast URL (`https://` only) → `SUFeedURL`; overrides `feed_url` in `release/sparkle.conf`. A feed without a key, or an invalid value, fails the build |
| `WIZREC_SPARKLE_PUBKEY` | `make-app.sh` (`sparkle-info.sh`) | EdDSA public key (base64, 32 bytes) → `SUPublicEDKey`; overrides `public_ed_key` in `release/sparkle.conf`. No key anywhere → updater off |
| `WIZREC_SPARKLE_CONF` | `sparkle-info.sh`, `update-appcast.sh` | Another config file instead of `release/sparkle.conf` |
| `WIZREC_ALLOW_BUILD_RPATHS=1` | `verify-dmg.sh` | Run paths outside the bundle are warnings, not errors (DMGs built before 2026-10-20, e.g. v0.1.0) |
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
| 2 | `scripts/release/bundle-dylibs.sh` | Copies Homebrew FFmpeg **and every transitive dylib** (x264, x265, LAME, dav1d, libvpx, opus, SVT-AV1, OpenSSL, …) into `Contents/Frameworks`, rewrites install names to `@rpath/…`, adds `@executable_path/../Frameworks`, copies each library's licence files into `Contents/Resources/Licenses/<formula>/` with `MANIFEST.txt`, removes run paths into the build machine (`install_name_tool -delete_rpath`: Xcode's Swift back-deploy path `…/XcodeDefault.xctoolchain/usr/lib/swift-6.x/macosx`, Homebrew, `/usr/local`) from the executable and the dylibs before anything is signed, fails if any load or run path still points into Homebrew or a toolchain |
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

**Feed host.** The appcast is `release/appcast.xml` in this repository, served from `main`
by raw.githubusercontent.com:
`https://raw.githubusercontent.com/devswizard/wizrec/main/release/appcast.xml`. Chosen
(2026-10-20) because it needs no web host, no GitHub Pages or other settings change and no
token: updating the feed is an ordinary commit, reviewed and kept in history. The DMGs stay
on the public releases
(`https://github.com/devswizard/wizrec/releases/download/<tag>/WizRec-<version>.dmg`).
The alternative, an `appcast.xml` release asset behind `releases/latest/download/appcast.xml`,
was rejected: every release would have to re-attach the whole history, one release without
the asset breaks the feed, and "latest" moves with each publish. raw.githubusercontent.com
caches for about 5 minutes, which does not matter for update checks. Sparkle verifies every
DMG with the EdDSA key, and `update-appcast.sh` also signs the feed file itself, so the host
is not trusted with integrity.

**Build-time configuration.** One committed file, `release/sparkle.conf`, holds both public
values:

```
feed_url = https://raw.githubusercontent.com/devswizard/wizrec/main/release/appcast.xml
public_ed_key =
```

`scripts/release/sparkle-info.sh` (called by `make-app.sh`) reads it and prints the
Info.plist entries `SUFeedURL` and `SUPublicEDKey`. With `public_ed_key` empty, the committed
state, it prints nothing and the updater stays off, as in v0.1.0. `WIZREC_SPARKLE_FEED` /
`WIZREC_SPARKLE_PUBKEY` in the environment (or as repository variables in CI) override the
file; a feed without a key, a key without a feed, a non-https feed or a key that is not 32
bytes of base64 fails the build.

**Sparkle: turning updates on (once, the user, on the maintainer Mac).** The only manual
step: it creates the private key in the login keychain, which no agent or workflow may do.

1. `swift build` (fetches Sparkle's tools), then:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   It creates the key pair in the login keychain (account `ed25519`) and prints the public
   key; `generate_keys -p` prints it again later.
2. Back up the private key offline (`generate_keys -x <file>`; keep the file somewhere safe
   outside the repository, never commit it). Losing it means existing installs can never
   verify another update.
3. Put the printed public key into `release/sparkle.conf` (`public_ed_key = <key>`), commit
   and push to `main`.
4. Every release built after that commit (tag → `release.yml`) has the updater on.

**Per release, after it is public:**

```sh
scripts/release/update-appcast.sh v0.2.0
git add release/appcast.xml && git commit -m "Appcast: v0.2.0"   # then push to main
```

`update-appcast.sh` downloads the public DMG and `SHA256SUMS.txt` without a token, checks the
sum, reads `CFBundleVersion`, the short version and `LSMinimumSystemVersion` from the app in
the DMG, signs the DMG with Sparkle's `sign_update` (which reads the private key from the
keychain itself; the script never reads, prints or stores it; `SPARKLE_KEY_FILE` passes a key
file on stdin instead), checks the signature against `public_ed_key` with openssl, and fails
on a mismatch or when the app inside carries a different `SUPublicEDKey`. It then writes the
item (download URL, length, `sparkle:edSignature`, release-notes link to the GitHub release),
replacing an earlier item of the same version, newest first, and signs the feed file
(`SIGN_FEED=0` skips that). Re-running it for the same tag leaves one item. Sparkle compares
`CFBundleVersion` (the commit count of `HEAD`), so releases are built from `main`. Checked
2026-10-20 with a throwaway openssl test key (never the keychain) against a local copy of the
DMG: one item after two runs, feed and DMG signatures verify with `sign_update --verify`, a
wrong public key and the committed (empty) key both fail.

**Other host (optional).** For a feed elsewhere, set `feed_url` (or the variables) and use
`scripts/release/appcast.sh`, which runs `generate_appcast` over `build/updates/` (keep
earlier DMGs there) and refuses to sign when the app's `SUPublicEDKey` does not match:

```sh
VERSION=0.2.0 WIZREC_DOWNLOAD_PREFIX=https://<host>/wizrec/ SPARKLE=1 scripts/release.sh
```

In CI, `release.yml` does this when the secret `SPARKLE_ED_PRIVATE_KEY` (the exported key)
and the variables `WIZREC_SPARKLE_FEED`, `WIZREC_DOWNLOAD_PREFIX` exist. Checked 2026-10-20
end to end with a throwaway key: self-signed build, appcast item with `sparkle:edSignature`,
`sign_update --verify` OK.

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
  with the DMG. It never publishes a release or pushes anything.
- `.github/workflows/publish.yml`: turns a draft release public (see "Publishing a
  release"). Runs on a push to `main` that changes `release/publish`, or by hand. Uses only
  the workflow's own `GITHUB_TOKEN` (`contents: write`); no secret or variable to set up.

## Setting up the GitHub remote (user)

The repository has no remote yet. Once the user creates it (e.g. `devswizard/wizrec`):

1. Add it as `origin` and push `main` (decide the git-history rewrite first, see
   `coordination/DECISIONS.md` 2026-10-20).
2. Actions run on their own: `ci.yml` on pushes and pull requests, `release.yml` on `v*` tags,
   `publish.yml` when `release/publish` changes on `main`.
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
3. Review the notes (prefilled from the template; update "What's new" for releases after
   0.1.0, before tagging).
4. Request publication: put the tag on the first non-comment line of `release/publish`,
   commit, and push to `main`. The **Publish release** workflow (`publish.yml`) then runs
   `scripts/release/publish-release.sh <tag>`, which:
   - finds the release by tag (waiting up to 75 minutes for the Release workflow when the
     request is pushed together with the tag);
   - exits 0 if it is already public (idempotent: re-running, or pushing the file again,
     changes nothing);
   - fails if the tag does not exist (publishing would otherwise create it on `main`'s head);
   - fails if the title or notes contain an AI attribution line (`Co-Authored-By:`,
     "Generated with …", Claude, Anthropic, Copilot, ChatGPT, OpenAI, the robot emoji);
   - downloads every asset, checks that each DMG is listed in `SHA256SUMS.txt`, runs
     `shasum -a 256 -c SHA256SUMS.txt` and `scripts/release/verify-dmg.sh` on each DMG
     (mount, signature, load paths, launch with `--quit-after 5`);
   - only then sets `draft: false` (marked latest) and reads the release back.

   The request line may add `allow-build-rpaths` after the tag (`v0.1.0 allow-build-rpaths`):
   `verify-dmg.sh` then reports run paths outside the bundle as warnings. Only for DMGs built
   before 2026-10-20 (v0.1.0 carries Xcode's Swift back-deploy run path); never for a new
   release.

   By hand: *Actions ▸ Publish release ▸ Run workflow*, with an optional tag (default: the
   one in `release/publish`), *dry run* (every check, the draft stays a draft) and *allow
   build run paths*.
   Locally the same script works with any token that has push access:
   `GH_TOKEN=… DRY_RUN=1 scripts/release/publish-release.sh v0.1.0` (curl and python3; no
   `gh`). The token goes to curl through a config on stdin, never on a command line or
   into the log.
5. Check the public asset without a token (next section, "Published releases").

### Verifying a downloaded release asset (no `gh`)

Draft assets are private: listing a draft and downloading its assets needs a token with
push access (`GH_TOKEN`, e.g. a fine-grained token with Contents: read). Published
releases need none: `curl -LO` each asset's `browser_download_url`.

```sh
R=devswizard/wizrec TAG=v0.1.0 D=$(mktemp -d) && cd "$D"
auth=(-H "Authorization: Bearer $GH_TOKEN" -H "X-GitHub-Api-Version: 2022-11-28")
# Drafts have no tag URL yet: find the release by tag in the list.
curl -fsS "${auth[@]}" "https://api.github.com/repos/$R/releases?per_page=20" \
  | python3 -c 'import json,sys; t=sys.argv[1]; r=[x for x in json.load(sys.stdin) if x["tag_name"]==t][0]
for a in r["assets"]: print(a["id"], a["name"])' "$TAG" \
  | while read -r id name; do
      curl -fsSL "${auth[@]}" -H "Accept: application/octet-stream" -o "$name" \
        "https://api.github.com/repos/$R/releases/assets/$id"
    done
shasum -a 256 -c SHA256SUMS.txt
"$OLDPWD/scripts/release/verify-dmg.sh" WizRec-*.dmg   # mount, checks, --quit-after 5
```

Without a token, download the same DMG from the Release run's workflow artifact (also needs
sign-in) or rebuild from the tag (check out `v0.1.0`, then `VERIFY=1 scripts/release.sh`).
`curl` sets no quarantine flag, so this does not exercise the Gatekeeper first-launch
prompt; for that, download in a browser and open it from Finder.

**Published releases** need no token: the assets have fixed URLs.

```sh
TAG=v0.1.0 V=0.1.0 D=$(mktemp -d)
U=https://github.com/devswizard/wizrec/releases/download/$TAG
(cd "$D" && curl -fsSLO "$U/WizRec-$V.dmg" && curl -fsSLO "$U/SHA256SUMS.txt" \
  && shasum -a 256 -c SHA256SUMS.txt)
scripts/release/verify-dmg.sh "$D/WizRec-$V.dmg"
```
