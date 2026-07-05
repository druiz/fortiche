---
name: fortiche-failure-archaeology
description: >
  The incident chronicle for Fortiche: every non-obvious failure the project has
  hit, formatted symptom -> root cause -> evidence -> status. Load this when a
  bug you are chasing smells familiar (Live Activity buttons doing nothing,
  paired-simulator watch/phone sync dead, WC messages vanishing, duplicate or
  deduped workout commands after a crash, the LLM parser emitting garbage
  zeros or malformed set arrays, templates never arriving on the watch,
  watchOS FoundationModels availability confusion, icon rendering artifacts),
  before re-attempting a fix that was already tried and rejected, or when you
  need the evidence trail behind a hard rule in fortiche-change-control
  (R1-R8) or CLAUDE.md.
---

# Fortiche failure archaeology

This is the project's incident log, mined from `git log` and `docs/SPIKE-M1.5.md`
(all claims re-verified against the repo as of 2026-07). Each entry records what
broke, what was tried and **why it wasn't enough**, the evidence that settled the
root cause, and the current status. Read the relevant entry BEFORE debugging a
symptom that matches one — several of these failures are deceptive (calls that
"succeed", fixes that look right but aren't) and cost real time the first time.

Jargon used throughout:

| Term | Meaning |
|---|---|
| `linkd` | The OS daemon that indexes App Intents metadata from installed bundles into `appintents.sqlite3`. If it rejects a bundle, no intent in that bundle works. |
| `chronod` | The daemon that executes Live Activity / widget button taps (`LNAction`s). |
| Rapport | Apple's device-to-device transport (`RPErrorDomain`); carries HealthKit workout mirroring. |
| WC | WatchConnectivity (`WCSession`): `applicationContext`, `transferUserInfo`, `sendMessage`. |
| Mirroring | `HKWorkoutSession.startMirroringToCompanionDevice()` + `sendToRemoteWorkoutSession` — the production live-sync channel. |
| Journal | The whole-`WorkoutState` JSON snapshot the engine writes to disk after every mutation, used for crash recovery. It is NOT a command log (`fortiche-architecture-contract` §3). |
| debug dylib | Xcode's `ENABLE_DEBUG_DYLIB` build layout: stub main executable + `<App>.debug.dylib` (speeds SwiftUI previews). |

## When NOT to use this skill

- You need the *forward-looking* rules and invariants (what the architecture IS,
  not how we learned it) → `fortiche-architecture-contract`.
- You are actively debugging and need log commands, daemon-inspection recipes,
  simulator gotchas → `fortiche-debugging-playbook` and
  `fortiche-diagnostics-and-tooling`.
- You want build/env setup (`DEVELOPER_DIR`, xcodegen, SDKs) → `fortiche-build-and-env`.
- You are planning real-device sync testing → `fortiche-device-sync-campaign`.
- You want LLM/parsing design as it stands today → `fortiche-intelligence-reference`.
- You want to *change* something an incident led to (e.g. re-enable
  `ENABLE_DEBUG_DYLIB`) → that is change control; see `fortiche-change-control`.
  Nothing in this file authorizes reverting a fix.

## Incident index

| # | Symptom | One-line root cause | Status |
|---|---|---|---|
| 1 | Live Activity buttons silently do nothing | linkd rejects ALL App Intents metadata: debug-dylib stub binary + `extract.packagedata` from package-hosted intents both EINVAL | Fixed (`e01c871`) |
| 2 | Watch→phone live sync dead on paired simulators | Mirroring rides Rapport; paired sims have no Rapport link — and the start call lies | Won't fix (OS); workarounds shipped |
| 3 | Live sync messages vanish during reachability blips | WC silently cancels sends mid-blip | Fixed via resync-on-reachability |
| 4 | Duplicate engine after relaunch; own commands deduped after recovery | Async HK recovery raced a new workout; fresh seq counter collided with restored `lastAppliedSeq` | Fixed (`1189a6b`) |
| 5 | LLM parser: unreliable per-set arrays; phantom `0` values | Small on-device model can't expand per-set arrays; emits 0 for "not specified" | Fixed: set-group schema + zero sanitization |
| 6 | Templates pushed before WC activation never arrive | `updateApplicationContext` before `.activated` is lost | Fixed: pending-buffer + re-send on activation |
| 7 | Watch device build fails on FoundationModels | `SystemLanguageModel`/`@Generable` are `@available(watchOS, unavailable)` — earlier "works on watch" claim was a misread SDK interface | Fixed (`57ea9a7`); lesson: verify availability per-slice |
| 8 | App icon concepts: monogram and plate abandoned | Monogram too cluttered at grid size; plate's `.clear`-blend punch-out cut through the background to transparency | Resolved: dumbbell shipped; dead concepts deleted |

---

## 1. The Live Activity button saga (three acts)

**Symptom:** Tapping any Live Activity button (Done Set, Skip Rest, Pause) did
*nothing*. No app launch, no log line from the intent's `perform()`, no error UI.
On device AND simulator.

This took three attempts. The first two were plausible, partially informed fixes
that did not survive contact with evidence. Recorded in commits `136a60d` →
`d4b0d8f` → `e01c871`.

### Act I — register `AppIntentsPackage` in the widget extension (`136a60d`) — insufficient

**Hypothesis:** intents lived in FortichePack (SwiftPM); the widget extension was
missing its `AppIntentsPackage` registration, so package-hosted intents weren't
discoverable from the widget process.

**What was done:** added the `AppIntentsPackage` conformance/registration to the
widget extension too, added per-invocation logging (subsystem
`com.davidruiz.fortiche`, category `intents`), and taught `WorkoutIntentBridge`
to recover a journaled workout when a button relaunches the app in the background.

**Result:** buttons still dead. The logging added here is what later made the
real diagnosis possible (the intent's `perform()` provably never ran — the
failure was upstream of our code).

### Act II — move LA intents out of the package into `Shared/` (`d4b0d8f`) — insufficient

**Hypothesis (partially correct):** package-hosted `LiveActivityIntent`s extract
metadata with the package module as `fullyQualifiedTypeName`
(`FortichePack.CompleteSetIntent`) and empty per-bundle type mappings, so the
system cannot resolve which process executes a tap and drops it silently.

**What was done:** moved the three LA intents to `Shared/LiveActivityIntents.swift`,
compiled into BOTH the app and the widget extension (Apple's sample
configuration — `project.yml` lists `sources: [Fortiche, Shared]` and
`sources: [ForticheWidgets, Shared]`), each binary getting its own registered
copy. `WorkoutIntentBridge` stayed in FortichePack, made public.

**Result:** still dead. Correct in direction (this arrangement is the shipped
one) but the bundle-level metadata rejection described in Act III masked any
improvement — linkd was rejecting the *entire bundle's* metadata regardless of
where individual intents lived.

### Act III — root cause via chronod + linkd's audit log (`e01c871`) — fixed

**Evidence trail (this is the part to remember):**

1. chronod, at tap time on the simulator:
   `Failed to execute LNAction … There is no metadata for CompleteSetIntent in com.davidruiz.fortiche`
   — so the OS had never indexed the intent at all.
2. linkd's `appintents.sqlite3` `audit_errors` table, at *install* time:
   - `Failed to resolve package data for Fortiche.app: EINVAL (…/Fortiche.app/Fortiche)` —
     linkd could not parse the **debug-dylib stub main executable**.
   - The same EINVAL on `extract.packagedata` entries emitted by
     `AppIntentsPackage` registrations for **statically linked** SwiftPM packages.
   - `Bundle did not provide any metadata sources` — after those failures, linkd
     indexed NOTHING for the bundle.

**Two compounding root causes, both required fixing:**

1. Debug builds' debug-dylib layout (stub main executable + `<App>.debug.dylib`)
   breaks linkd's binary parse → the whole bundle's App Intents metadata is
   rejected at install, on device and simulator. Fix: `ENABLE_DEBUG_DYLIB: NO`
   in `project.yml` (line ~30; cost: slower SwiftUI-preview relaunches).
2. The `AppIntentsPackage` registrations themselves emit `extract.packagedata`,
   which EINVALs the same way for statically linked packages. Fix: removed both
   registrations (`Fortiche/ForticheAppIntents.swift` and
   `ForticheWidgets/ForticheWidgetsAppIntents.swift` deleted) and moved the Siri
   intents + entities + `AppShortcutsProvider` from FortichePack into the app
   target (`Fortiche/Intents/WorkoutIntentsSiri.swift`,
   `Fortiche/Intents/WorkoutEntities.swift`). `AppShortcutsProvider` must live
   in the app target anyway (Apple requirement). **No App Intents remain
   package-hosted.**

**Verification that settled it:** after the fix, linkd's database contained
canonical bundle + `intent_metadata` rows for all 7 intents (CompleteSet,
SkipRest, PauseResume, StartForticheWorkout, LogSet, NextExercise, SkipRestSiri),
and buttons dispatched.

**Status: FIXED.** Codified as hard rule R1: App Intents never live in a Swift
package; `ENABLE_DEBUG_DYLIB` stays `NO`. Where things live now: LA intents in
`Shared/` (compiled into app + widget), Siri intents in `Fortiche/Intents/`.
Rule text lives in `fortiche-change-control` (home of the numbered rules
R1–R8; `fortiche-architecture-contract` cites them from its own invariants
list); the linkd/chronod
inspection recipes live in `fortiche-debugging-playbook`. Note from `136a60d`:
simulator *lock-screen* taps are additionally blocked by linkd bundle validation
of the ad-hoc-signed widget — that path is device-only.

---

## 2. Paired-simulator mirroring: Rapport failure + the deceptive success

**Symptom:** watch-started workout never appeared on the phone when running on
paired simulators (iPhone 17 + Watch Ultra 3, both 27.0), even though
`simctl list pairs` showed the pair `(active, connected)` and every API call
succeeded.

**What was tried:** a dedicated spike (M1.5, commit `0d89087`, findings in
`docs/SPIKE-M1.5.md`) with minimal spike code on both sides, tracing delivery
through `healthd`.

**Evidence that settled it:** watch-side `healthd` log:

```
Error Domain=com.apple.healthkit Code=300 "Remote device is unreachable"
  ← RPErrorDomain Code=-6727 kNotFoundErr ('rapport:rdid:PairedCompanion' not found)
```

The mirroring transport is Rapport, and paired simulators have no Rapport
companion link. Full stop — this is an OS/simulator limitation on this beta
(Xcode 27 beta, iOS 27.0 24A5355p / watchOS 27.0 24R5289n, as of 2026-07).

**The trap inside the trap:** `startMirroringToCompanionDevice()` **resolves
without error even when the companion is unreachable** — healthd enqueues the
transaction and retries internally. Never infer from the call succeeding that
the phone is attached. This is why the app-level `requestSnapshot`/`snapshot`
handshake exists and is mandatory (`SyncMessage.requestSnapshot` in
`FortichePack/Sources/FortichePack/Engine/WorkoutCommand.swift`; the watch
answers in `ForticheWatch/WatchWorkoutController.swift`, the phone asks in
`Fortiche/MirroringReceiver.swift`).

**Status: WON'T FIX (not ours to fix).** Shipped mitigations:
- Real devices required to exercise the production mirroring path (see
  `fortiche-device-sync-campaign`).
- Simulator dev loop uses the **WC `sendMessage` debug transport** (WC works
  between paired sims), selected when the mirrored channel never connects.
- Watch retries mirroring with backoff for the life of the workout
  (`WatchWorkoutController.swift` ~line 197), precisely because the call can
  "succeed" while unreachable.
- Hard rule R2/R3 context: the phone's `workoutSessionMirroringStartHandler` is
  installed synchronously in `ForticheApp.init` (see the comment there — a
  lazily installed handler drops the background-delivered session), and the
  Live Activity is requested inside that handler's ~10s window with placeholder
  content (`MirroringReceiver.swift` ~line 63).

---

## 3. WC messages silently cancelled during reachability blips

**Symptom:** during live workouts over the WC debug transport, occasional
commands/snapshots simply never arrived; no error surfaced at the API level in
a way the app acted on.

**Evidence:** observed `shouldCancel: YES` in WC-layer logging during
reachability transitions (observed 2026-07 during M3 development; the string is
from OS logs, not our code) — sends issued during a blip are cancelled, not
queued.

**Fix (shipped in `1189a6b`):** never trust an individual live send; make the
*state*, not the message, the unit of sync. Both sides resync on
`sessionReachabilityDidChange`:
- `ConnectivityHub.onReachabilityChange` (`FortichePack/Sources/FortichePack/Sync/ConnectivityHub.swift`)
  fans the callback out.
- Watch (authority): re-sends a full snapshot on regaining reachability
  (`WatchWorkoutController.swift` ~line 35).
- Phone (peer): sends `.requestSnapshot` (`MirroringReceiver.swift` ~line 47).

Snapshots are idempotent and stale-rejected via `lastAppliedSeq`
(`MirroringReceiver` logs "ignored stale snapshot"), so over-resyncing is safe.

**Status: FIXED** by design (resync-on-reachability), rule R4. The general
principle — every live channel needs a state-resync path; per-message delivery
is best-effort — is part of `fortiche-architecture-contract`.

---

## 4. Recovery races: HK adoption vs. fresh workouts, and the sequence counter

Two related crash-recovery bugs, both found during M3 (`1189a6b`) and both now
guarded in code.

### 4a. Async HK recovery adopting the *current* workout's journal

**Symptom:** a duplicate engine adoption — `HKHealthStore.recoverActiveWorkoutSession`'s
completion fired AFTER the user had already started a *new* workout, and the
recovery path adopted the journal that belonged to the freshly running engine.

**Root cause:** `recoverIfNeeded()` checks `engine == nil` before calling the
async HK query, but the query's completion can land arbitrarily later. A guard
only at entry is a TOCTOU bug.

**Fix:** re-check inside the completion. Verbatim from
`ForticheWatch/WatchWorkoutController.swift` (~line 56):

```swift
healthStore.recoverActiveWorkoutSession { [weak self] session, _ in
    Task { @MainActor in
        guard let self else { return }
        // Re-check: a workout may have started while the async HK
        // recovery query was in flight (its journal is NOT a crash).
        guard self.engine == nil else { return }
        ...
```

Also handled there: an HK session existing with *no* journal is an orphan and
gets `session.end()`.

### 4b. Fresh sequence counter deduping its own commands

**Symptom:** after journal recovery, the engine's own new commands were
silently dropped.

**Root cause:** the engine dedupes per-origin via `lastAppliedSeq`; a recovered
engine that restarted its sequence counter at 1 emitted seq numbers ≤ the
restored `lastAppliedSeq[localHost]`, so its own commands were treated as
already-applied duplicates.

**Fix:** verbatim from
`FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift` (~line 34):

```swift
// Resume the sequence counter after recovery — a fresh counter would
// collide with the restored lastAppliedSeq and dedupe local commands.
self.nextSeq = (state.lastAppliedSeq[localHost.rawValue] ?? 0) + 1
```

**Status: both FIXED**, rule R5. If you touch recovery code, preserve both
guards; there are engine tests in FortichePack (`swift test --package-path
FortichePack` with `export DEVELOPER_DIR=/Applications/Xcode-beta.app`).

---

## 5. LLM schema evolution: per-set arrays → set groups; zero means unset

Two separate lessons about the small on-device FoundationModels model,
both baked into `FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift`.

### 5a. Per-set array expansion was unreliable → set-GROUP schema

**Symptom:** asking the model to emit one array element per set ("3x8" → three
identical set objects) produced unreliable output on the small model —
wrong counts, malformed expansions.

**Fix (M2, `7746352`):** don't make the model do arithmetic/expansion. The
`@Generable` schema is `GeneratedSetGroup { setCount, reps, repsUpper, weight,
unit, rpe }` — "3x8 @ 100kg" is ONE group with `setCount: 3`; only genuinely
differing sets (5/3/1) become multiple groups. Deterministic Swift code expands
groups afterwards, clamped: `let count = min(30, max(1, group.setCount))`
(TemplateParser.swift ~line 200). Combined with the other M2 reliability
levers: deterministic pre-segmentation into day chunks (`ProgramSegmenter`), one
`GeneratedDay` per request, temperature 0, per-day heuristic fallback.

### 5b. The model emits `0` for "not specified"

**Symptom:** parsed programs showed `@ 0%` / zero weights / zero rest where the
source text said nothing at all (user-visible fix landed in `d9799b2`:
"zero weight/percent from the model now reads as bodyweight").

**Root cause:** despite `@Guide` descriptions saying "else null", the model
emits `0` for unspecified numeric fields.

**Fix:** sanitize at conversion, never trust raw zeros
(TemplateParser.swift ~lines 185–199):

```swift
// The model sometimes emits 0 for "not specified" — treat as
restSeconds: (exercise.restSeconds ?? 0) > 0 ? exercise.restSeconds : nil,
...
// Zero means "the model had nothing" — treat as bodyweight.
if (weightKg ?? 0) <= 0 { weightKg = nil }
if (percent ?? 0) <= 0 { percent = nil }
```

One deliberate exception: `reps: 0` is a *defined* encoding for AMRAP/max reps
(see the `@Guide` on `reps`) — do not "sanitize" that one.

**Status: FIXED**, rule R6. Current-state parsing design (including the related
dataset quirk: free-exercise-db says "shoulder press"/"military press", never
"overhead press" — aliased in `ExerciseMatcher.swift`) is documented in
`fortiche-intelligence-reference`.

---

## 6. Template push lost before WC activation

**Symptom:** templates pushed phone→watch right after app launch (the app pushes
the catalog once per launch and after every template mutation — see
`pushTemplatesToWatch` in `Fortiche/ForticheApp.swift`) never arrived: the push
happened before `WCSession` activation completed, and
`updateApplicationContext` calls before `.activated` are lost.

**Fix (M3, `1189a6b`, "activation-buffered"):** buffer the latest catalog and
replay it when activation completes.
`FortichePack/Sources/FortichePack/Sync/ConnectivityHub.swift`:

- `pushTemplates(_:)` — if `activationState != .activated`, store into
  `_pendingTemplates` and return.
- `session(_:activationDidCompleteWith:error:)` — on success, take-and-clear
  `_pendingTemplates` and call `pushTemplates` again.

Only the *latest* catalog is kept (last-writer-wins), which is correct because
`applicationContext` itself is latest-value semantics, not a queue.

**Status: FIXED.** If you add any new pre-activation send path, replicate this
pattern or route through `ConnectivityHub`.

---

## 7. The watchOS FoundationModels misread — verify availability per-slice

**Symptom:** real-device watch builds failed on FoundationModels symbols; the
simulator watch build had "worked" earlier only because M2 had gated the
parsing path off the watch-*simulator* slice specifically.

**Root cause (commit `57ea9a7`, verbatim from its message):** on watchOS 27,
`LanguageModelSession` is available but `SystemLanguageModel` (the local model)
and `@Generable` guided generation are `@available(watchOS, unavailable)` —
only cloud-backed models exist on the watch. **The earlier simulator-only guard
was based on a misread of the SDK interface.** Someone saw FoundationModels
symbols present for watchOS and concluded the local model worked there; the
per-declaration availability annotations in the device-slice `.swiftinterface`
said otherwise.

**Fix:** parsing is iPhone-side anyway, so the FoundationModels parsing path is
excluded from watchOS entirely (not just the simulator slice). Same commit also
persisted `DEVELOPMENT_TEAM` in `project.yml` so `xcodegen generate` stops
clobbering signing.

**The transferable lesson:** module availability ≠ symbol availability, and
simulator slices ≠ device slices. Before claiming an API works on a platform,
check the *device* slice's per-declaration `@available` annotations (build for
the device destination, or read the swiftinterface for the device triple) —
never conclude from "it compiles for the simulator" or "the framework imports".
Status of cloud-backed models on watch: **untested, labeled as such** (rule R7);
anything exploratory there belongs in `fortiche-research-frontier`.

**Status: FIXED** in `57ea9a7`; both platform builds green since.

---

## 8. App icon concepts: monogram rejected, plate punch-out failure

Low-stakes, but recorded because the dead code is gone and the "why not X?"
questions recur. History: `c196db6` (first icon, three concepts in
`Scripts/generate_icon.swift`: monogram / dumbbell / plate) → `c3105cd`
(colorway catalog; only the dumbbell survives in the script today).

- **Monogram** (an "F" whose strokes are barbells ending in plates): rejected
  because it was **cluttered at home-screen grid size** — the plate details that
  read well at 1024px turn to noise at ~60px. Ironically the `c196db6` script
  header still called it "the shipped icon" while the commit actually shipped
  the dumbbell — stale comment, not a second incident.
- **Plate** (end-on weight plate): its recessed ring + center bore were drawn by
  punching through the white disc with `ctx.setBlendMode(.clear)` *after* the
  background gradient was already in the context (visible in
  `git show c196db6:Scripts/generate_icon.swift`, "Recessed ring + center bore,
  punched out of the plate"). `.clear` erases every layer beneath, so the punch
  cut through the background too, leaving fully transparent ring/bore holes in
  the PNG instead of showing green through them — and iOS composites icon alpha
  over black. Rendering failure; concept dropped rather than reworked.

**Status: RESOLVED.** The dumbbell shipped, in five colorways with an in-app
picker (`c3105cd`). Regeneration is script-only, never hand-edited (rule R8):

```sh
swift Scripts/generate_icon.swift --catalog
```

Related dev-only quirk from the same work: SpringBoard caches icons across
reinstalls — delete the app or respring if an icon change doesn't show
(see `fortiche-debugging-playbook`).

---

## How to extend this chronicle

When a new incident closes, append an entry with the same shape — **Symptom /
What was tried (including failed attempts) / Evidence that settled it / Status**
— and cite the commit SHA plus the exact log lines or file:line evidence.
Failed attempts are the payload: Act I and Act II of incident 1 are what stop
the next person from re-trying them. If the incident produces a new invariant,
the rule itself goes to `fortiche-change-control`'s R1–R8 list (the single
home of the numbered rules; `fortiche-architecture-contract` may cite it from
its invariants); this file keeps the story.

## Provenance and maintenance

Facts here were verified against the repo on 2026-07-05. One-line re-checks for
the claims most likely to drift:

```sh
cd /Users/david/Code/Fortiche   # adjust to your checkout
git log --oneline                                                    # commit SHAs cited above
grep -n "ENABLE_DEBUG_DYLIB" project.yml                             # expect: NO (incident 1)
grep -rn "AppIntentsPackage" --include="*.swift" . | grep -v ThirdParty  # expect: no hits (incident 1)
ls Shared/LiveActivityIntents.swift Fortiche/Intents/                # intent homes (incident 1)
sed -n '1,45p' docs/SPIKE-M1.5.md                                    # Rapport verdict verbatim (incident 2)
grep -n "Re-check" ForticheWatch/WatchWorkoutController.swift        # recovery race guard (incident 4a)
grep -n "Resume the sequence counter" FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift  # (incident 4b)
grep -n "emits 0 for" FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift  # zero sanitization (incident 5b)
grep -n "_pendingTemplates" FortichePack/Sources/FortichePack/Sync/ConnectivityHub.swift  # activation buffer (incident 6)
git log -1 --format=%B 57ea9a7                                       # watchOS availability lesson (incident 7)
git show c196db6:Scripts/generate_icon.swift | grep -n "punched out" # plate punch-out code (incident 8)
```

Volatile: the Rapport/paired-sim behavior (incident 2) is tied to the Xcode 27
beta simulators (iOS 27.0 24A5355p / watchOS 27.0 24R5289n) — re-run the spike
check on each new beta before assuming it still fails. The `shouldCancel: YES`
string (incident 3) is an OS log observation, not reproducible from repo
contents. The monogram-clutter and plate-artifact *rationales* (incident 8) are
project-history record; the repo evidence is the concepts' existence in
`c196db6` and removal in `c3105cd`, plus the punch-out code itself.
