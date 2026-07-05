# Fortiche

iOS 27 / watchOS 27 **exclusive** strength-training app (iPhone + optional Apple Watch).
"Fortiche" is a working codename; rename points live at the top of `project.yml`.

Full architecture/decisions: `/Users/david/.claude/plans/synchronous-strolling-panda.md`.

## Layout

- `project.yml` — XcodeGen definition (the `.xcodeproj` is generated, git-ignored). Edit YAML, then regenerate.
- `FortichePack/` — local SwiftPM package: SwiftData models, units, exercise library, (workout engine + sync protocol from M3).
- `Fortiche/`, `ForticheWatch/`, `ForticheWidgets/` — app-target sources only; logic belongs in FortichePack.
- `ThirdParty/free-exercise-db/` — raw public-domain exercise dataset (credited in the in-app licenses screen).
- `Scripts/import_exercises.py` — regenerates the bundled dataset resource from ThirdParty.

## Build & test

Xcode 27 beta is required and is NOT the selected toolchain — prefix commands:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
xcodegen generate                      # after any project.yml change
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Fortiche.xcodeproj -scheme ForticheWatch -destination 'generic/platform=watchOS Simulator' build
swift test --package-path FortichePack # unit tests (macOS host is fine for pure-Swift logic)
```

## Rules

- Weights are stored in **kilograms** everywhere; convert only at display/input via `WeightUnit`.
- SwiftData models must stay CloudKit-compatible: optional/defaulted properties, no unique constraints, optional relationships with inverses, explicit `order` fields (use the `ordered*` accessors).
- The exercise library is read-only reference data, never inserted into the synced store; templates point at it via `librarySlug` (optional — free-form exercise names are valid).
- Watch store is local-only (`ForticheStore.container(.watch)`); anything crossing devices goes through the sync protocol, not CloudKit.
- `workoutSessionMirroringStartHandler` must be installed synchronously in `ForticheApp.init` (background launch drops the session otherwise).
