---
name: fortiche-validation-and-qa
description: >
  How to prove a Fortiche change works: which unit-test suite protects what,
  how to run and add Swift Testing tests, when the real-model (Apple
  Intelligence) integration tests run, the manual two-device smoke script, and
  the acceptance-evidence rules (screenshots for UI claims, log lines for sync
  claims, never trusting simulator mirroring). Load this when you are about to
  claim "it works", "tests pass", "verified", or "done"; when adding or
  modifying tests in FortichePack/Tests; when deciding what evidence a change
  needs before adoption; or when planning a QA pass before release.
---

# Fortiche validation and QA

This skill defines what counts as **evidence** in this repo and how to produce
it. A claim without the matching evidence class below is an opinion, not a
verification.

Jargon used once and defined here:

- **Engine** — `ActiveWorkoutEngine` (FortichePack/Sources/FortichePack/Engine/),
  the command-sourced state machine for a live workout. Every mutation is a
  sequence-numbered `WorkoutCommand` envelope; duplicates are dropped per
  origin via `state.lastAppliedSeq`.
- **Mirroring** — HealthKit's `HKWorkoutSession` companion channel
  (watch-authoritative live sync). It does **not** work between paired
  simulators; see the hard rule below.
- **Swift Testing** — Apple's `import Testing` framework (`@Suite`, `@Test`,
  `#expect`, `#require`), used for all FortichePack tests. Not XCTest.

## When NOT to use this skill

- Build fails or toolchain problems (DEVELOPER_DIR, xcodegen, SDKs) →
  **fortiche-build-and-env**.
- You are diagnosing *why* something broke, not proving it works →
  **fortiche-debugging-playbook**; past incidents behind the rules here →
  **fortiche-failure-archaeology**.
- Launching the app, demo launch args, simulator seeding →
  **fortiche-run-and-operate**; log capture / simctl recipes →
  **fortiche-diagnostics-and-tooling**.
- What the architecture guarantees (engine invariants, sync channels, model
  rules) → **fortiche-architecture-contract**. Whether a change is allowed at
  all, and adoption sign-off → **fortiche-change-control**.
- Running the real-device sync test matrix end to end →
  **fortiche-device-sync-campaign** (this skill only defines the smoke script
  and its evidence bar).
- Parser/LLM behavior details (guided generation, set-group schema, model
  quirks) → **fortiche-intelligence-reference**. Release/TestFlight checks →
  **fortiche-appstore-and-release**.

## The evidence ladder (acceptance discipline)

Match the claim to the evidence class. Weaker evidence does not substitute.

| Claim | Required evidence |
|---|---|
| "Logic is correct" | `swift test` output, all green, including a test that would have failed before the change |
| "UI shows/does X" | Screenshot (`xcrun simctl io <udid> screenshot out.png`) or other simctl-observable artifact from a real run — not a code read |
| "Sync/transfer happened" | Actual log lines from **both** sides (`log show --info` / `log stream --level info`), showing the send and the receive |
| "Mirroring / live watch→phone works" | **Real devices only.** Simulator evidence is inadmissible — see below |
| "Saved to HealthKit / History" | Entry visible in the Health app (or HK query output) *and* the History tab after the run |
| "Crash-recovery works" | Kill + relaunch demonstrated, journal restored state observed |

Hard rules that bound what evidence can prove (incidents behind each — see
**fortiche-failure-archaeology**):

1. **Never claim mirroring works from simulator evidence.** Between paired
   simulators, watch-side healthd fails with HK error 300 (Rapport
   `kNotFoundErr`), *and* `startMirroringToCompanionDevice()` resolves without
   error anyway — a successful call proves nothing. Only the app-level
   snapshot handshake observed on **real devices** proves the production path.
   Simulators exercise the WatchConnectivity debug transport instead
   (docs/SPIKE-M1.5.md).
2. **A silent WC send is not a delivered WC send.** Sends during reachability
   blips are cancelled without error (`shouldCancel: YES`). Evidence of
   delivery is a receive-side log line, never a send-side one.
3. **One mechanism must explain all observations — including the negative
   results.** Before adopting a fix or a conclusion, write down every
   observation from the investigation (what happened *and* what conspicuously
   did not) and check the proposed mechanism explains each one. If any
   observation needs a second mechanism or a shrug, you have not found the
   cause yet. This rule caught the App Intents incident: "buttons do nothing"
   plus "no error anywhere" were only jointly explained by linkd indexing
   nothing for the bundle.

Simulator log gotchas (evidence you will otherwise silently miss):
`log show` needs `--info`, `log stream` needs `--level info`, or `Logger.info`
lines are invisible. Full recipes: **fortiche-diagnostics-and-tooling**.

## Unit tests: what exists and what each protects

All automated tests live in `FortichePack/Tests/FortichePackTests/` (11 files,
14 `@Suite`s, 64 tests, all passing as of 2026-07-05 — the count includes the
2 real-model tests when the host has Apple Intelligence). Run them from the
repo root:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
swift test --package-path FortichePack               # everything
swift test --package-path FortichePack --filter EngineTests   # one suite
```

macOS host is fine — the package is pure Swift logic. There are no UI tests;
UI verification is manual + screenshots (evidence ladder above).

| File | Suite(s) | Protects |
|---|---|---|
| `EngineTests.swift` | `EngineTests` (@MainActor, 10 tests) | Engine transitions (complete set → rest phase with correct deadline, exercise advance, no rest after final set), add/remove set cloning prescriptions, rest adjust/skip, **per-origin dedup** (`duplicateAndStaleEnvelopesAreIgnored`), **snapshot reconciliation** (`staleSnapshotsAreRejectedFreshOnesAdopted` — the `lastAppliedSeq` staleness gate), **disk journal** round-trip restoring mid-workout state, end-of-workout log contains only completed work, snapshot message wire round-trip |
| `ParsingTests.swift` | `SegmenterTests`, `HeuristicLineParserTests`, `HeuristicProgramParserTests` | Pass-1 deterministic day segmentation (headers vs exercise lines, weekday/"Day N"/headerless), line-parser fixtures (3x5 @ kg, rep ranges, AMRAP/bodyweight, percent+rest, RPE, lb-in-name, non-exercise lines → nil), end-to-end heuristic parse through the `ProgramParsing` protocol with `usedFallback` set, conservative canonicalization, `makeTemplate` structure preservation |
| `IntelligentParserTests.swift` | `IntelligentParserTests` (availability-gated) | The **real** FoundationModels path — see next section |
| `ExerciseMatcherTests.swift` | `ExerciseMatcherTests` (7 tests) | Fuzzy matching against the **real bundled dataset**: shorthand aliases (OHP → shoulder press — the dataset never says "overhead press"), hyphen/plural variants, typo tolerance (Damerau-Levenshtein), garbage returns nothing, auto-assign stays conservative |
| `ExerciseLibraryTests.swift` | `ExerciseLibraryTests` | Bundled free-exercise-db resource integrity: loads with >800 entries, slugs unique and resolvable, fields usable, image URLs resolve. Fails if `Scripts/import_exercises.py` output regresses |
| `PlateCalculatorTests.swift` | `PlateCalculatorTests` | Plate math: exact kg and lb breakdowns, below-bar-weight → no plates, non-divisible loads round down and flag inexact |
| `ProgramScheduleTests.swift` | `ProgramScheduleTests` (@MainActor) | Next-day suggestion: first day when no history, day-after-last-logged, wrap-around, most-recent-log wins over array order, deleted day falls back, active template = most recently trained |
| `ProgramNamerTests.swift` | `ProgramNamerTests`; `WorkoutSavingRuleTests` (@MainActor) | Template auto-naming (join/collapse/fallback-to-count); the **discard-under-3-minutes rule** (`WorkoutState.minimumSaveDuration = 3 * 60`, `qualifiesForSaving`, un-ended workouts measured to now) |
| `StatsTests.swift` | `StatsTests` (@MainActor) | Epley e1RM, PRs take best e1RM, last-performance lookup finds most recent prior session, daily volume aggregation |
| `ModelTests.swift` | `ModelTests` (@MainActor) | SwiftData template graph round-trips through a real (in-memory) store; `ordered*` accessors sort by explicit `order` fields regardless of insertion order — the CloudKit-compatibility contract in CLAUDE.md |
| `WeightTests.swift` | `WeightTests` | kg↔lb known values, parameterized round-trip stability, display formatting, locale unit defaults — guards the "kilograms canonical, convert at display only" rule |

If you change engine, parsing, matching, schedule, stats, models, units, or
the dataset importer and no suite in this table went red first, ask whether
your change is actually covered — and add a test (below) before claiming done.

## Real-model integration tests (Apple Intelligence)

`IntelligentParserTests.swift` hits the **actual on-device foundation model** —
no mock. Gating:

```swift
@Suite(.enabled(if: IntelligentProgramParser.availability == .available))
```

- **Runs** on hosts where Apple Intelligence is available (this Mac, real
  devices). **Skips itself** on CI without the model and on simulators
  without host AI — a skip is normal, not a failure.
- Each test carries `.timeLimit(.minutes(3))`; a real run takes ~6–9 s per
  test on this Mac (as of 2026-07).
- What it proves: two-pass guided generation produces correct set expansion
  (set-group schema), rep ranges, lb→kg conversion, percent-of-max kept
  separate from absolute weight, and the LLM zero-means-unset sanitization
  (`0` reps for AMRAP, no phantom weights). Model quirk background:
  **fortiche-intelligence-reference**.
- **Nondeterminism caveat:** temperature is 0 but the model can still drift
  across OS betas. A one-off failure here is a *finding to investigate*
  (did the model change? did the prompt/schema change?), not automatically a
  regression in your diff — but never dismiss it without identifying the
  mechanism (evidence rule 3).

Watch-side note: there is no on-watch local model on watchOS 27
(`SystemLanguageModel` and `@Generable` are unavailable), so there is no
watch-parser test surface — parsing is iPhone-side only.

## Adding tests: the patterns this repo uses

Swift Testing, not XCTest. Follow the existing conventions:

```swift
import Foundation
import Testing
@testable import FortichePack

@MainActor                       // required for suites touching SwiftData or the engine
@Suite struct MyFeatureTests {
    @Test func doesTheThing() throws {
        let container = try ForticheStore.container(.inMemory)   // real store, in memory
        let context = container.mainContext
        // ... insert, save, fetch ...
        let fetched = try #require(try context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        #expect(fetched.orderedDays.count == 1)
    }

    @Test(arguments: [0.0, 2.5, 60, 102.5])   // parameterized (see WeightTests)
    func roundTrips(_ kg: Double) { /* ... */ }
}
```

House rules observed in the existing suites:

- `#expect` for assertions, `try #require` to unwrap-or-fail; `Issue.record`
  when a `guard case` pattern can't use either (see
  `EngineTests.completeSetStartsRestAndRecordsActuals`).
- `@MainActor` on the whole suite when it touches SwiftData
  (`ForticheStore.container(.inMemory)`) or `ActiveWorkoutEngine` — both are
  main-actor-bound. Pure-value suites (weights, plates, segmenter) stay
  nonisolated.
- Engine tests build a `WorkoutState` fixture and drive `engine.submit(...)`;
  journal tests pass a temp-file `journalURL` and rebuild the engine from it.
- Async model-touching tests get `.timeLimit(...)`; availability-dependent
  suites get `.enabled(if:)` so they skip instead of fail.
- Fixtures are inline string literals (see `SegmenterTests.ppl`) — no fixture
  files, keeps tests copy-paste runnable.
- `@Sendable` closure capture helper: the `Collector` class at the bottom of
  `ParsingTests.swift`; reuse it rather than inventing new lock dances.
- Tests live in the package. If your logic is in an app target and you want
  to test it, that is usually the signal to **move the logic into
  FortichePack** (CLAUDE.md: "logic belongs in FortichePack") — but never move
  App Intents into the package (hard rule R1; see
  **fortiche-failure-archaeology**).

## Manual two-device smoke script

This is the minimum end-to-end pass for any change touching sync, the engine,
workout saving, or the Live Activity. **Real iPhone + real Watch, both on
27.0** — items 2–3 are meaningless on simulators (evidence rule 1). Device
setup and pairing: **fortiche-device-sync-campaign**; launching and demo
seeding: **fortiche-run-and-operate**.

For each step, capture the evidence listed — the artifact is the pass, not
your recollection.

| # | Step | Pass criteria | Evidence to capture |
|---|---|---|---|
| 1 | **Template push** phone→watch: import or create a template on the phone; open the watch app | Template catalog appears on the watch (WC applicationContext; buffered until WC activation, so a cold watch may lag — relaunch once before calling it a failure) | Watch screenshot of the catalog; phone+watch log lines for the applicationContext send/receive |
| 2 | **Watch-started workout raises the phone mirror**: start a workout day on the watch with the phone locked/backgrounded | Phone gets the mirrored session in the background, Live Activity appears within seconds (placeholder first is fine — the ~10 s handler window is by design, rule R3) | Photo/screenshot of the Live Activity; phone log showing `workoutSessionMirroringStartHandler` fired |
| 3 | **Mid-set phone edit reconciles**: while the watch session runs, complete a set / edit weight from the phone UI | Watch state reflects the phone's command; no duplicate set, no lost edit after the echoed snapshot returns (watch is authoritative; phone is the optimistic peer) | Both-side logs showing the command envelope and the snapshot echo; screenshots of matching state on both screens |
| 4 | **Discard-under-3-minutes**: start a workout, end it before 3:00 elapsed | No History entry, no HealthKit workout (`qualifiesForSaving == false`) | History tab screenshot (empty of it) + Health app check |
| 5 | **History + Health save**: run a workout past 3:00 with at least one completed set, end it | Exactly **one** entry in History (finished workouts arrive over dual channels — transferUserInfo and the mirror path — and upsert by UUID; two entries = dedup regression) and one HK workout | History screenshot, Health app screenshot, log lines for the transferUserInfo delivery |

Also worth one deliberate pass when touching sync: toggle airplane mode on
the watch mid-workout, restore it, and confirm both sides resync on
`sessionReachabilityDidChange` (rule R4) — the failure mode is silent.

## Evidence bar for adopting a change

Before marking a change done (and before **fortiche-change-control** sign-off):

- [ ] `swift test --package-path FortichePack` green, run *after* the final edit.
- [ ] New behavior has a test that fails on the pre-change code, where the
      behavior is package-testable.
- [ ] Both platform builds succeed if any target source or `project.yml`
      changed (`xcodegen generate` first — commands in **fortiche-build-and-env**).
- [ ] Every user-visible claim in your summary is backed by an evidence-ladder
      artifact, correctly classed (no simulator evidence for mirroring claims).
- [ ] One mechanism explains all observations, including negatives. If two
      explanations remain, the investigation is not over.
- [ ] Nothing generated was hand-edited (icons, dataset, xcodeproj,
      screenshots) — regenerate via Scripts/ instead (rule R8).

## Provenance and maintenance

Facts above verified against the repo on 2026-07-05. Re-verify with:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
# test count / suites / all green (drifts with every added test):
swift test --package-path FortichePack 2>&1 | tail -1
# suite inventory:
grep -rn "@Suite" FortichePack/Tests/FortichePackTests/
# real-model gating still availability-based:
grep -n "enabled(if:" FortichePack/Tests/FortichePackTests/IntelligentParserTests.swift
# 3-minute rule constant:
grep -n "minimumSaveDuration" FortichePack/Sources/FortichePack/Engine/WorkoutState.swift
# dedup/staleness gate symbol:
grep -n "lastAppliedSeq" FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift
# simulator-mirroring verdict still current for this beta:
sed -n '1,20p' docs/SPIKE-M1.5.md
```

Volatile items: the 64-test/14-suite count; the ~6–9 s real-model test timing;
the simulator mirroring verdict (re-run the spike on each new Xcode/OS beta);
"no UI tests" (revisit if an XCUITest target is ever added to project.yml).
