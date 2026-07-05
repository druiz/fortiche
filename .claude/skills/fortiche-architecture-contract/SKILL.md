---
name: fortiche-architecture-contract
description: >
  The load-bearing architectural decisions of Fortiche and WHY each one exists:
  the command-sourced ActiveWorkoutEngine, watch-authoritative sync with an
  optimistic phone peer, sequence-number reconciliation, canonical-kilogram
  storage, CloudKit-compatible SwiftData rules, the watch's local-only store
  and explicit sync-channel boundaries, journal-based crash recovery, the
  mirroring-handler launch discipline, the sub-3-minute discard rule, the
  generated-artifact policy, and the Shared/ target-membership pattern for
  Live Activity intents. Load this BEFORE designing or reviewing any change
  that touches FortichePack/Sources/FortichePack/Engine, Sync, Models, Units,
  the watch/phone workout controllers, MirroringReceiver, project.yml target
  membership, or anything that stores a weight, orders a child collection, or
  moves data between devices. Also load it when someone asks "why is it built
  this way", "can I just...", or proposes CloudKit/live-sync/model changes.
---

# Fortiche architecture contract

This skill is the set of decisions you must not casually undo, each with the
reason it exists and the invariant it protects. Fortiche is an iOS 27 /
watchOS 27 strength-training app: iPhone app (`Fortiche/`), watch app
(`ForticheWatch/`), widget extension (`ForticheWidgets/`), and a local SwiftPM
package (`FortichePack/`) holding models, the workout engine, parsing, sync,
and stats. `Shared/` compiles into BOTH the app and the widget targets. The
Xcode project is generated from `project.yml` by XcodeGen and is git-ignored.

**When NOT to use this skill**

- Build commands, toolchain, SDK setup → `fortiche-build-and-env`
- Running the app, simulators, launch args, demo seeding → `fortiche-run-and-operate`
- Diagnosing a live failure (logs, chronod, linkd, WC traces) → `fortiche-debugging-playbook` and `fortiche-diagnostics-and-tooling`
- The full war stories behind the hard rules cited here → `fortiche-failure-archaeology`
- Whether a change is allowed at all / review gates → `fortiche-change-control`
- LLM template import, guided generation, parser details → `fortiche-intelligence-reference`
- Training-domain semantics (RPE, 1RM, AMRAP) → `strength-domain-reference`
- Testing matrices and QA passes → `fortiche-validation-and-qa`
- Release/App Store mechanics → `fortiche-appstore-and-release`
- Real-device sync verification plan → `fortiche-device-sync-campaign`

Jargon used below, defined once:

- **Command**: one value of `WorkoutCommand` (completeSet, adjustWeight, pause, end, ...) — the only vocabulary for mutating an active workout.
- **Envelope**: `CommandEnvelope` = command + `origin` (which device created it) + `seq` (monotonic per-origin sequence number).
- **Authority**: the device whose engine's state is the truth for the current session. Watch when a watch session runs; phone otherwise.
- **Peer**: the non-authoritative device. Runs its own engine optimistically and reconciles against snapshots echoed by the authority.
- **Snapshot**: a whole `WorkoutState` value shipped from authority to peer.
- **Journal**: the JSON file the engine writes after every mutation for crash recovery.

## 1. The command-sourced engine

Files: `FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift`,
`WorkoutCommand.swift`, `WorkoutState.swift`.

**Decision**: every mutation of an active workout is a `WorkoutCommand`
applied through `ActiveWorkoutEngine.apply(_:)` / `submit(_:)`. There are no
direct state writes from views, intents, or sync handlers. The engine is
host-agnostic — the identical class runs watch-authoritative,
phone-authoritative, and as the phone-side peer.

**Why**: three consumers need the exact same mutation semantics — the local
UI, the remote peer (commands arrive over a transport), and crash recovery
(state is replayable/journalable). A command vocabulary gives all three one
code path, makes replication a matter of shipping envelopes, and makes
dedup/ordering a property of the envelope (`origin` + `seq`), not of the
transport.

Mechanics you must preserve:

- `submit(_:)` stamps the next local `seq`, applies locally, then fires
  `onLocalCommand` so the host can forward the envelope (peer → authority).
- `apply(_:)` enforces **per-origin dedup**: an envelope with
  `seq <= state.lastAppliedSeq[origin]` is silently ignored. This is what
  makes dual-delivery (production channel + WC debug channel both firing) and
  retries safe.
- After every applied command the engine journals to disk and fires
  `onStateChange` — hosts use that to echo snapshots and refresh the Live
  Activity. Do not add a mutation path that skips `apply` — it would bypass
  journaling, replication, and dedup all at once.
- `WorkoutState` is a value type, `Codable`, shipped whole as the snapshot.
  Keep it that way; the sync protocol and the journal both depend on it.

## 2. Authority model and reconciliation

Files: `Engine/WorkoutCommand.swift` (`SyncMessage`),
`ForticheWatch/WatchWorkoutController.swift` (authority),
`Fortiche/MirroringReceiver.swift` (peer),
`Fortiche/WorkoutSession/PhoneWorkoutController.swift` (phone-only authority).

**Decision**: when a watch session runs, the watch is the authority. The
phone runs a peer engine that applies its own edits optimistically, forwards
each envelope to the watch, and reconciles against snapshots the watch echoes
after every applied command. Phone-only workouts skip all of this — one
authoritative engine on the phone, no replication.

**Why**: the watch owns the `HKWorkoutSession` and the live builder (heart
rate, calorie collection) — it cannot be a follower of a device that might be
locked in a pocket. But phone edits must feel instant, so the peer applies
locally first instead of waiting a round trip.

The wire protocol is three `SyncMessage` cases and nothing more:

| Message | Direction | Meaning |
|---|---|---|
| `.command(envelope)` | peer → authority | apply this |
| `.snapshot(state)` | authority → peer | full truth after applying |
| `.requestSnapshot` | peer → authority | resend full state (reconnect/recovery) |

Reconciliation rule (`ActiveWorkoutEngine.adopt(snapshot:)`): the peer adopts
a snapshot **only if it is fresh** — i.e. the snapshot's
`lastAppliedSeq[localHost]` acknowledges every command this device has
already submitted (`acknowledged >= nextSeq - 1`). Stale snapshots are
rejected so optimistic local edits never visibly roll back and then re-apply.
The authority never adopts snapshots, ever (`WatchWorkoutController.handle`
ignores `.snapshot`).

Also load-bearing: the app-level `requestSnapshot`/`snapshot` handshake is
**mandatory** and not an optimization. `startMirroringToCompanionDevice()`
resolves without error even when delivery is impossible (hard rule R2; the
watch controller wraps it in an infinite backoff retry for exactly this
reason), and paired simulators have no Rapport link at all — on simulators
the same `SyncMessage`s flow over WatchConnectivity `sendMessage` as a debug
transport. Both sides resync on `sessionReachabilityDidChange` (watch
re-sends its snapshot, phone sends `.requestSnapshot`) because WC sends
during reachability blips are silently cancelled (R4). Incident details:
`fortiche-failure-archaeology`; device-verification plan:
`fortiche-device-sync-campaign`.

## 3. Journal-based crash recovery

**Decision**: the engine writes `WorkoutState` as JSON to
`ActiveWorkoutEngine.defaultJournalURL` (Application Support,
`active-workout.json`) after **every** mutation, atomically; deletes it when
the state is finished. `recover(localHost:)` restores an unfinished journal
at launch.

**Why**: a strength workout is 45–90 minutes of irreplaceable user effort;
watchdog kills and crashes mid-session are a when, not an if. Journaling
whole state (not a command log) keeps recovery O(1) and makes the journal
identical in shape to the sync snapshot.

Two recovery rules with incidents behind them (R5 — do not regress):

1. **Restore the sequence counter.** `ActiveWorkoutEngine.init` sets
   `nextSeq = lastAppliedSeq[localHost] + 1`. A fresh counter once caused the
   recovered engine to dedupe its *own* new commands (their seqs collided
   with already-applied ones).
2. **Re-check `engine == nil` inside async recovery completions.**
   `HKHealthStore.recoverActiveWorkoutSession`'s completion can fire AFTER
   the user already started a new workout; `WatchWorkoutController.recoverIfNeeded`
   guards twice (before the call and inside the completion). A single guard
   once produced a duplicate engine adoption.

The peer engine on the phone runs with `journalURL: nil` — the watch's
journal is the recoverable truth for watch-hosted sessions; a phone journal
of peer state would fight it after a phone relaunch.

## 4. Storage rules

### Canonical kilograms

`FortichePack/Sources/FortichePack/Units/Weight.swift`. Every stored or
transmitted weight — `TemplateSet.weightKg`, `SetState.weightKg`,
`LoggedSet.weightKg`, envelopes, snapshots — is kilograms. `WeightUnit`
converts at display/input boundaries only. **Why**: one canonical unit means
stats, plate math, 1RM estimates, and sync never carry a unit tag and never
double-convert; unit preference becomes pure presentation. `nil` weight means
bodyweight/unspecified (the LLM's zero-means-unset quirk is sanitized before
it reaches storage — see `fortiche-intelligence-reference`).

### CloudKit-compatible SwiftData models

Files: `Models/TemplateModels.swift`, `Models/LogModels.swift`,
`Models/ForticheStore.swift`. Every `@Model` obeys, without exception:

- all properties optional or defaulted (no non-optional un-defaulted stored properties)
- no `#Unique` / `@Attribute(.unique)` — CloudKit cannot enforce uniqueness
- relationships optional, with explicit inverses, cascade rules declared
- **every ordered child has an explicit `order: Int` field**, read only through the `ordered*` accessors (`orderedDays`, `orderedExercises`, `orderedSets`) — CloudKit relationships are unordered arrays

**Why**: the phone store opens with `cloudKitDatabase: .automatic`
(`ForticheStore.container(.phone)`), and CloudKit schema constraints are
checked at container-open time — one incompatible model bricks the store.
Identity is by `uuid` field + fetch, never by unique constraint; finished
workouts **upsert by UUID** because the two delivery channels
(mirrored-session final snapshot and WC `transferUserInfo`) may both deliver
the same workout (`MirroringReceiver.ingest` deletes-then-inserts by uuid).

Caveat, stated plainly: `.phone` mode falls back to `cloudKitDatabase: .none`
when the container throws (no iCloud account, missing entitlement), so local
dev mostly exercises the fallback. See §8.

### Watch store is local-only; channels are explicit

`ForticheStore.container(.watch)` is always `cloudKitDatabase: .none`.
**Why**: CloudKit on watchOS is slow to converge, needs its own account
state, and would race the live sync path. Everything that crosses devices
uses exactly one designated channel (`Sync/ConnectivityHub.swift`):

| Data | Channel | Direction | Properties |
|---|---|---|---|
| Template catalog | WC `updateApplicationContext` | phone → watch | latest-wins; buffered in `ConnectivityHub` until WC activation |
| Finished workouts | WC `transferUserInfo` | watch → phone | queued by the OS, survives phone-dead; upsert by UUID on arrival |
| Live session state | `sendToRemoteWorkoutSession` (production); WC `sendMessage` (simulator debug transport) | both | fire-and-forget; resync via snapshot handshake |

Do not route data through a different channel than the table says, and do not
add CloudKit as a watch↔phone path. The widget extension gets read-only
access to the phone store via the App Group (`group.com.davidruiz.fortiche`)
— it never opens its own sync.

### Sub-3-minute discard

`WorkoutState.minimumSaveDuration = 3 * 60`; `qualifiesForSaving` gates every
persistence point: watch `end(in:)` (no log, no queued transfer, HK
`discardWorkout()`), phone `PhoneWorkoutController.end`, and
`MirroringReceiver.ingest` (the phone re-applies the rule on ingest, so a
short workout arriving over a channel is still dropped). **Why**: accidental
starts pollute history and HealthKit rings; the final snapshot is still sent
so the peer tears down its UI. If you change the threshold, change it in the
one constant — every gate reads it.

## 5. Process and target rules

### Mirroring-handler discipline (R3)

`healthStore.workoutSessionMirroringStartHandler` is installed
**synchronously** in `ForticheApp.init` via `MirroringReceiver.install()`.
When the watch starts a workout, the system launches the phone app in the
background and delivers the mirrored session immediately — a lazily
installed handler silently drops it. The Live Activity must be requested
inside that handler's ~10s background window with placeholder content
("Connecting to watch…"); the first snapshot fills it in
(`MirroringReceiver.attach` → `startLiveActivity`). Do not move `install()`
into a view, a task, or `onAppear`.

### Shared/ target membership and the debug-dylib ban (R1)

Live Activity button intents live in `Shared/LiveActivityIntents.swift`,
compiled into BOTH the app and widget targets (see `sources: [Fortiche,
Shared]` and `sources: [ForticheWidgets, Shared]` in `project.yml`). App
Intents must NEVER live in a Swift package, and `ENABLE_DEBUG_DYLIB` stays
`NO` in `project.yml`. **Why**: linkd cannot extract App Intents metadata
from package-hosted intents or from the debug-dylib stub executable — the
result was Live Activity buttons that silently did nothing. Siri intents live
in `Fortiche/Intents/`; `AppShortcutsProvider` must be in the app target
(Apple requirement). Full incident chain: `fortiche-failure-archaeology`.

### Generated artifacts are never hand-edited (R8)

Icons (`swift Scripts/generate_icon.swift --catalog`), the exercise dataset
(`python3 Scripts/import_exercises.py`), the Xcode project (`xcodegen
generate` after editing `project.yml`), screenshots (demo launch args).
**Why**: hand edits are silently destroyed on the next regeneration. Change
the generator or its input, then regenerate. Process gates:
`fortiche-change-control`.

## 6. Invariants — check any diff against these

1. Engine state mutates only via `apply`/`submit` (and `restExpired`, which
   is the rest-deadline tick); no host writes `engine.state` directly.
2. Every envelope carries `origin` + monotonic per-origin `seq`; `apply`
   drops `seq <= lastAppliedSeq[origin]`.
3. The peer adopts a snapshot only when it acknowledges all local submits
   (`adopt` returns false otherwise); the authority never adopts snapshots.
4. Every applied command journals before the host callbacks observe it; the
   journal is deleted exactly when `state.isFinished`.
5. Recovery restores `nextSeq` from `lastAppliedSeq[localHost]`, and async
   recovery completions re-check `engine == nil`.
6. All stored/transmitted weights are kilograms; `nil` means
   bodyweight/unspecified; conversion only through `WeightUnit`.
7. Every `@Model`: optional/defaulted properties, no unique constraints,
   optional inverse relationships, and an explicit `order` field on every
   ordered child, read via `ordered*` accessors.
8. Watch store never touches CloudKit; cross-device data uses exactly the
   channel in the §4 table.
9. Finished-workout ingestion is idempotent by UUID and re-applies the
   3-minute rule.
10. `MirroringReceiver.install()` runs synchronously in `ForticheApp.init`;
    the Live Activity request stays inside the mirroring handler path.
11. App Intents live in app/widget targets (Shared/ for LA intents), never in
    FortichePack; `ENABLE_DEBUG_DYLIB: NO` stays.
12. Never trust `startMirroringToCompanionDevice()` resolving — the snapshot
    handshake is the liveness check.

## 7. Known weak points (as of 2026-07)

Stated plainly so nobody designs on sand:

- **Production mirroring path unverified on hardware.** R2 means the real
  `sendToRemoteWorkoutSession` path has only ever been exercised via the WC
  debug transport on simulators. The retry/backoff and handshake logic is
  believed correct but unproven on devices. Plan: `fortiche-device-sync-campaign`.
- **No offline phone command queue.** `MirroringReceiver.send` and
  `ConnectivityHub.sendLive` are fire-and-forget; a command submitted while
  both transports are down is applied optimistically on the phone and then
  lost. Because the watch can never acknowledge the lost seq, `adopt` rejects
  every subsequent snapshot for the rest of the session — the phone's view
  stays frozen on its optimistic state until the finished-state snapshot
  (which bypasses `adopt`) tears it down. Treat phone edits while
  disconnected as unreliable by design, not as a bug to patch casually.
- **No live watch↔phone mid-workout handoff.** Authority is fixed at start;
  you cannot promote the phone if the watch dies mid-session.
- **CloudKit sync untested against a real iCloud container.** The models
  follow the compatibility rules and `.automatic` is requested, but
  multi-device convergence has never been observed; local dev usually runs
  the `.none` fallback.
- **PCC entitlement unknown.** Whether cloud-backed FoundationModels
  (the only option on watchOS 27, per R7) requires additional
  entitlements/approval is unverified — nothing in the repo references it.
  See `fortiche-intelligence-reference` and `fortiche-research-frontier`.

## 8. Provenance and maintenance

All claims verified against the repo on 2026-07-05 (64 package tests
passing). One-line re-verification commands (run from the repo root; prefix
Swift/xcodebuild with `export DEVELOPER_DIR=/Applications/Xcode-beta.app`):

```sh
# Engine contract: apply/submit/adopt, dedup, journal, seq restore
grep -n "lastAppliedSeq\|nextSeq\|func adopt\|func apply\|func submit\|journal()" FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift

# Wire protocol is still three messages
grep -n "case " FortichePack/Sources/FortichePack/Engine/WorkoutCommand.swift | grep -A3 SyncMessage; grep -n "case command\|case snapshot\|case requestSnapshot" FortichePack/Sources/FortichePack/Engine/WorkoutCommand.swift

# Authority never adopts; peer forwards commands
grep -n "authority never adopts\|case .snapshot" ForticheWatch/WatchWorkoutController.swift Fortiche/MirroringReceiver.swift

# 3-minute rule and its gates
grep -rn "minimumSaveDuration\|qualifiesForSaving" FortichePack/Sources Fortiche ForticheWatch --include="*.swift"

# Store modes: watch local-only, phone CloudKit-with-fallback
grep -n "cloudKitDatabase" FortichePack/Sources/FortichePack/Models/ForticheStore.swift

# CloudKit model rules and order fields
grep -n "order: Int\|@Relationship\|ordered" FortichePack/Sources/FortichePack/Models/TemplateModels.swift FortichePack/Sources/FortichePack/Models/LogModels.swift

# Channel boundaries
grep -n "updateApplicationContext\|transferUserInfo\|sendMessage" FortichePack/Sources/FortichePack/Sync/ConnectivityHub.swift

# Mirroring handler installed in App init; debug dylib off; Shared/ membership
grep -n "install()" Fortiche/ForticheApp.swift; grep -n "ENABLE_DEBUG_DYLIB\|sources: \[" project.yml

# Canonical kg
grep -n "toKilograms\|fromKilograms" FortichePack/Sources/FortichePack/Units/Weight.swift

# Test count drifts — re-run
swift test --package-path FortichePack 2>&1 | tail -1
```

If any command's output contradicts this file, the file is stale: fix the
file, not the code, unless `fortiche-change-control` says otherwise.
