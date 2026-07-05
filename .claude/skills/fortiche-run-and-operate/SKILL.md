---
name: fortiche-run-and-operate
description: >
  Run and configure the Fortiche app: boot paired iPhone/Watch simulators, install
  the app and the embedded watch app (direct install workaround), launch with the
  demo/automation launch arguments (--demo-import, --demo-history, --demo-workout,
  --skip-health, --tab), install on real devices with xcrun devicectl, and change
  any configuration axis in project.yml (bundle ids, entitlements, Info.plist keys,
  ENABLE_DEBUG_DYLIB, app-icon build settings, UserDefaults keys). Load this skill
  whenever you need to see the app running, seed demo data, take screenshots,
  rename the app, add a launch arg, add an alternate icon, or add an entitlement.
---

# Fortiche: run and operate

This is the runbook for **getting the app on a screen** (simulator or device) and
the **catalog of every configuration knob** the project exposes. All commands were
verified against the repo as of 2026-07.

## When NOT to use this skill

| You actually want | Go to |
|---|---|
| Toolchain setup, xcodegen, xcodebuild flags, `swift test` | `fortiche-build-and-env` |
| Log filtering, `log stream`/`log show` gotchas, chronod/linkd forensics | `fortiche-diagnostics-and-tooling` |
| Why a past incident happened (Live Activity dead buttons, mirroring failures) | `fortiche-failure-archaeology` |
| Engine/sync design (command sourcing, snapshots, WC channels) | `fortiche-architecture-contract` |
| Debugging a live misbehavior right now | `fortiche-debugging-playbook` |
| Testing the phone↔watch live-sync path on real hardware | `fortiche-device-sync-campaign` |
| App Store metadata, release script, TestFlight | `fortiche-appstore-and-release` |
| QA passes / acceptance checklists | `fortiche-validation-and-qa` |
| What must not be changed without sign-off | `fortiche-change-control` |

Jargon used below, defined once:

- **XcodeGen** — tool that generates `Fortiche.xcodeproj` from `project.yml`. The
  `.xcodeproj` is git-ignored; **never edit it, edit `project.yml` then regenerate**.
- **UDID** — the simulator/device unique identifier `simctl` and `devicectl` take.
- **appex** — an app extension bundle (here: the widget extension inside `PlugIns/`).
- **Live Activity** — the Lock Screen / Dynamic Island workout card driven by the
  widget extension.

## 0. Prerequisites (one-time per shell)

Xcode 27 beta is required and is NOT the selected toolchain on this machine:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
cd <repo-root>          # the directory containing project.yml
xcodegen generate       # only needed after project.yml changes or fresh clone
```

## 1. Run on paired simulators

### 1.1 Pick and boot a pair

```sh
xcrun simctl list pairs
```

Pick a pair whose phone and watch are both on the 27.0 runtimes (the app's
deployment target is iOS/watchOS 27.0 — older runtimes will refuse to install).
Then boot both halves by UDID:

```sh
PHONE=<phone-udid>
WATCH=<watch-udid>
xcrun simctl boot "$PHONE"
xcrun simctl boot "$WATCH"
```

Note: `simctl list pairs` reporting `(active, disconnected)` is normal while both
sims are shut down; and even `(active, connected)` does **not** mean HealthKit
mirroring works between sims — it never does (Rapport link absent, see
`docs/SPIKE-M1.5.md` and `fortiche-failure-archaeology`). The WatchConnectivity
debug transport covers the simulator dev loop.

### 1.2 Build to a known products path

Use an explicit `-derivedDataPath` so the `.app` location is predictable (do not
hardcode the default DerivedData hash directory — it differs per machine):

```sh
DD=/tmp/fortiche-dd
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination "platform=iOS Simulator,id=$PHONE" \
  -derivedDataPath "$DD" build
APP="$DD/Build/Products/Debug-iphonesimulator/Fortiche.app"
```

The built bundle embeds everything (verified structure):

```
Fortiche.app/
  Watch/ForticheWatch.app        # the watch app
  PlugIns/ForticheWidgets.appex  # the widget/Live Activity extension
  Metadata.appintents            # App Intents metadata (must exist — see §4.1)
```

### 1.3 Install — including the watch-app workaround

```sh
xcrun simctl install "$PHONE" "$APP"
```

**Workaround (known flaky path):** on this beta, the watch app frequently does
NOT auto-install on the paired watch sim from the embedded bundle. Install it
directly onto the watch simulator instead:

```sh
xcrun simctl install "$WATCH" "$APP/Watch/ForticheWatch.app"
```

### 1.4 Launch, with the launch-arg catalog

`simctl launch` passes everything after the bundle id as process arguments:

```sh
xcrun simctl launch "$PHONE" com.davidruiz.fortiche --demo-import --demo-history --skip-health
xcrun simctl launch "$WATCH" com.davidruiz.fortiche.watchkitapp --demo-workout --skip-health
```

Full catalog (every consumer verified in source):

| Arg | Platform | Exactly what it does | Source |
|---|---|---|---|
| `--demo-import` | iOS | Seeds a 3-day Push/Pull/Legs program **through the real parse → canonicalize → save pipeline** (uses `IntelligentProgramParser` if the local model is available, else `HeuristicProgramParser`; empty name suggestion → `ProgramNamer` produces "Push/Pull/Legs"). **No-op unless the template list is empty** — safe to pass on every launch. Also pushes the catalog to the watch. | `Fortiche/RootView.swift` (`runDemoImportIfRequested`) |
| `--demo-history` | iOS | Seeds ~3 weeks of plausible finished `WorkoutLog`s cycling the template's days, weights creeping +2.5 kg per cycle — enough for charts, PRs, and ghost sets. **Only runs inside the `--demo-import` path**: pass BOTH flags, on a run where the import actually fires (empty store). Alone it does nothing. | `Fortiche/RootView.swift` (`seedDemoHistory`) |
| `--demo-workout` | iOS + watchOS | Auto-starts the **first day of the first template**, headlessly. **Works standalone** with pre-existing data (it runs in a `.task(id: templates.count)` independent of the import path), and also chains after `--demo-import`. No-op if a workout is already active or no templates exist. | `Fortiche/RootView.swift`, `ForticheWatch/ForticheWatchApp.swift` |
| `--skip-health` | iOS + watchOS | Suppresses ALL HealthKit/notification authorization requests so headless runs never show permission sheets: phone mirror auth (`RootView`), phone workout recording + notification auth (`PhoneWorkoutController.start`), watch HK session (`WatchWorkoutController.startHealthKitSession` — the watch then runs the workout with **no HK session at all**, so no mirroring either). | grep `--skip-health` |
| `--tab history` / `--tab settings` | iOS | Opens on that tab instead of the default `programs`. Valid values are the tab tags: `programs`, `history`, `settings`. Used by the App Store screenshot flow. | `Fortiche/RootView.swift` |
| `--spike-autostart` | — | **Legacy, removed.** Belonged to the M1.5 spike (`SpikeWorkoutController`), which no longer exists in the tree. As of 2026-07 the string appears nowhere in source — do not document or pass it; `--demo-workout` on the watch is the replacement. | (absent) |

Useful combos:

- Screenshot seeding: `--demo-import --demo-history --skip-health --tab history`
- Headless live-workout check: `--demo-import --demo-workout --skip-health`
- Watch-side demo: install templates first (launch phone app once so it pushes the
  catalog over WC applicationContext, or start from `--demo-import` on the phone),
  then `--demo-workout --skip-health` on the watch.

### 1.5 Simulator operational gotchas

- **Device Hub replaced Simulator.app** in Xcode 27. GUI lives at
  `/Applications/Xcode-beta.app/Contents/Applications/DeviceHub.app`
  (`open` it if you need a visible screen; `simctl` works headless regardless).
- **SpringBoard caches app icons across reinstalls.** After regenerating icons,
  either delete the app from the sim (`xcrun simctl uninstall "$PHONE" com.davidruiz.fortiche`)
  or respring — otherwise you'll stare at the stale icon and think the generator failed.
- **iPhone-simulator HealthKit auth auto-grants** (no sheet). The watch sim DOES
  show sheets — hence `--skip-health` for headless watch runs.
- **Logging:** `log show` needs `--info`, `log stream` needs `--level info`, or
  every `Logger.info` line is invisible. Full recipes: `fortiche-diagnostics-and-tooling`.
- **HK mirroring never connects between paired sims** and
  `startMirroringToCompanionDevice()` succeeds anyway — don't burn time on it;
  real devices only (`fortiche-device-sync-campaign`).

## 2. Run on real devices (xcrun devicectl)

`devicectl` accepts a UUID, UDID, serial, or the device's **name** for `--device`.

```sh
# Discover attached devices (physical entries have Reality = "physical")
xcrun devicectl list devices

# Build for device (cloud/automatic signing is configured in project.yml)
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/fortiche-dd build

# Install + launch
xcrun devicectl device install app --device <name-or-uuid> \
  /tmp/fortiche-dd/Build/Products/Debug-iphoneos/Fortiche.app
xcrun devicectl device process launch --device <name-or-uuid> com.davidruiz.fortiche

# What's installed
xcrun devicectl device info apps --device <name-or-uuid>
```

Launch args work with `devicectl device process launch` too (appended after the
bundle id). On a real phone the watch app installs via the embedded `Watch/`
bundle through the normal Watch-app sync; the direct-install workaround in §1.3
is a simulator-only concern. Real-device HealthKit requires the provisioning
profile from the paid team (`DEVELOPMENT_TEAM: M9MD9VA4G3` in `project.yml`).

## 3. Configuration catalog (project.yml is the single source of truth)

Everything below lives in `project.yml`. After ANY edit:
`xcodegen generate` — then rebuild. Never touch `Fortiche.xcodeproj`.

### 3.1 Identity / rename points

"Fortiche" is a working codename. The rename points (documented at the top of
`project.yml`) are:

| Axis | Current value |
|---|---|
| Bundle id prefix | `com.davidruiz` (`bundleIdPrefix`) |
| iOS app | `com.davidruiz.fortiche` |
| Watch app | `com.davidruiz.fortiche.watchkitapp` (+ `WKCompanionAppBundleIdentifier` must match the iOS app id) |
| Widget ext | `com.davidruiz.fortiche.widgets` |
| iCloud container | `iCloud.com.davidruiz.fortiche` |
| App group | `group.com.davidruiz.fortiche` |

Renaming is change-controlled (App Store identity, iCloud container migration) —
see `fortiche-change-control` before touching any of these.

### 3.2 Entitlements per target

Declared as `entitlements.properties` in `project.yml`; XcodeGen writes the
`.entitlements` files (`Fortiche/Fortiche.entitlements`, etc.) at generate time —
treat those files as generated output.

| Entitlement | Fortiche (iOS) | ForticheWatch | ForticheWidgets |
|---|---|---|---|
| `com.apple.developer.healthkit` | yes | yes | — |
| `com.apple.developer.healthkit.background-delivery` | yes | — | — |
| `com.apple.developer.icloud-services: [CloudKit]` + container | yes | — | — |
| `com.apple.security.application-groups` | yes | — | yes |
| `com.apple.developer.siri` | yes | — | — |

Note the deliberate asymmetries: the watch store is local-only (no CloudKit on
watch); the widget shares the app group with the app but has no HealthKit.

### 3.3 Info.plist keys (set via `info.properties` in project.yml)

| Key | Target | Why it exists |
|---|---|---|
| `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription` | iOS + watch (different strings per platform) | Required or HealthKit auth crashes at request time. |
| `NSSupportsLiveActivities: true` | iOS | Without it, `Activity.request` throws and no Live Activity ever appears. |
| `WKBackgroundModes: [workout-processing]` | watch | Keeps the watch app alive through a workout session. |
| `WKApplication: true`, `WKCompanionAppBundleIdentifier` | watch | Marks it a watch app and binds it to the phone app. |
| `ITSAppUsesNonExemptEncryption: false` | iOS | Standard HTTPS-only exemption; auto-answers the export-compliance question on every App Store upload. |
| `UILaunchScreen: {}`, portrait-only orientation | iOS | Baseline app config. |
| `NSExtensionPointIdentifier: com.apple.widgetkit-extension` | widgets | Declares the extension point. |

### 3.4 LOAD-BEARING build settings — do not "clean up"

**`ENABLE_DEBUG_DYLIB: NO`** (project-wide `settings.base`). Hard rule R1: it
stays NO, project-wide. Consequence of flipping it: Live Activity buttons go
silently dead — `linkd` cannot index App Intents metadata from the debug-dylib
stub binary. Cost of keeping it NO: slower SwiftUI-preview relaunches. Related
half of the same incident: App Intents must never live in a Swift package —
Siri intents are in `Fortiche/Intents/`, Live Activity intents in `Shared/`
(compiled into BOTH the app and widget targets), and the
`AppShortcutsProvider` must be in the app target. Log strings and full
forensics: `fortiche-failure-archaeology`.

**App icon settings — a THREE-WAY sync.** On the Fortiche target:

```yaml
ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: AppIcon-Ember AppIcon-Forest AppIcon-Midnight AppIcon-Ivory
```

These names must agree with, simultaneously:

1. The `colorways` array in `Scripts/generate_icon.swift` — the first entry
   becomes the primary `AppIcon.appiconset`, later entries become
   `AppIcon-<Name>.appiconset`, and EVERY entry (including the first — hence
   `IconPreview-Indigo`) additionally gets an `IconPreview-<Name>.imageset`,
   because appiconsets are not loadable via `UIImage(named:)` for the in-app
   picker.
2. `AppIconPicker.options` in `Fortiche/Settings/AppIconPicker.swift`
   (`iconName: nil` = primary, else `"AppIcon-<Name>"`; `previewName:
   "IconPreview-<Name>"`).
3. The build settings above in `project.yml`.

The asset catalogs are generated — never hand-edit `Fortiche/Assets.xcassets`
icon sets; run `swift Scripts/generate_icon.swift --catalog` (rule R8).
watchOS has no alternate icons; the watch catalog gets the default colorway only.

**Other settings worth knowing** (all in `project.yml`): `SWIFT_VERSION: 6.0`,
deployment targets 27.0/27.0, `CODE_SIGN_STYLE: Automatic` +
`DEVELOPMENT_TEAM`, `TARGETED_DEVICE_FAMILY: 1` and
`SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"` (iPhone-only, no iPad/Mac
Catalyst), `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (bumped by the
release flow — `fortiche-appstore-and-release`).

### 3.5 UserDefaults keys

| Key | Constant | Semantics |
|---|---|---|
| `weightUnit` | `WeightUnit.preferenceKey` (`FortichePack/Sources/FortichePack/Units/UnitPreference.swift`) | User's DISPLAY unit (`WeightUnit` rawValue). Read via `WeightUnit.preferred`; SettingsView writes it through `@AppStorage(WeightUnit.preferenceKey)` so every screen updates live. **Storage is always kilograms** — this key affects display/input conversion only. Plain `UserDefaults.standard`, not the app group. |

That is the only user-preference defaults key as of 2026-07. (The engine's crash
journal and the alternate-icon selection are NOT defaults keys — the journal is
a disk file, the icon choice is persisted by the system via
`setAlternateIconName`.)

## 4. Checklists

### 4.1 Add a new launch arg

1. Pick a `--kebab-case` name; check it isn't taken: `grep -rn '\-\-my-arg' Fortiche ForticheWatch Shared`.
2. Consume it via `ProcessInfo.processInfo.arguments.contains("--my-arg")`
   (value-taking args: see the `--tab` index pattern in `Fortiche/RootView.swift`).
   Put the check in the target that owns the behavior; a seeding arg should be a
   no-op when data already exists (mirror `--demo-import`'s `templates.isEmpty` guard)
   so scripts can pass it unconditionally.
3. Add a one-line comment at the consumption site starting with
   "CLI automation hook:" (the greppable convention used by the existing args).
4. If the arg triggers HealthKit or notifications, make it compose with
   `--skip-health`.
5. Update the catalog table in §1.4 of THIS skill, and the launch-args line in
   `CLAUDE.md` if it's a headline arg.
6. Verify headlessly: build, `simctl install`, `simctl launch "$PHONE"
   com.davidruiz.fortiche --my-arg --skip-health`, then assert the effect via
   UI or `log stream --level info`.
7. A new launch arg is a behavior change in a target source (plus a CLAUDE.md
   edit) — it goes through `fortiche-change-control` like any other code
   change; classify the risk tier there before merging.

### 4.2 Add a new alternate app icon

1. Add the colorway tuple to `colorways` in `Scripts/generate_icon.swift`
   (append — index 0 is the primary).
2. Regenerate the catalogs: `swift Scripts/generate_icon.swift --catalog`
   (needs no DEVELOPER_DIR; pure CoreGraphics). Never hand-edit the emitted
   `.appiconset`/`.imageset` folders.
3. Append `AppIcon-<Name>` to `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`
   in `project.yml`, then `xcodegen generate`. This is a `project.yml` edit —
   at least medium risk per `fortiche-change-control`, which requires
   `xcodegen generate` plus BOTH platform builds and its pre-review checklist.
4. Add an `IconOption(label:iconName:"AppIcon-<Name>", previewName:"IconPreview-<Name>")`
   to `AppIconPicker.options` in `Fortiche/Settings/AppIconPicker.swift`.
5. Rebuild with **both platform builds green** (iOS and watchOS —
   `fortiche-build-and-env`), **uninstall the app from the simulator first**
   (SpringBoard icon cache), reinstall, then switch to the new icon in
   Settings → App Icon and confirm on the home screen.

### 4.3 Add a new entitlement

1. Add it under the owning target's `entitlements.properties` in `project.yml`
   only — never edit the `.entitlements` files by hand (generated).
2. `xcodegen generate`, rebuild both platforms.
3. Ask: does the capability need App Store Connect / provisioning changes
   (e.g. new iCloud container, push)? Automatic signing usually handles it, but
   real-device HealthKit-class entitlements need the paid-team profile.
4. If the entitlement gates a runtime API, the simulator may behave differently
   from device (e.g. sim HK auto-grants) — verify on device before claiming done.
5. Entitlement additions are change-control territory (`fortiche-change-control`):
   they alter the App Store privacy story ("Data Not Collected") review surface.

## Provenance and maintenance

Verified against the repo on 2026-07-05 (Xcode 27 beta). If any check below
disagrees with this document, the repo wins — update this file.

```sh
# Launch args still exist with the documented semantics
grep -rn 'demo-import\|demo-history\|demo-workout\|skip-health\|"--tab"\|--tab ' Fortiche ForticheWatch Shared
# --spike-autostart is still absent (if this ever matches, un-legacy it)
grep -rn 'spike-autostart' Fortiche ForticheWatch Shared FortichePack/Sources
# Bundle ids / entitlements / Info keys / icon names / ENABLE_DEBUG_DYLIB
grep -n 'PRODUCT_BUNDLE_IDENTIFIER\|ENABLE_DEBUG_DYLIB\|APPICON\|healthkit\|application-groups\|icloud\|siri\|WKBackgroundModes\|NSSupportsLiveActivities\|ITSAppUsesNonExemptEncryption' project.yml
# Icon three-way sync partners
grep -n 'AppIcon' Scripts/generate_icon.swift Fortiche/Settings/AppIconPicker.swift
# UserDefaults key
grep -n 'preferenceKey' FortichePack/Sources/FortichePack/Units/UnitPreference.swift
# Bundle layout after a sim build (Watch/ and PlugIns/ present)
ls "<derived-data>/Build/Products/Debug-iphonesimulator/Fortiche.app"
# Device Hub still ships at this path
ls /Applications/Xcode-beta.app/Contents/Applications/ | grep DeviceHub
# devicectl subcommands unchanged
xcrun devicectl device install app --help | head -5
```
