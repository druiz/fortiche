---
name: fortiche-build-and-env
description: >
  Set up a machine to build Fortiche from scratch and get to a known-good state:
  Xcode 27 beta selection (DEVELOPER_DIR pattern), installing XcodeGen, when and
  why to run `xcodegen generate`, required iOS 27.0 / watchOS 27.0 simulator
  runtimes and paired simulators, code signing via project.yml, first-build
  traps (missing new files, watch bundle-id suffix, version matching, why
  `swift test` runs on macOS), and the full verification sequence (64/64 tests
  + two green simulator builds). Load this when: a build fails on a fresh
  checkout, xcodebuild says "Fortiche.xcodeproj does not exist", a new file is
  "not in scope" / not compiling, signing settings look wrong or got reverted,
  simulators or runtimes are missing, or you need to prove the toolchain is
  healthy before touching code.
---

# Fortiche: build system and environment setup

This is the runbook for taking a fresh checkout of `/Users/david/Code/Fortiche`
(or a fresh machine) to a verified, buildable state. Follow it top to bottom on
a new environment; jump to a section when a specific symptom matches.

Key vocabulary, defined once:

- **XcodeGen** — a CLI tool that generates `Fortiche.xcodeproj` from the
  declarative spec `project.yml`. The `.xcodeproj` is a **generated artifact**:
  git-ignored, never hand-edited, always reproducible via `xcodegen generate`.
- **DEVELOPER_DIR** — an environment variable that tells `xcodebuild`, `swift`,
  `xcrun`, etc. which Xcode installation to use, overriding the machine-wide
  `xcode-select` choice for the current shell only.
- **FortichePack** — the local Swift Package (at `FortichePack/`) holding all
  models/engine/parsing/sync/stats logic. It has its own `Package.swift` and
  test suite, and builds independently of the Xcode project.

## When NOT to use this skill

- Running the app, launch arguments, seeding demo data, installing on
  simulators/devices → **fortiche-run-and-operate**.
- Reading logs, `log show`/`log stream` flags, chronod/linkd forensics,
  simulator gotchas while debugging → **fortiche-diagnostics-and-tooling**.
- Deciding *whether* you are allowed to change `project.yml`, entitlements, or
  build settings → **fortiche-change-control**.
- Why the targets are shaped the way they are (Shared/ dual-compilation, App
  Intents placement, watch-authoritative engine) → **fortiche-architecture-contract**.
- The incident history behind `ENABLE_DEBUG_DYLIB: NO` and intents-in-app-target
  → **fortiche-failure-archaeology**.
- Test strategy and QA passes beyond the smoke sequence here → **fortiche-validation-and-qa**.
- Archiving, TestFlight upload, App Store metadata (`Scripts/release.sh`) →
  **fortiche-appstore-and-release**.
- Anything requiring real (physical) iPhone + Watch hardware →
  **fortiche-device-sync-campaign**.

## Prerequisites at a glance

| Requirement | Why | Verify with |
|---|---|---|
| macOS host with Xcode 27 beta at `/Applications/Xcode-beta.app` | iOS/watchOS 27.0 SDKs; the app is 27-exclusive | `DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild -version` |
| XcodeGen (Homebrew) | Generates the git-ignored `.xcodeproj` from `project.yml` | `xcodegen --version` |
| iOS 27.0 + watchOS 27.0 simulator runtimes | Build destinations and the whole sim dev loop | `xcrun simctl list runtimes` |
| At least one paired iPhone+Watch simulator pair | Watch app runs against a paired phone; WC debug transport needs a pair | `xcrun simctl list pairs` |
| Python 3 (only if regenerating the exercise dataset) | `Scripts/import_exercises.py` | `python3 --version` |

As of 2026-07 the known-good versions on the reference machine: Xcode 27.0
(build 27A5194q), XcodeGen 2.45.4, iOS 27.0 runtime 24A5355p, watchOS 27.0
runtime 24R5289n. Newer betas may work; these are the ones the "64/64 tests +
two green builds" baseline was verified against.

## Step 1 — Select the Xcode 27 beta (DEVELOPER_DIR, not xcode-select)

Xcode 27 beta must live at `/Applications/Xcode-beta.app`. It is typically NOT
the machine's globally selected toolchain, and we deliberately do not make it
so. Prefix every `swift` / `xcodebuild` / `xcrun` invocation session with:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
```

Why `DEVELOPER_DIR` instead of `sudo xcode-select -s`:

- Per-shell, zero side effects on other projects or tools on the machine.
- No sudo, so it works in sandboxed/headless agent shells.
- Copy-pasteable into scripts (`Scripts/release.sh` does exactly this, with a
  `${DEVELOPER_DIR:-/Applications/Xcode-beta.app}` default).

Note: `DEVELOPER_DIR` accepts the `.app` path; tools resolve it to
`Contents/Developer` internally (`xcodebuild -version` will confirm it picked
up Xcode 27.0). If a command behaves as if it's using the wrong Xcode, check
`xcode-select -p` — but fix it by exporting `DEVELOPER_DIR`, not by changing
the global selection.

Every command block below assumes `DEVELOPER_DIR` is exported in the current
shell. Shell state does not persist between separate tool invocations, so
re-export it in each new shell/compound command.

## Step 2 — Install XcodeGen

```sh
brew install xcodegen
xcodegen --version   # 2.45.4 known-good as of 2026-07
```

## Step 3 — Generate the Xcode project

```sh
cd /Users/david/Code/Fortiche
export DEVELOPER_DIR=/Applications/Xcode-beta.app
xcodegen generate
```

`Fortiche.xcodeproj/` is in `.gitignore` — a fresh clone has **no project
file** until you run this. Regenerate after:

1. **Any edit to `project.yml`** — the project is otherwise stale and silently
   ignores your change.
2. **Adding, deleting, moving, or renaming ANY source file** in `Fortiche/`,
   `ForticheWatch/`, `ForticheWidgets/`, or `Shared/`. XcodeGen resolves target
   source lists by scanning those directories **at generation time** — a file
   created after the last `xcodegen generate` is invisible to `xcodebuild`.
   Symptom: "cannot find 'X' in scope" for a type you can see on disk.
   (Files under `FortichePack/Sources` and `FortichePack/Tests` are picked up
   by SwiftPM directly and do NOT need regeneration.)

Regeneration is idempotent and safe to run any time you are unsure. Never edit
the `.xcodeproj` (or target settings in Xcode's UI) — the next `xcodegen
generate` clobbers it without warning. See **fortiche-change-control** before
changing `project.yml` itself; header comments in that file are load-bearing
(notably the `ENABLE_DEBUG_DYLIB: NO` rationale — never flip it; incident
detail in **fortiche-failure-archaeology**).

## Step 4 — Simulator runtimes and paired pairs

Both 27.0 runtimes must be installed (Xcode → Settings → Components, or
`xcodebuild -downloadPlatform iOS` / `-downloadPlatform watchOS`):

```sh
xcrun simctl list runtimes | grep -E 'iOS 27|watchOS 27'
# iOS 27.0 (27.0 - 24A5355p) - com.apple.CoreSimulator.SimRuntime.iOS-27-0
# watchOS 27.0 (27.0 - 24R5289n) - com.apple.CoreSimulator.SimRuntime.watchOS-27-0
```

The `generic/platform=... Simulator` build destinations used below need only
the runtimes. For actually *running* the watch app you need a paired
iPhone+Watch simulator pair — discover them with:

```sh
xcrun simctl list pairs
```

Pick a pair whose phone and watch are both on 27.0 devices (Xcode's default
device set usually includes several; create one with
`xcrun simctl pair <watch-udid> <phone-udid>` if needed). Do not hard-code
UDIDs anywhere — always rediscover via `simctl list`. Two facts that live in
sibling skills but bite people here:

- A pair showing `(active, connected)` does NOT mean HKWorkoutSession
  mirroring works — it never works between paired simulators
  (**fortiche-failure-archaeology**, `docs/SPIKE-M1.5.md`).
- Xcode 27 replaced Simulator.app with Device Hub
  (`/Applications/Xcode-beta.app/Contents/Applications/DeviceHub.app`) —
  operational detail in **fortiche-run-and-operate**.

## Step 5 — Code signing

Signing is configured **only** in `project.yml` (`settings.base`):

```yaml
CODE_SIGN_STYLE: Automatic
DEVELOPMENT_TEAM: M9MD9VA4G3
```

Rules:

- Never set the team (or any build setting) in the generated project or via
  Xcode's Signing & Capabilities UI — the next `xcodegen generate` clobbers it.
  If signing settings "mysteriously reverted", this is why.
- On a machine where `M9MD9VA4G3` is not a signed-in team: simulator builds
  (the verification sequence below) do not require a valid team; device builds
  do. Changing `DEVELOPMENT_TEAM` is a `project.yml` change → goes through
  **fortiche-change-control**.
- Release/TestFlight signing uses xcodebuild cloud signing with an ASC API key
  and is out of scope here → **fortiche-appstore-and-release**.

## First-build traps

| Symptom | Cause | Fix |
|---|---|---|
| `xcodebuild: error: ... Fortiche.xcodeproj does not exist` | Fresh clone; project is generated, git-ignored | `xcodegen generate` (Step 3) |
| New type "cannot find in scope" though the file exists on disk | File added after last generation; source lists resolve at generation time | `xcodegen generate`, rebuild |
| Edit to `project.yml` has no effect | Project not regenerated | `xcodegen generate` |
| Watch app fails install/validation with bundle-id complaints | Watch bundle id MUST be the phone id + `.watchkitapp` suffix: `com.davidruiz.fortiche.watchkitapp`, and its Info.plist `WKCompanionAppBundleIdentifier` must equal the phone id | Both are set in `project.yml`; never diverge them when renaming the app (rename points are listed at the top of `project.yml`) |
| Upload/validation rejects mismatched versions across app/watch/widget bundles | Apple requires `CFBundleShortVersionString`/build to match between a watch app (and extensions) and its companion | Versions are defined ONCE in `project.yml` `settings.base` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) and inherited by all three targets — bump them there only, then regenerate |
| `swift test` "unsupported platform" or trying to build for iOS | Tests run on the macOS host | `Package.swift` lists `.macOS("26.0")` **only so `swift test` runs on the host** (comment in the file says so); the apps still target iOS/watchOS 27. Don't remove the macOS platform entry; don't add macOS-incompatible code to FortichePack without `#if canImport` guards |
| Wrong SDK / "iOS 27.0 is not installed" | `DEVELOPER_DIR` not exported in this shell, or runtime missing | Step 1 / Step 4 |
| Live Activity buttons dead, or intent metadata errors in a debug build | Someone flipped `ENABLE_DEBUG_DYLIB` or moved an App Intent into FortichePack | Both are hard rules with an incident behind them — revert; see **fortiche-failure-archaeology** |

## Known-good verification sequence

Run this end-to-end after environment setup, after toolchain updates, or any
time you need to prove the baseline before starting work. All three stages
verified green on 2026-07-05.

```sh
cd /Users/david/Code/Fortiche
export DEVELOPER_DIR=/Applications/Xcode-beta.app

# 0. Regenerate the project (idempotent)
xcodegen generate

# 1. Package tests on the macOS host — expect: "Test run with 64 tests in 14 suites passed"
swift test --package-path FortichePack

# 2. iOS app build — expect: ** BUILD SUCCEEDED **
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination 'generic/platform=iOS Simulator' build

# 3. Watch app build — expect: ** BUILD SUCCEEDED **
xcodebuild -project Fortiche.xcodeproj -scheme ForticheWatch \
  -destination 'generic/platform=watchOS Simulator' build
```

Pass criteria: 64/64 tests passing, both builds end with `** BUILD
SUCCEEDED **`. (Test count is as of 2026-07; if it grew, that's fine — the
criterion is zero failures. If it *shrank*, someone deleted tests: stop and
investigate.) `xcodebuild -project Fortiche.xcodeproj -list` should show
targets Fortiche, ForticheWatch, ForticheWidgets and schemes Fortiche,
FortichePack, ForticheWatch, ForticheWidgets.

Only after this sequence is green, move on to running the app
(**fortiche-run-and-operate**: `--demo-import`, `--skip-health`, etc.).

## Generated artifacts — never hand-edit

For completeness (full rule owned by **fortiche-change-control**): the
`.xcodeproj` (xcodegen), app icons (`swift Scripts/generate_icon.swift
--catalog`), and the bundled exercise dataset (`python3
Scripts/import_exercises.py`) are all generated. Edit the source of truth and
regenerate; never patch the output.

## Provenance and maintenance

Volatile facts and their one-line re-verification commands (all read-only;
prefix with `export DEVELOPER_DIR=/Applications/Xcode-beta.app`):

| Claim (as of 2026-07-05) | Re-verify |
|---|---|
| Xcode 27.0 (27A5194q) at Xcode-beta.app | `xcodebuild -version` |
| XcodeGen 2.45.4 via Homebrew | `brew list --versions xcodegen` |
| iOS 27.0 (24A5355p) + watchOS 27.0 (24R5289n) runtimes installed | `xcrun simctl list runtimes 27` |
| `Fortiche.xcodeproj/` is git-ignored | `grep xcodeproj /Users/david/Code/Fortiche/.gitignore` |
| Signing: `CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM: M9MD9VA4G3`, `ENABLE_DEBUG_DYLIB: NO` in settings.base | `grep -n -e DEVELOPMENT_TEAM -e ENABLE_DEBUG_DYLIB -e CODE_SIGN_STYLE /Users/david/Code/Fortiche/project.yml` |
| Versions defined once in settings.base | `grep -n -e MARKETING_VERSION -e CURRENT_PROJECT_VERSION /Users/david/Code/Fortiche/project.yml` |
| Watch bundle id `com.davidruiz.fortiche.watchkitapp` + `WKCompanionAppBundleIdentifier` | `grep -n -e watchkitapp -e WKCompanionAppBundleIdentifier /Users/david/Code/Fortiche/project.yml` |
| Package platforms include `.macOS("26.0")` for host testing | `grep -n macOS /Users/david/Code/Fortiche/FortichePack/Package.swift` |
| 64 tests / 14 suites, all passing | `swift test --package-path /Users/david/Code/Fortiche/FortichePack` (read the final summary line) |
| Both simulator builds green | Steps 2–3 of the verification sequence |
