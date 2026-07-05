---
name: strength-domain-reference
description: >
  Lifting-domain knowledge as implemented in Fortiche. Load this when you need
  to interpret or change program notation (SxR like "3x5", rep ranges "8-12",
  AMRAP, %1RM, RPE, rest notation, splits like PPL/Upper-Lower/5-3-1), the
  Epley e1RM formula, volume math, plate-math conventions (per-side breakdown,
  bar weights, kg/lb plate sets), the HealthKit workout export model
  (HKWorkoutActivity per exercise, JSON metadata, functional vs traditional
  strength training), or next-day scheduling (last-completed+1 wraparound).
  Also load it before touching TemplateSet/ParsedSet semantics, WorkoutStats,
  PlateCalculator, or ProgramSchedule, or before writing tests that assert
  domain numbers. (Fortiche-specific despite the generic name — the one
  skill in this library without the fortiche- prefix, kept for continuity.)
---

# Strength Domain Reference (Fortiche)

Facts below were verified against the repo on 2026-07-05. File paths are
relative to the repo root. Line numbers drift; symbol names are the stable
handle — `grep -rn "<symbol>" FortichePack/Sources` to re-locate anything.

## When NOT to use this skill

| You actually need | Go to |
|---|---|
| How the two-pass LLM parse works (guided generation, sessions, availability, prompts) | `fortiche-intelligence-reference` |
| Engine/command-sourcing, snapshots, watch-phone authority | `fortiche-architecture-contract` |
| Building, SDKs, xcodegen, DEVELOPER_DIR | `fortiche-build-and-env` |
| Running sims, launch args (`--demo-import` etc.), log capture | `fortiche-run-and-operate` |
| Live-sync device testing (mirroring, WC) | `fortiche-device-sync-campaign` |
| Why a past incident forbids something | `fortiche-failure-archaeology` |

This skill is the one-home for *what the lifting numbers and notations mean* —
formulas, units, notation → model mapping, HealthKit export shape, scheduling
semantics.

## Glossary (one-time definitions)

- **Set / rep**: a *set* is a group of consecutive repetitions (*reps*) of one
  exercise. "3x5" = 3 sets of 5 reps.
- **AMRAP**: "As Many Reps As Possible" — an open-ended set with no rep target.
- **RPE**: Rate of Perceived Exertion, a 1–10 subjective effort scale
  (10 = could not do another rep). A *target*, not a measurement.
- **1RM / %1RM**: one-rep max — the heaviest weight liftable for a single rep.
  Programs often prescribe load as a percentage of it ("5x5 @ 75%").
- **e1RM**: *estimated* 1RM computed from a submaximal set (see Epley below).
- **Volume**: total work proxy, Σ (reps × weight) over some scope.
- **Split**: how training is divided across days. **PPL** = Push/Pull/Legs
  (3-day cycle), **Upper/Lower** (2-day cycle), **5/3/1** = Wendler's program
  whose top sets are 5, then 3, then 1 rep at rising %1RM.
- **Plate math**: which plates to load *per side* of a barbell to reach a
  target total, given the bar's own weight.

## 1. Program notation the parsers must honor

Two parsers produce the same `ParsedProgram` shape
(`FortichePack/Sources/FortichePack/Parsing/ParsedProgram.swift`):

- `HeuristicLineParser` — deterministic regex, always available, the fallback
  and the reference for tests (`Parsing/HeuristicLineParser.swift`).
- `IntelligentProgramParser` — FoundationModels guided generation, set-GROUP
  schema (`Parsing/TemplateParser.swift`). Mechanics live in
  `fortiche-intelligence-reference`; only the *semantics* both must honor are
  here.

### Notation → model mapping

| Notation | Example | Parsed as | Heuristic parser? |
|---|---|---|---|
| SxR | `Squat 3x5` | 3 `ParsedSet`s, repsMin=repsMax=5. `×` normalized to `x` | Yes |
| Rep range | `3x8-12` | repsMin=8, repsMax=12 (en-dash `–` accepted) | Yes |
| AMRAP | `Dips 3xAMRAP` | repsMin=repsMax=**0** (0/0 = open set, see TemplateSet doc) | Yes |
| Absolute weight | `@ 100kg`, `80 kg`, `225 lb`, `225#` | `weightKg` in **canonical kilograms**, converted at parse time | Yes |
| Bare number weight | `@ 100` | Weight in `defaultUnit` — but **only when preceded by `@`** (avoids eating `rest 90`) | Yes |
| %1RM | `@ 65%` | `percentOfMax` = 65 (0–100), `weightKg` stays nil | Yes |
| RPE | `4x12 RPE 8` | `rpe` = 8.0 | Yes |
| Rest | `rest 90s`, `rest 2min`, `R90`, `repos 120` | `restSeconds` (min → ×60); French `repos` accepted | Yes |
| Varying sets | `5/3/1` (three different top sets) | Multiple `GeneratedSetGroup`s, one per distinct prescription | **No — LLM path only.** The heuristic regex requires `\d+x(\d+|amrap)`; a `5/3/1` line parses to nil and is dropped |

Rules encoded in both paths:

- One load spec per set: absolute `weightKg` **or** `percentOfMax` **or**
  RPE-guided (nil weight + `rpe`). `TemplateSet` doc comment states this
  ("at most one load spec") — don't add code that fills two.
- Weight is stored in kg, always. `WeightUnit.toKilograms` /
  `fromKilograms` at boundaries only (`Units/Weight.swift`,
  `poundsPerKilogram = 2.204622621848776`).
- Zero-means-unset sanitation (hard rule R6): the on-device model emits `0`
  for "not specified". At conversion (`ParsedDay.init(generated:)` in
  `Parsing/TemplateParser.swift`): weight ≤ 0 → `weightKg = nil`
  (bodyweight), percent ≤ 0 → nil, restSeconds ≤ 0 → nil (then default 90),
  `setCount` clamped to 1...30.
- Default rest when unspecified: **90 s**, applied at
  `ParsedProgram.makeTemplate` (`restSeconds: exercise.restSeconds ?? 90`)
  and as the `TemplateExercise` init default.
- Exercise naming: keep the name *as written* (`OHP` stays `OHP` in
  `name`); the optional `librarySlug` link is fuzzy-matched separately
  (`ExerciseLibrary/ExerciseMatcher.swift` — alias table maps `ohp` →
  "shoulder press" because the dataset never says "overhead press", R6).

### Day segmentation and splits

`Parsing/ProgramSegmenter.swift` (deterministic pass 1) decides day
boundaries: markdown headers, `Day`/`Week` (+ French `Jour`/`Semaine`)
prefixes, weekday names (EN+FR), or short colon-terminated lines
("Push A:"). Lines containing SxR notation or `@` are never headers.
Bodyless chunks (rest days, trailing headers, title preamble) are dropped.

Split names imply nothing structural: a PPL, Upper/Lower, or 5/3/1 program
all become the same thing — an ordered `[TemplateDay]` (explicit `order`
field, CloudKit rule) cycled by wraparound (section 6). Weekday headers
become day *names* only; nothing binds a day to a calendar weekday.
`Parsing/ProgramNamer.swift` derives the program name from day names
("Push A"/"Pull A"/"Legs" → "Push/Pull/Legs"; all-generic names → "N-Day
Program").

## 2. Epley e1RM as implemented

`FortichePack/Sources/FortichePack/Stats/WorkoutStats.swift`:

```swift
estimatedOneRepMax(weightKg:reps:)
// reps <= 0 → 0
// reps == 1 → weightKg          (no inflation for an actual single)
// else      → weightKg * (1 + reps/30)
```

Known limits — state these when surfacing numbers, don't "fix" silently:

- Epley **overestimates at high reps** (a 20-rep set claims 1.67× the set
  weight); there is deliberately no rep cap in the formula. AMRAP sets logged
  with high actual reps therefore produce optimistic PRs.
- All e1RM values are kg; convert only at display.
- `personalRecords(from:)` keys by `librarySlug` **else lowercased name** —
  renaming a free-form exercise splits its PR history; matching it to a
  library slug merges history across spellings. Only sets with
  `completedAt != nil`, `weight > 0`, `reps > 0` count (pure bodyweight work
  never sets a PR).
- `lastPerformance(ofSlug:name:before:in:)` — the "previous performance
  ghost" in `Fortiche/WorkoutSession/LiveWorkoutView.swift` — returns the
  heaviest completed set of the most recent prior session, same key rule.

Verified by `FortichePack/Tests/FortichePackTests/StatsTests.swift`
(100 kg × 5 → ~116.667; reps 0 → 0).

### %1RM at workout time — plumbed, not yet wired (as of 2026-07)

`WorkoutState.start(day:host:bodyMassKg:oneRepMaxes:now:)`
(`Engine/WorkoutState.swift`) resolves `percentOfMax` into a concrete
`weightKg` only when the caller passes `oneRepMaxes` keyed by `librarySlug`
(`weight = max * percent / 100`). Both current callers —
`Fortiche/WorkoutSession/PhoneWorkoutController.swift` and
`ForticheWatch/WatchWorkoutController.swift` — use the default empty
dictionary, so %1RM sets currently start with nil weight (displays as
bodyweight; user sets it mid-workout). Feeding
`WorkoutStats.personalRecords` output into these call sites is the obvious
candidate wiring — treat as unbuilt until you see it in the callers.

## 3. Volume

Canonical definition: **Σ reps × weightKg** over completed sets. Two homes,
keep them consistent:

- `WorkoutLog.totalVolumeKg` (`Engine/HealthKitExport.swift`) — one log.
- `WorkoutStats.dailyVolume(from:calendar:)` — per **calendar day**
  (`calendar.startOfDay(for: log.startedAt)`), ascending; drives the History
  chart (`Fortiche/HistoryView.swift`).

Why per-day, not per-log: two sessions on one day (e.g. a discarded restart,
or AM/PM sessions) should read as one training day in trend charts, and
day-bucketing is what makes week-over-week comparisons stable. Note
`WorkoutLog` only ever contains *completed* sets (`WorkoutState.makeLog`
filters `completedAt != nil`), so no completion filter is needed at the
stats layer. `weightKg == nil` (bodyweight) contributes 0 — bodyweight
volume is intentionally not counted.

## 4. Plate math

`FortichePack/Sources/FortichePack/Units/PlateCalculator.swift` — pure value
logic, unit-tested (`Tests/FortichePackTests/PlateCalculatorTests.swift`).

Conventions:

- **Per-side** breakdown: `remainingPerSide = (target − barWeight) / 2`,
  greedy largest-first. Greedy is exact for these standard denominations.
- Plate sets (one side): kg `25/20/15/10/5/2.5/1.25`; lb `45/35/25/10/5/2.5`.
- Bar weight is a parameter in **kg** (`barWeightKg`, default 20) even in lb
  mode; a "45 lb bar" is `barWeightKg: 20.4116` (see the pounds test). The
  Settings plate-calculator UI (`Fortiche/Settings/SettingsView.swift`,
  `PlateCalculatorView`) offers 20/15/10 kg bars and steppers in display
  units over a canonical-kg `@State`.
- Target below bar weight → empty `perSide`, `achievedTotal = barWeight`
  ("Just the bar").
- Non-divisible targets **round down**: `Result.isExact == false` and
  `achievedTotal ≤ target` (101 kg on a 20 kg bar → 100 kg). The UI shows
  "Closest reachable". Never round up — loading more than asked is the wrong
  failure mode for a lifter.
- `plates(forTotal:)` takes the display unit; `plates(forTotalKg:)` converts
  first. Comparison epsilon 0.0001 guards float drift on 2.5/1.25 plates.

## 5. HealthKit workout model as used here

| Concern | Watch session | Phone-only session |
|---|---|---|
| Controller | `ForticheWatch/WatchWorkoutController.swift` | `Fortiche/WorkoutSession/PhoneWorkoutController.swift` |
| Recording API | `HKWorkoutSession` + `HKLiveWorkoutBuilder` (live heart rate) | `HKWorkoutBuilder` only — the codebase treats `HKWorkoutSession` as watch-only; no workout background mode on iOS, rest alerts are local notifications |
| Mirror peer | phone `MirroringReceiver` holds the mirrored `HKWorkoutSession` (see `fortiche-architecture-contract`, R2/R3) | none |
| Crash recovery | `healthStore.recoverActiveWorkoutSession` + engine journal (R5: re-check `engine == nil` in the completion) | engine journal only |

Export shape, shared via `WorkoutState.makeHealthKitActivities()`
(`FortichePack/Sources/FortichePack/Engine/HealthKitExport.swift`):

- **One `HKWorkoutActivity` per exercise** that has ≥1 completed set, so the
  structure shows in Apple Health/Fitness. Exercises with zero completed
  sets export nothing.
- Set details ride as a JSON **string** in activity metadata under key
  `com.davidruiz.fortiche.exercise` (`WorkoutState.exerciseMetadataKey`) —
  HealthKit metadata values must be scalars, hence JSON-in-a-string. Payload:
  `{"name", "librarySlug", "sets": [{"reps", "weightKg"}]}`.
- Activity timeline: start = first set completion − 45 s (nominal set
  duration), clamped to workout start; end = last set completion.
- Activity type: `WorkoutTemplate.activityKind`
  (`StrengthActivityKind` in `Models/TemplateModels.swift`) —
  `.functional` (default) → `.functionalStrengthTraining`,
  `.traditional` → `.traditionalStrengthTraining`. Applied to both the
  top-level workout configuration and each per-exercise activity.
- **Under-3-minute discard**: `WorkoutState.minimumSaveDuration = 3 * 60`;
  `qualifiesForSaving` gates *everything* — no `WorkoutLog`, builder gets
  `discardWorkout()` instead of `finishWorkout()`, watch queues nothing to
  the phone (it still sends the final snapshot so the phone tears down its
  mirror UI).
- Recording is best-effort: HealthKit denial never blocks the workout.
  `--skip-health` suppresses the auth sheet for headless runs (see
  `fortiche-run-and-operate`).
- Saved logs upsert by `WorkoutLog.uuid` (dual delivery channels), and
  logs/HealthKit both derive from the same `WorkoutState` — never compute
  one from the other.

## 6. Next-day scheduling semantics

`FortichePack/Sources/FortichePack/Stats/ProgramSchedule.swift` — shared by
the phone list (`Fortiche/RootView.swift`), the watch list
(`ForticheWatch/ForticheWatchApp.swift`), and intended for widgets/Siri.

- `nextDay(in:logs:)`: find the most recent log with this template's
  `templateUUID` and a non-nil `dayUUID`; suggest `days[(lastIndex + 1) %
  days.count]` — **last-completed + 1 with wraparound**. No history, or the
  logged day was deleted from the template → first day. Discarded (<3 min)
  sessions never became logs, so they don't advance the cycle.
- `activeTemplate(in:logs:)`: the template trained most recently (by
  `startedAt`), else the first.
- Consequence of the wraparound model: skipping a calendar day never skips a
  training day; repeating "Push" twice in a row advances to "Pull" next
  either way (the *latest* log wins). There is no weekday scheduling — by
  design, matching how lifters actually run PPL/Upper-Lower cycles.

## Quick reference card

| Fact | Value |
|---|---|
| Canonical weight unit | kilograms, everywhere in models; convert at display (`WeightUnit`) |
| lb per kg | 2.204622621848776 |
| Epley e1RM | `weight × (1 + reps/30)`; reps 1 → weight; reps ≤ 0 → 0 |
| AMRAP encoding | repsMin = repsMax = 0 |
| Bodyweight/unset weight | `weightKg = nil` (LLM's 0 sanitized to nil) |
| Default rest | 90 s |
| Volume | Σ reps × weightKg, bodyweight counts 0, bucketed per calendar day |
| kg plates (per side) | 25, 20, 15, 10, 5, 2.5, 1.25 |
| lb plates (per side) | 45, 35, 25, 10, 5, 2.5 |
| Bars in UI | 20 / 15 / 10 kg; 45 lb bar ≙ 20.4116 kg |
| HK metadata key | `com.davidruiz.fortiche.exercise` |
| Discard threshold | 3 minutes (`WorkoutState.minimumSaveDuration`) |
| Next day | (index of last logged day + 1) mod day count |

## Provenance and maintenance

All claims re-verifiable read-only. Run from the repo root; prefix Swift/xcodebuild work with `export DEVELOPER_DIR=/Applications/Xcode-beta.app`.

```bash
# Epley formula, PR keying, daily volume
grep -n "1 + Double(reps) / 30\|librarySlug ?? \|startOfDay" FortichePack/Sources/FortichePack/Stats/WorkoutStats.swift
# Notation regexes (SxR, %, RPE, rest) in the heuristic parser
grep -n "amrap\|rpe\|rest\|%" FortichePack/Sources/FortichePack/Parsing/HeuristicLineParser.swift
# Zero-means-unset sanitation + set-group expansion
grep -n "<= 0\|min(30" FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift
# Plate sets and bar weights
grep -n "plates = \|barWeightKg" FortichePack/Sources/FortichePack/Units/PlateCalculator.swift
# HK metadata key, per-exercise activity, -45s heuristic
grep -n "exerciseMetadataKey\|addingTimeInterval(-45)" FortichePack/Sources/FortichePack/Engine/HealthKitExport.swift
# 3-minute discard + %1RM resolution hook
grep -n "minimumSaveDuration\|percentOfMax" FortichePack/Sources/FortichePack/Engine/WorkoutState.swift
# %1RM still unwired? (empty oneRepMaxes at call sites — no extra args means yes)
grep -rn "WorkoutState.start(" Fortiche ForticheWatch --include="*.swift"
# Wraparound scheduling
grep -n "% days.count" FortichePack/Sources/FortichePack/Stats/ProgramSchedule.swift
# Default rest = 90
grep -n "?? 90\|restSeconds: Int = 90" FortichePack/Sources/FortichePack/Parsing/ParsedProgram.swift FortichePack/Sources/FortichePack/Models/TemplateModels.swift
# Domain tests still green (all package tests must pass; count baseline: fortiche-build-and-env)
swift test --package-path FortichePack
```
