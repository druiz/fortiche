---
name: fortiche-appstore-and-release
description: >
  Ship Fortiche to TestFlight and the App Store: run/modify Scripts/release.sh
  (xcodebuild archive + exportArchive with cloud signing and an App Store
  Connect API key), edit AppStore/ExportOptions.plist, bump MARKETING_VERSION,
  regenerate the App Store screenshots (iPhone 6.9-inch 1320x2868 and watch
  422x514 via demo launch args), maintain AppStore/metadata and
  review-notes.md, verify PRIVACY.md is publicly reachable, answer the App
  Privacy questionnaire
  ("Data Not Collected"), and decide what may be claimed publicly about the
  app. Load this skill for anything involving TestFlight, App Store Connect,
  release builds, screenshots, app metadata, privacy policy, review notes, or
  marketing/positioning claims.
---

# Fortiche: App Store and release

Everything needed to take a green build from this repo to TestFlight and,
eventually, the App Store — and to keep the store-facing artifacts
(`AppStore/`, `PRIVACY.md`) truthful.

Facts below were verified against the repo on 2026-07-05. Volatile ones are
date-stamped; re-verification one-liners are at the bottom.

## When NOT to use this skill

- Building or testing locally, toolchain/SDK setup, `xcodegen` mechanics →
  **fortiche-build-and-env**.
- Running the app in simulators, the full launch-arg catalog, simulator
  gotchas (icon caching, log flags, watch-app install flakiness) →
  **fortiche-run-and-operate**.
- Deciding whether a change is allowed at all, or what review it needs →
  **fortiche-change-control**.
- What evidence a release candidate needs before you upload →
  **fortiche-validation-and-qa**.
- Why the privacy architecture is the way it is (no server, CloudKit private
  DB, on-device parsing) → **fortiche-architecture-contract**.
- Claims about the AI parsing pipeline itself → **fortiche-intelligence-reference**.
- Unproven future features you might be tempted to market →
  **fortiche-research-frontier**.

## Map of release-relevant files

| Path | What it is |
|---|---|
| `Scripts/release.sh` | Archive + upload to App Store Connect (TestFlight) |
| `AppStore/ExportOptions.plist` | exportArchive options: upload, cloud signing, team |
| `AppStore/metadata/en-US/description.txt` | App Store description (paste into ASC) |
| `AppStore/metadata/en-US/misc.txt` | Name, subtitle, keywords, categories, price, age rating, URLs, release notes |
| `AppStore/review-notes.md` | Reviewer test script + privacy questionnaire answers |
| `AppStore/screenshots/iphone-6.9/` | 4 iPhone screenshots, 1320x2868 |
| `AppStore/screenshots/watch/` | 2 watch screenshots, 422x514 |
| `PRIVACY.md` | Privacy policy — must be HOSTED at a public URL before submission |
| `project.yml` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, entitlements, usage strings, `ITSAppUsesNonExemptEncryption` |

There is no ASC-automation tooling (no fastlane). Metadata is applied by
pasting from `AppStore/metadata/` into App Store Connect by hand; the files in
the repo are the source of truth, so edit them first, then mirror into ASC.

## 1. The release pipeline: `Scripts/release.sh`

One script, two `xcodebuild` invocations, zero local certificates.

```sh
Scripts/release.sh <KEY_ID> <ISSUER_ID> [path/to/AuthKey_<KEY_ID>.p8]
```

### Prerequisite: App Store Connect API key (one-time)

App Store Connect → Users & Access → Integrations → App Store Connect API →
Team Keys → generate a key with role **App Manager**. Download the `.p8`
ONCE (ASC never re-offers it) and store it at the default location the script
looks in:

```sh
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.appstoreconnect/private_keys/
```

`KEY_ID` is the 10-char key identifier; `ISSUER_ID` is the UUID shown at the
top of the Team Keys page. If the `.p8` lives elsewhere, pass its path as the
third argument.

### What the script does, step by step

1. `export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"` —
   honors a pre-set `DEVELOPER_DIR`, otherwise defaults to the Xcode 27 beta.
   This default is how you will later switch to a GM Xcode (see §2).
2. `xcodegen generate` — the `.xcodeproj` is generated and git-ignored;
   `project.yml` is authoritative (never hand-edit the project — see
   **fortiche-change-control**).
3. `xcodebuild archive` with `-scheme Fortiche -destination
   'generic/platform=iOS' -archivePath build/Fortiche.xcarchive` plus the
   cloud-signing flags:
   - `-allowProvisioningUpdates` — lets xcodebuild create/refresh signing
     assets in the cloud; no local distribution certificate needed.
   - `-authenticationKeyID / -authenticationKeyIssuerID /
     -authenticationKeyPath` — the ASC API key from above.
   The `Fortiche` scheme archives the iOS app, which embeds the watch app and
   the widget extension (they are target dependencies in `project.yml`), so
   one archive covers all three.
4. `xcodebuild -exportArchive -exportOptionsPlist AppStore/ExportOptions.plist`
   with the same auth flags — because the plist says `destination: upload`,
   this both signs for App Store Connect and uploads in one step. Track
   processing afterwards in App Store Connect → TestFlight.

### Do not reach for altool

Upload is `xcodebuild -exportArchive` with `destination=upload` in the export
options — that is the supported path. `altool` is deprecated for uploads;
do not build any new tooling on it. (As of 2026-07 the Xcode 27 beta still
ships a legacy `altool` binary, so "it still runs" is not evidence it is the
right tool.) If you ever need a standalone uploader outside this script, the
sanctioned one is Transporter / `xcrun` `notarytool`-era tooling, but the
script's path needs neither.

### Known script pitfall: the archive step can fail "silently"

The archive invocation ends with `| grep -E 'error|warning: Signing|ARCHIVE'
|| true`. Under `set -euo pipefail`, the trailing `|| true` applies to the
whole pipeline, so a failed `xcodebuild archive` does NOT stop the script —
you find out when `-exportArchive` complains that `build/Fortiche.xcarchive`
is missing or stale. If the upload step errors about the archive, re-run the
archive command by itself without the grep filter and read the real error:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
xcodebuild archive -project Fortiche.xcodeproj -scheme Fortiche \
  -destination 'generic/platform=iOS' -archivePath build/Fortiche.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyID <KEY_ID> -authenticationKeyIssuerID <ISSUER_ID> \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

### `AppStore/ExportOptions.plist` decoded

| Key | Value | Why |
|---|---|---|
| `method` | `app-store-connect` | Distribution to ASC (TestFlight + App Store) |
| `destination` | `upload` | exportArchive uploads directly instead of writing an .ipa |
| `teamID` | `M9MD9VA4G3` | Matches `DEVELOPMENT_TEAM` in `project.yml` — keep them in sync |
| `uploadSymbols` | `true` | Symbolicated crash reports in ASC |
| `manageAppVersionAndBuildNumber` | `true` | Xcode/ASC auto-bumps the build number at upload (see §3) |

### Export compliance is pre-answered

`project.yml` sets `ITSAppUsesNonExemptEncryption: false` in the app's
Info.plist (standard HTTPS-only exemption). Every upload therefore skips the
"Does your app use encryption?" interstitial in ASC. Do not remove this key.

## 2. TestFlight vs App Store: the beta-SDK rule

- **TestFlight** generally accepts builds made with a **beta** Xcode/SDK
  during that OS's beta cycle. As of 2026-07, Xcode 27 is beta-only, so
  everything this repo produces is **TestFlight-only**.
- **App Store release** builds must be built with a **non-beta (GM/release)
  Xcode and SDK**. Apple rejects beta-SDK binaries at App Store review.

Consequence: until the iOS 27 GM Xcode ships, `Scripts/release.sh` is a
TestFlight pipeline. When the GM lands, install it and point the script at it
without editing anything:

```sh
DEVELOPER_DIR=/Applications/Xcode.app Scripts/release.sh <KEY_ID> <ISSUER_ID>
```

(The script only defaults to `/Applications/Xcode-beta.app` when
`DEVELOPER_DIR` is unset.) The app targets iOS/watchOS 27.0 minimum, so the
GM SDK builds it unchanged.

## 3. Version and build-number management

Both numbers live in `project.yml` (verified at lines 20-21):

```yaml
MARKETING_VERSION: 1.0.0        # the user-visible version, e.g. "1.0.0"
CURRENT_PROJECT_VERSION: 1      # the build number
```

Rules:

- To cut a new version: edit `MARKETING_VERSION` in `project.yml`, then
  `xcodegen generate` (release.sh regenerates anyway). Never edit the
  `.xcodeproj` (generated artifact — **fortiche-change-control**).
- You normally never touch `CURRENT_PROJECT_VERSION`:
  `manageAppVersionAndBuildNumber=true` in ExportOptions.plist makes the
  upload step assign the next valid build number for that marketing version
  automatically. This is why uploading twice in a day "just works".
- Per-release notes go in `AppStore/metadata/en-US/misc.txt` under
  `release_notes` — update that file in the same change as the version bump
  so repo and ASC never drift.

## 4. Store metadata: `AppStore/metadata/` and `review-notes.md`

### `metadata/en-US/misc.txt` — the ASC form fields

Current values (2026-07): name Fortiche, subtitle "Paste a program. Go
lift.", categories Health & Fitness / Sports, price Free, age rating 4+
(all questionnaire answers "None"), copyright © 2026 David Ruiz.

The real repo URLs are wired in (commit `f6d63d3`, 2026-07):
`support_url` = `https://github.com/druiz/fortiche` and
`privacy_policy_url` = `https://github.com/druiz/fortiche/blob/main/PRIVACY.md`.
The remaining pre-submission check is that the `github.com/druiz/fortiche`
repo is actually **public**, so both URLs resolve for Apple's reviewer
without a GitHub login (see §5).

### `metadata/en-US/description.txt` — the description

Full App Store description. Check every claim against §7 before adding a new
one. If a feature claim changes here, the same claim must stay consistent in
`review-notes.md`, `PRIVACY.md`, and README.

**Open pre-submission blocker (2026-07):** the "Your iPhone mirrors the
whole workout live … both stay in sync" paragraph describes the production
mirroring path, which is unverified on real hardware (§7, rule R2). Before
submission, either complete **fortiche-device-sync-campaign** phases 1–3 on
devices or soften this paragraph.

### `review-notes.md` — the reviewer script

Paste into App Store Connect → App Review Information. Its contents, and why
they are shaped that way:

- **No account/sign-in** stated up front — removes the demo-account review
  requirement.
- A **numbered test flow** with a copy-pasteable sample program (the same
  Push/Pull format the `--demo-import` seeder uses), covering: on-device
  parse, live workout + Live Activity buttons, History + Apple Health write,
  watch mirroring, and Siri phrases. Keep this flow executable by a reviewer
  with zero context; if a step's UI changes, update the notes in the same PR.
  **Open pre-submission blocker (2026-07):** step 4 ("a workout started
  there mirrors live to the iPhone, and edits flow both ways") exercises the
  production mirroring path, which has never run end-to-end on hardware
  (rule R2 — it cannot be tested between paired simulators). Verify it on
  real devices (**fortiche-device-sync-campaign** phases 1–3) or rewrite the
  step before submission.
- **HealthKit disclosure**: writes workouts; reads heart rate and body mass.
  The matching usage strings live in `project.yml` under both the iOS and
  watch targets' `info.properties` (all four `NSHealth*UsageDescription`
  keys) — App Review checks these exist and match behavior.
- **Intentional oddity pre-empted**: workouts under 3 minutes are discarded
  by design (accidental starts). Telling the reviewer prevents a "data loss"
  rejection.
- **The App Privacy questionnaire answer: "Data Not Collected" across the
  board.** This is true *by architecture*, not by policy promise: the
  developer operates no server, the app contains no analytics and no
  third-party SDKs, program/history data lives on-device and in the user's
  **private** CloudKit database (which the developer cannot read), Health
  data stays in Apple Health under user control, and program text is parsed
  on-device by FoundationModels or the built-in heuristic parser. Under
  Apple's definition, data is "collected" only when it is transmitted off
  device in a way accessible to the developer — nothing here is. See
  **fortiche-architecture-contract** for the design; do not add any SDK,
  endpoint, or crash reporter without re-answering the questionnaire
  (**fortiche-change-control** gates this).
- **The one network call** is disclosed: optional lazy-loading of exercise
  photos from GitHub's CDN (free-exercise-db) in the exercise detail view.
  This request carries no personal data and does not change the
  "Data Not Collected" answer, but it must stay disclosed everywhere the app
  says "no network" — always phrase it as "no network calls *except*
  exercise photos".

## 5. PRIVACY.md must be publicly reachable

Apps that access HealthKit must have a privacy policy URL in App Store
Connect (it is also required for all apps at submission). `PRIVACY.md` at the
repo root is the policy text; `misc.txt` points at the GitHub blob URL
`https://github.com/druiz/fortiche/blob/main/PRIVACY.md` (real URLs wired in
commit `f6d63d3`, 2026-07). Before first submission:

1. Verify the `github.com/druiz/fortiche` repo is **public**, so the
   `support_url` and the PRIVACY.md blob URL resolve without a GitHub login
   (`curl -sIL <url> | head -1` on both — expect HTTP 200, not 404).
2. Keep the URL entered in ASC (App Privacy → privacy policy URL) identical
   to `AppStore/metadata/en-US/misc.txt` → `privacy_policy_url`.
3. When editing `PRIVACY.md`, keep its "Last updated" line current and keep
   the exercise-photo network exception intact (§4).

## 6. Screenshot regeneration

Never hand-mock screenshots; they are generated artifacts seeded by demo
launch args (same rule family as icons/dataset — **fortiche-change-control**).
The launch-arg catalog itself is documented in **fortiche-run-and-operate**;
this section is the store-specific recipe.

### Required sizes (what is in the repo today, verified with `sips`)

| Set | Pixels | Device used |
|---|---|---|
| `AppStore/screenshots/iphone-6.9/` (4 shots) | 1320x2868 portrait | iPhone 17 Pro Max simulator (6.9-inch) |
| `AppStore/screenshots/watch/` (2 shots) | 422x514 | Apple Watch Ultra 3 (49mm) simulator |

ASC derives smaller iPhone sizes from the 6.9-inch set, so only this set is
maintained. The pixel sizes are simply the native screen sizes of those two
simulators — `xcrun simctl io <udid> screenshot` produces the right
dimensions with no post-processing.

### Shot-to-launch-arg map

| File | Launch args | Notes |
|---|---|---|
| `iphone-6.9/01-programs.png` | `--demo-import --demo-history --skip-health` | Programs tab is the default tab |
| `iphone-6.9/02-live-workout.png` | `--demo-import --demo-history --demo-workout --skip-health` | `--demo-workout` auto-starts the first day |
| `iphone-6.9/03-history.png` | `--demo-import --demo-history --skip-health --tab history` | history seeding gives 3 weeks of logs, PRs, charts |
| `iphone-6.9/04-settings.png` | `--skip-health --tab settings` | no seed needed |
| `watch/01-days.png` | (none on watch) | day list, populated via template push from phone |
| `watch/02-live-set.png` | `--demo-workout` (on the watch app) | starts the first day of the first synced template |

Two behavioral facts that shape the procedure (verified in
`Fortiche/RootView.swift` and `ForticheWatch/ForticheWatchApp.swift`):

- `--demo-history` only takes effect **during** a `--demo-import` seed (the
  history seeder runs inside the import hook). Seeding also only runs when
  the store has no templates. So include `--demo-history` in the FIRST
  seeded launch; to change your mind, uninstall the app to wipe its store.
- The watch has **no** `--demo-import`. Its templates arrive only via the
  WatchConnectivity applicationContext push from the phone (which the phone
  re-sends on every launch). WC works fine between paired simulators — the
  simulator limitation (rule R2, HK session mirroring) does not apply to
  template sync.

### Full recipe

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app

# 0. Discover simulators (create a paired iPhone 17 Pro Max + Ultra 3 pair
#    in Device Hub if none exists; see fortiche-run-and-operate).
xcrun simctl list devices available | grep -E "iPhone 17 Pro Max|Ultra 3"
xcrun simctl list pairs
PHONE=<phone-udid> ; WATCH=<watch-udid>
xcrun simctl boot "$PHONE"; xcrun simctl boot "$WATCH"

# 1. Build both apps for simulator into a known products dir.
xcodegen generate
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination "platform=iOS Simulator,id=$PHONE" \
  -derivedDataPath build/screens build

# 2. Install. The embedded watch app auto-install is flaky on this beta —
#    install it explicitly from inside the iOS bundle (fortiche-run-and-operate).
APP=build/screens/Build/Products/Debug-iphonesimulator/Fortiche.app
xcrun simctl install "$PHONE" "$APP"
xcrun simctl install "$WATCH" "$APP/Watch/ForticheWatch.app"

# 3. Clean status bars (classic 9:41, full battery).
xcrun simctl status_bar "$PHONE" override --time "9:41" \
  --batteryState charged --batteryLevel 100

# 4. iPhone shots — relaunch with the args from the table, screenshot each.
#    (terminate first; launch args only apply to a fresh process)
xcrun simctl terminate "$PHONE" com.davidruiz.fortiche 2>/dev/null || true
xcrun simctl launch "$PHONE" com.davidruiz.fortiche \
  --demo-import --demo-history --skip-health
sleep 8   # let the parse/seed finish (watch templates also get pushed now)
xcrun simctl io "$PHONE" screenshot AppStore/screenshots/iphone-6.9/01-programs.png
# ... repeat terminate/launch/screenshot for 02 (add --demo-workout),
#     03 (--tab history), 04 (--tab settings) per the table above.

# 5. Watch shots — templates should already be on the watch from step 4.
xcrun simctl launch "$WATCH" com.davidruiz.fortiche.watchkitapp
xcrun simctl io "$WATCH" screenshot AppStore/screenshots/watch/01-days.png
xcrun simctl terminate "$WATCH" com.davidruiz.fortiche.watchkitapp
xcrun simctl launch "$WATCH" com.davidruiz.fortiche.watchkitapp --demo-workout
sleep 5
xcrun simctl io "$WATCH" screenshot AppStore/screenshots/watch/02-live-set.png

# 6. Verify dimensions before committing.
sips -g pixelWidth -g pixelHeight AppStore/screenshots/iphone-6.9/*.png \
  AppStore/screenshots/watch/*.png
```

Gotchas (details in **fortiche-run-and-operate**): if the watch day list is
empty, relaunch the phone app once (it re-pushes the catalog on every launch,
and pushes buffer until WC activation); if the demo seed didn't run, the
store probably wasn't empty — `xcrun simctl uninstall "$PHONE"
com.davidruiz.fortiche` and redo step 2. On the iPhone simulator, HealthKit
auth auto-grants, and `--skip-health` suppresses the request entirely, so no
permission sheet should ever appear in a shot.

## 7. External positioning: what may be claimed

Every public artifact (App Store description, promotional text, README,
release notes, interviews) draws from the same two lists. Adding a claim to
the MAY list requires the evidence bar in **fortiche-validation-and-qa** and
goes through **fortiche-change-control**.

**MAY claim (architecture- or code-backed, shipping today):**

- On-device program parsing via Apple Intelligence / FoundationModels, with a
  built-in (heuristic) parser fallback where the model is unavailable —
  "nothing you paste leaves your device" (see **fortiche-intelligence-reference**).
- No account, no server, no analytics, no third-party SDKs; "Data Not
  Collected" privacy label; data in the user's private iCloud and Apple
  Health. Always with the exercise-photo CDN exception when phrasing is
  absolute (§4).
- Live Activity with working Log Set / Skip Rest / Pause buttons; Siri /
  App Intents phrases; PRs (estimated 1RM), weekly volume, plate calculator;
  870+ public-domain exercise library with alias matching.

**MUST NOT claim until proven (as of 2026-07):**

- **Live phone-watch mirroring as a proven shipping feature.** The engine
  and sync logic are verified on simulators over the WC debug transport, but
  the production HK mirrored-session channel has never run end-to-end on
  real hardware — rule R2 makes it untestable between paired simulators, and
  **fortiche-validation-and-qa**'s evidence rules forbid claiming mirroring
  works from simulator evidence. Re-adding this to the MAY list is gated on
  **fortiche-device-sync-campaign** phases 1–3 passing on devices. Until
  then, `review-notes.md` step 4 and the description's mirroring paragraph
  are pre-submission blockers (§4).
- Anything involving **Private Cloud Compute** or cloud-model parsing. The
  watch-side cloud-backed `LanguageModelSession` path is untested and
  on-watch local models are unavailable on watchOS 27 (rule R7); nothing
  cloud-AI is shipped or validated.
- **Adaptive coaching / auto-progression / AI programming advice** — not
  implemented; lives in **fortiche-research-frontier** as candidate work.
- Any absolute "zero network traffic" phrasing (false: exercise photos), any
  "works fully offline on watch alone" phrasing beyond what the local-only
  watch store actually supports, and any accuracy percentage for the parser
  that has not been measured per **fortiche-validation-and-qa**.

## 8. Pre-submission checklist

- [ ] `swift test --package-path FortichePack` green; both platform builds
      green (**fortiche-build-and-env**); QA evidence per
      **fortiche-validation-and-qa**.
- [ ] `MARKETING_VERSION` bumped in `project.yml`; release notes updated in
      `misc.txt`.
- [ ] Screenshots regenerated if any pictured UI changed (§6), dimensions
      verified.
- [ ] `review-notes.md` test flow re-walked on the current build — every step
      must still work exactly as written.
- [ ] `github.com/druiz/fortiche` public; `support_url` and
      `privacy_policy_url` resolve without login (§5).
- [ ] Mirroring claims resolved: `review-notes.md` step 4 and the
      description's mirroring paragraph either verified on real hardware
      (**fortiche-device-sync-campaign**) or rewritten (§7).
- [ ] Description/promo claims all in the MAY list (§7).
- [ ] TestFlight upload: `Scripts/release.sh <KEY_ID> <ISSUER_ID>`.
- [ ] App Store (post-GM only): rebuild with the release Xcode via
      `DEVELOPER_DIR=/Applications/Xcode.app Scripts/release.sh ...` (§2).

## Provenance and maintenance

Verified 2026-07-05 against the working tree. Re-verify before relying:

- Script anatomy / flags: `cat Scripts/release.sh`
- Export options: `cat AppStore/ExportOptions.plist` (team must equal
  `grep DEVELOPMENT_TEAM project.yml`)
- Version fields: `grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" project.yml`
- Export-compliance key: `grep -n ITSAppUsesNonExemptEncryption project.yml`
- HealthKit usage strings: `grep -n NSHealth project.yml` (4 hits: 2 iOS, 2 watch)
- Metadata URLs current: `grep -n 'druiz/fortiche' AppStore/metadata/en-US/misc.txt` (expect `support_url` and `privacy_policy_url` hits); repo reachable: `curl -sIL https://github.com/druiz/fortiche | head -1` (expect 200)
- Screenshot dimensions: `sips -g pixelWidth -g pixelHeight AppStore/screenshots/iphone-6.9/01-programs.png AppStore/screenshots/watch/01-days.png` (expect 1320x2868 and 422x514)
- Demo-arg behavior (history-inside-import, `--tab`): `grep -n "demo-\|--tab" Fortiche/RootView.swift`
- Watch demo hook (no watch-side import): `grep -n "demo" ForticheWatch/ForticheWatchApp.swift`
- Simulators still exist: `export DEVELOPER_DIR=/Applications/Xcode-beta.app; xcrun simctl list devicetypes | grep -E "iPhone 17 Pro Max|Ultra 3"`
- Xcode still beta (TestFlight-only rule active): check for a non-beta
  `/Applications/Xcode.app` with a 27.x GM; until then §2 stands.
- Bundle IDs used in the recipe: `grep -n PRODUCT_BUNDLE_IDENTIFIER project.yml`
