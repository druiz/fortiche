---
name: fortiche-research-frontier
description: >
  Fortiche's open research problems and how to attack them: on-device adaptive
  load progression, photo-of-a-program import via iOS 27 FoundationModels image
  Attachments, Private Cloud Compute for long/messy program parsing, watch-side
  coaching within the no-local-model constraint, HealthKit workout-zone
  adoption for strength training, and an open program-exchange text format.
  Load this when someone asks "what should we research next", "can Fortiche do
  X with AI", proposes a new intelligent/experimental feature, wants to run an
  experiment against workout history, asks about vision/image parsing, PCC,
  HKWorkoutZoneConfiguration, or program interchange formats — or when you are
  about to prototype anything speculative and need the evidence bar and the
  flag-gating rules that apply before code touches main paths.
---

# Fortiche research frontier

This skill is the research agenda: six open problems where a small open-source
app with a complete local dataset and a command-sourced engine can produce
results the incumbents structurally cannot. Each problem states why the
current state of the art falls short, what asset this repo already has, the
first three concrete steps *in this repo*, and a falsifiable "you have a
result when…" milestone.

Fortiche in one paragraph (details live in `fortiche-architecture-contract`):
an iOS 27 / watchOS 27 strength-training app. Every workout mutation is a
sequence-numbered `WorkoutCommand` applied by `ActiveWorkoutEngine`
(`FortichePack/Sources/FortichePack/Engine/`). Finished sessions land as
`WorkoutLog → LoggedExercise → LoggedSet` SwiftData models
(`FortichePack/Sources/FortichePack/Models/LogModels.swift`), weights
canonically in kilograms. Template import runs Apple's on-device
FoundationModels with a deterministic regex fallback
(`FortichePack/Sources/FortichePack/Parsing/`). There is no server and no
analytics — the App Store privacy stance is "Data Not Collected".

## When NOT to use this skill

- How the existing LLM import pipeline works today → `fortiche-intelligence-reference`
- Whether a change is allowed to land / promotion gates → `fortiche-change-control`
- Architectural invariants you must not break while prototyping → `fortiche-architecture-contract`
- Build/toolchain commands (`DEVELOPER_DIR`, xcodegen, SDKs) → `fortiche-build-and-env`
- Running the app, simulators, demo seeding, launch args → `fortiche-run-and-operate`
- Debugging a failure in an experiment → `fortiche-debugging-playbook`, `fortiche-diagnostics-and-tooling`
- Past experiments that failed and why → `fortiche-failure-archaeology`
- Training-domain terms used below (e1RM, RPE, AMRAP, progression) → `strength-domain-reference`
- Test matrices for promoted features → `fortiche-validation-and-qa`
- Shipping any of this → `fortiche-appstore-and-release`
- Real-device sync verification (several milestones below need real devices) → `fortiche-device-sync-campaign`

## The evidence bar (non-negotiable methodology)

Research in this repo follows four rules. They exist because vibes-based "the
AI feels smarter" claims are unfalsifiable and have burned us before.

1. **Predict numbers before you run.** Every hypothesis is written down with
   its expected quantitative outcome *before* the experiment executes
   ("suggestion acceptance will exceed 60% vs. a 45% baseline"). If you did
   not pre-register the number, you are doing archaeology, not science.
2. **One mechanism explains all observations.** A result is not understood
   until a single causal story accounts for every data point, including the
   weird ones. Two half-explanations are zero explanations. (This is the same
   bar `fortiche-debugging-playbook` applies to bugs.)
3. **Negative results get archived.** A cleanly falsified hypothesis is a
   deliverable. Write it up in `fortiche-failure-archaeology` format: what was
   predicted, what happened, the mechanism, what it rules out. The mirroring
   spike (`docs/SPIKE-M1.5.md`) is the house style — its "simulators cannot
   mirror" negative saved every later milestone.
4. **Ideas live behind launch args or flags until promoted.** Experimental
   code paths are gated the way `--demo-import` / `--demo-workout` /
   `--skip-health` are gated in `Fortiche/RootView.swift` — an explicit
   `ProcessInfo.processInfo.arguments.contains(...)` check, default off, no
   effect on normal users. Promotion out of a flag goes through
   `fortiche-change-control`. Never wire an experiment into the engine's
   command flow, the sync channels, or the SwiftData schema without that
   review — schema changes especially, because models must stay
   CloudKit-compatible (see `fortiche-architecture-contract`).

Verification setup used throughout (as of 2026-07, Xcode 27 beta):

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
swift test --package-path FortichePack   # all tests must pass (count baseline: fortiche-build-and-env)
```

---

## Problem 1 — On-device adaptive progression

**The question.** Can an on-device model, given a lifter's complete history,
propose next-session loads that users accept unmodified more often than a
static progression rule does?

**Why SOTA falls short.** Closed trackers ship fixed rules (linear +2.5 kg,
percentage waves) that ignore the individual's actual response; the "AI
coach" apps that do adapt are cloud services — your training history is
uploaded, the model is unauditable, and the adaptation logic is a trade
secret. Nobody can reproduce or falsify their claims.

**Fortiche's asset.** The complete, structured, local history: every
`LoggedSet` has reps, `weightKg`, optional `rpe`, `completedAt`, and `skipped`
(`LogModels.swift`); exercises key across sessions via `librarySlug`.
`WorkoutStats` (`FortichePack/Sources/FortichePack/Stats/WorkoutStats.swift`)
already computes Epley e1RM (`estimatedOneRepMax`), per-exercise
`personalRecords`, and `lastPerformance`. The engine gives a free measurement
instrument: a suggestion shown at session start is "accepted unmodified" iff
the set completes with no `adjustWeight` command against it —
`WorkoutCommand.swift` makes user modification an observable event, not a
survey question. And FoundationModels guided generation is already integrated
and tested (`TemplateParser.swift`, `IntelligentParserTests`).

**First three steps in this repo.**

1. Build the baseline as a pure function: `WorkoutStats.suggestedNextLoad`
   implementing the static rule (last successful top set + 2.5 kg on full-rep
   completion, hold on failure), with unit tests in
   `FortichePack/Tests/FortichePackTests/StatsTests.swift`. Pure Swift, no
   model, testable on the macOS host.
2. Add the measurement channel behind a launch arg (e.g. `--suggest-loads`,
   registered alongside the existing args in `Fortiche/RootView.swift`):
   surface the suggestion in the session UI and log
   (exercise, suggestedKg, performedKg, adjustWeight-count) per set to a local
   JSON journal — not to the SwiftData schema, which stays untouched until
   promotion.
3. Prototype the model path: a `@Generable` suggestion schema (mirroring the
   set-GROUP style of `GeneratedDay` — per-set arrays were unreliable on the
   small model) prompted with a compact text rendering of the last N sessions
   for one exercise, `GenerationOptions(temperature: 0)`, and R6-style
   sanitization (the model emits 0 for "not specified"; clamp absurd jumps,
   e.g. reject >10% load increases, at conversion — never trust raw output).

**You have a result when…** over a pre-registered N ≥ 30 sessions of real
use, the model path's accepted-unmodified rate exceeds the static rule's rate
(both measured by the same command-stream instrument), with zero suggestions
escaping the safety clamp. If the static rule wins, that is the result —
archive it; "small on-device models cannot beat linear progression" is worth
knowing and nobody has published it.

---

## Problem 2 — Photo-of-a-program import

**The question.** Can the on-device model parse a *photo* of a program — a
whiteboard, a coach's PDF screenshot, a notebook page — end to end, with no
cloud OCR?

**Why SOTA falls short.** Program import in commercial apps is either manual
entry or cloud OCR (photo leaves the device). The realistic artifact a lifter
holds is a photo, not clean text.

**Fortiche's asset.** iOS 27 FoundationModels adds image attachments —
verified in the SDK swiftinterface (as of 2026-07, Xcode 27 beta):
`Attachment<ImageAttachmentContent>` with `init(_ cgImage:)`,
`init(_ ciImage:)`, `init(_ pixelBuffer:)`, `init(imageURL:)`, conforming to
`PromptRepresentable`, and `LanguageModelCapabilities` exposing a `.vision`
capability check. Fortiche already owns the entire downstream pipeline: the
two-pass text parser, the `GeneratedDay` schema, per-day heuristic fallback,
fuzzy exercise matching, and the review UI
(`Fortiche/TemplateImport/TemplateImportView.swift`, `TemplateReviewView.swift`).
A photo parser only has to reach *text or `ParsedDay`*; everything after is
built and tested.

**First three steps in this repo.**

1. Capability probe first (this gates everything): on a real device, log
   `SystemLanguageModel.default.capabilities.contains(.vision)` behind a
   debug flag. Whether the *on-device* model actually has vision — vs. the
   API existing for other executors — is unverified as of 2026-07. If false,
   the pivot is Vision-framework OCR feeding the existing text pipeline;
   record the probe result either way.
2. Spike image→text transcription as a separate first pass: prompt a session
   with the `Attachment` and ask for a faithful plain-text transcription of
   the program, then feed that through the *existing*
   `ProgramSegmenter` → per-day pipeline unchanged. This preserves pass-1
   deterministic segmentation and the per-day fallback; direct
   image→`GeneratedDay` skips both and should be the compared variant, not
   the default.
3. Assemble a ground-truth corpus before UI work: 10 photographed real
   programs (varied handwriting, lighting, layouts) with hand-labeled
   expected `ParsedProgram`s, scored by exercise-line match rate. Only then
   add a PhotosPicker entry to `TemplateImportView` behind a flag.

**You have a result when…** a pre-registered X of the 10 corpus photos
produce a `ParsedProgram` with ≥ 90% exercise-line agreement against ground
truth, fully on-device. Predict X first. X = 0 with `.vision` absent on
device is also a result: file it, and the OCR fallback becomes the plan.

---

## Problem 3 — Private Cloud Compute for long/messy programs

**The question.** When a program is too long or too messy for the on-device
model (the exact case where `usedFallback` flips true today), can Apple's
Private Cloud Compute model rescue it without compromising the app's
no-server privacy stance?

**Why SOTA falls short.** Every cloud-AI fitness app sends training data to a
conventional server under a conventional privacy policy. PCC is the one cloud
path with stateless, attestable execution — but no strength app has adopted
it, and its practical limits (availability, quota, guided-generation support)
are undocumented in the wild.

**Fortiche's asset.** A graded difficulty instrument nobody else has: the
two-pass parser records `usedFallback` per program and degrades *per day*, so
"messiness" is measurable, not anecdotal. And the SDK path exists — verified
in the iOS 27 FoundationModels swiftinterface: `PrivateCloudComputeLanguageModel`
with `availability` (`UnavailableReason` = `deviceNotEligible` /
`systemNotReady`), a `quotaUsage` property, and
`LanguageModelSession(model: some LanguageModel, ...)` overloads that accept
it. Note the API-visible unavailable reasons do *not* include a
missing-entitlement case — which is exactly why step 1 is empirical.

**First three steps in this repo.**

1. **Answer the entitlement/quota question — it is step 1, not step 3.**
   Behind a `--pcc-probe` launch arg, construct
   `PrivateCloudComputeLanguageModel()` on a real device, log `availability`,
   `isAvailable`, `quotaUsage`, and `capabilities` (does it contain
   `.guidedGeneration`? `.vision`?), and attempt one trivial `respond` call.
   Check Signing & Capabilities / provisioning for any required entitlement
   the swiftinterface doesn't surface. Everything else is blocked on this
   probe's output.
2. Build the messy corpus and baseline: collect long real programs (8+ days,
   pasted PDFs, mixed notation) and record today's per-day fallback rate B%
   and failure taxonomy through the existing `IntelligentProgramParser`.
3. Implement a third `ProgramParsing` conformer backed by the PCC model —
   same `GeneratedDay` schema if guided generation is supported — flag-gated
   and *opt-in per import* with explicit UI consent, because "Data Not
   Collected" is a load-bearing App Store declaration
   (`fortiche-appstore-and-release` owns whether PCC use changes it; do not
   guess).

**You have a result when…** on the messy corpus, the PCC path's per-day
fallback rate lands at or below a pre-registered target vs. baseline B%, with
quota consumption and latency numbers recorded — or the step-1 probe shows
PCC unusable (entitlement, quota, no guided generation), which goes straight
to `fortiche-failure-archaeology` with the probe logs as evidence.

---

## Problem 4 — Watch-side coaching within the R7 limits

**The question.** How much useful mid-workout coaching can render on the
watch given the hard constraint (R7): watchOS 27 has `LanguageModelSession`,
but `SystemLanguageModel` — the local model — is `@available(watchOS,
unavailable)` (verified in the watchOS 27 SDK swiftinterface, line-level, as
of 2026-07). Cloud-backed models are the only on-watch option, and untested.

**Why SOTA falls short.** Watch strength apps are timers and rep counters;
anything "smart" lives on the phone or in a cloud round-trip that dies when
the phone does. Nobody has published what coaching latency is achievable on
watchOS 27's actual model surface.

**Fortiche's asset.** The watch is already the *authoritative* engine during
a watch session, with a reconciled phone peer and multiple live channels
(mirrored-session `sendToRemoteWorkoutSession`, WC `sendMessage` debug
transport — see `fortiche-architecture-contract` and
`FortichePack/Sources/FortichePack/Sync/ConnectivityHub.swift`). That
inverts the problem: coaching does not need to be *computed* on the watch,
only *rendered* there within the rest interval. The phone can run Problem 1's
suggester and ship results over channels that already exist.

**First three steps in this repo.**

1. Probe the watch model surface on a real watch (per R2, live-session
   plumbing is device-only anyway — coordinate with
   `fortiche-device-sync-campaign`): behind a debug flag in
   `ForticheWatch/WatchWorkoutController.swift`, log
   `PrivateCloudComputeLanguageModel().availability` (the watchOS 27
   swiftinterface *does* declare it available there) and time one trivial
   session call. Battery and radio cost noted per attempt.
2. Prototype the phone-computed path: phone generates a next-set hint
   (Problem 1's output) and ships it to the watch. **Gate:** extending the
   snapshot/command envelope schema is a HIGH-risk change per
   `fortiche-change-control` (goes through review with engine tests) — do
   NOT wire it in as a prototyping shortcut. The pre-review prototype path
   is a flag-gated side-channel message over `ConnectivityHub`'s live
   channel. Watch renders it as a one-line hint during rest. No new sync
   channel; no watch-side model.
3. Define and instrument the latency budget: a hint is useful iff it arrives
   before the rest timer ends. Log (hint-requested, hint-rendered) timestamps
   on the watch across real sessions.

**You have a result when…** across 5 real-device sessions, phone-computed
hints render on the watch before rest ends for ≥ 95% of sets (pre-register
the threshold); and the on-watch PCC probe yields either concrete
latency/availability numbers or a documented negative. Do not oversell: as of
2026-07 all watch-side model behavior is *untested* — the probe result, not
the SDK annotation, is the fact.

---

## Problem 5 — HealthKit workout-zone adoption for strength

**The question.** Apple shipped a workout-zone API surface in the 27 SDKs —
verified present and *unadopted in this repo*:
`HKWorkoutZoneConfiguration` / `HKWorkoutZone` / `HKWorkoutZoneGroup` /
`HKWorkoutZoneDuration` in the HealthKit swiftinterface,
`HKHealthStore.preferredWorkoutZoneConfiguration(for:)`,
`HKWorkoutBuilder.setCustomZoneConfiguration(_:for:)`, and the delegate
callback `workoutBuilder(_:didUpdateWorkoutZone:)` on
`HKLiveWorkoutBuilderDelegate` (header: `HKLiveWorkoutBuilder.h`,
`API_AVAILABLE(ios(27.0), watchos(27.0))`). Zones are heart-rate-framed —
cardio furniture. Does zone telemetry carry any signal for *strength*
training: is HR-zone recovery during rest a usable readiness/auto-rest input?

**Why SOTA falls short.** Strength apps ignore HR entirely; cardio apps own
zones. The intersection — zone dwell during inter-set rest, correlated with
whether the next set hits its target — is unexplored, plausibly because no
strength app has both the set-level command stream and the live HK builder in
the same process.

**Fortiche's asset.** Exactly that intersection.
`ForticheWatch/WatchWorkoutController.swift` already holds the
`HKLiveWorkoutBuilder` and implements its delegate (today only
`didCollectDataOf` / `didCollectEvent` — zone callbacks unadopted), while the
same process runs the engine that timestamps every `completeSet` and rest
period.

**First three steps in this repo.**

1. Adopt the callback observationally: implement
   `workoutBuilder(_:didUpdateWorkoutZone:)` in `WatchWorkoutController`,
   flag-gated, logging zone transitions (`zoneGroup`, `currentZoneDuration`,
   `lastSampleProcessedDate`) alongside the engine's set/rest timeline.
   First falsifiable sub-question: does the callback fire *at all* for a
   strength-training activity type on a real watch? A "no" is a finding —
   Apple may gate zones to cardio activities.
2. Log the user's zone model once per session via
   `preferredWorkoutZoneConfiguration(for: heart-rate quantity type)` so
   analysis uses the same zones Apple's UI shows.
3. Offline correlation, no product behavior yet: across recorded sessions,
   test the pre-registered hypothesis "HR returning to the lowest zone
   before rest ends predicts hitting target reps on the next set" over
   ≥ 100 rest intervals.

**You have a result when…** either (a) the callback demonstrably never fires
for strength activities (archive with logs — it scopes the whole API for
this domain), or (b) the correlation lands above/below the pre-registered
effect size over ≥ 100 intervals. Only a positive (b) earns a step 4
(auto-rest suggestions), which then goes through `fortiche-change-control`.

---

## Problem 6 — An open program-exchange text format

**The question.** Can the notation Fortiche already parses be promoted into a
small, specified, round-trippable text format for sharing strength programs —
the thing the ecosystem conspicuously lacks?

**Why SOTA falls short.** There is no interchange format for training
programs. Every tracker locks programs in a proprietary database; "sharing" a
program means screenshots (which is Problem 2's input — the two problems are
duals). Coaches distribute PDFs that every client re-types.

**Fortiche's asset.** The parser *is* the spec seed.
`HeuristicLineParser.swift` is a deterministic, unit-tested reference
implementation of the common notation (`Squat 3x5 @ 100kg`,
`Bench Press 5×8-12 80 kg`, `OHP 3x8 @ 65% rest 120s`, `Pull-ups 3xAMRAP`,
`Curls 4x12 RPE 8` — its own doc comment is the corpus start);
`ProgramSegmenter` defines day-header rules; `ParsedProgram` / `TemplateDTO`
are the data model; `ParsingTests.swift` is the conformance suite seed. A
spec extracted from running, tested code beats a committee document.

**First three steps in this repo.**

1. Write the grammar down: a spec document (EBNF-style) covering exactly what
   `HeuristicLineParser` + `ProgramSegmenter` accept today — every claim
   backed by an existing or new case in
   `FortichePack/Tests/FortichePackTests/ParsingTests.swift`. Where code and
   intuition disagree, the tests decide.
2. Build the emitter: `ParsedProgram → String` in `Parsing/`, with the
   property test `HeuristicLineParser`-family parse(emit(p)) ≡ p (modulo
   defaulted fields) over the whole existing test corpus. Round-tripping is
   the format's falsifiability engine — a format you can't round-trip is
   prose.
3. Add flag-gated export UI (share a template as text) and grow a public
   corpus of real-world programs with expected parses, so a second,
   independent implementation can be tested against it.

**You have a result when…** the round-trip property holds at 100% over the
existing corpus plus a pre-registered N of newly collected real-world
programs, and at least one parser *not in this repo* (even a 50-line Python
script in the corpus repo) passes the conformance suite. The format is real
when the second implementation agrees; until then it is labeled a candidate.

---

## Provenance and maintenance

Volatile facts above are stated as of 2026-07 against Xcode 27 beta. One-line
re-verification for each load-bearing claim:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
IOS_SDK=/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
WATCH_SDK=/Applications/Xcode-beta.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk

# All package tests passing (baseline harness health; count owned by fortiche-build-and-env)
swift test --package-path FortichePack 2>&1 | tail -1

# P1: log/stat/engine assets exist
grep -l estimatedOneRepMax FortichePack/Sources/FortichePack/Stats/WorkoutStats.swift
grep -n "case adjustWeight" FortichePack/Sources/FortichePack/Engine/WorkoutCommand.swift

# P2: image Attachments + vision capability in FoundationModels
grep -n "ImageAttachmentContent\|static var vision" "$IOS_SDK"/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface | head

# P3: PCC model, quota, session init over any LanguageModel
grep -n "PrivateCloudComputeLanguageModel\|quotaUsage\|init(model: some LanguageModel" "$IOS_SDK"/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface | head

# P4: watch surface — SystemLanguageModel unavailable, PCC declared available
grep -n -B1 "class SystemLanguageModel\|class PrivateCloudComputeLanguageModel" "$WATCH_SDK"/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/*.swiftinterface | head

# P5: zone API present in SDK, absent from repo
grep -rn "didUpdateWorkoutZone" "$IOS_SDK"/System/Library/Frameworks/HealthKit.framework/Headers/HKLiveWorkoutBuilder.h
grep -rn "HKWorkoutZoneConfiguration" "$IOS_SDK"/System/Library/Frameworks/HealthKit.framework/Modules/HealthKit.swiftmodule/*.swiftinterface | head -3
grep -rn "didUpdateWorkoutZone" ForticheWatch/ FortichePack/Sources/ || echo "still unadopted"

# P6: parser/segmenter/tests exist
ls FortichePack/Sources/FortichePack/Parsing/HeuristicLineParser.swift FortichePack/Tests/FortichePackTests/ParsingTests.swift

# Launch-arg gating pattern to copy
grep -n '"--demo-import"\|"--skip-health"' Fortiche/RootView.swift Fortiche/WorkoutSession/PhoneWorkoutController.swift
```

Drift watchlist: beta SDK interfaces (all of P2–P5's API claims) can change
at any Xcode 27 seed — re-run the greps before acting; the R7 watch-model
availability annotations specifically have already been observed to be
finer-grained in the interface than the one-line rule suggests, so verify
against the current interface, not this document. `--demo-history` seeds
synthetic logs (`fortiche-run-and-operate`) — fine for pipeline smoke tests,
useless as evidence for P1/P5, which require real training data.
