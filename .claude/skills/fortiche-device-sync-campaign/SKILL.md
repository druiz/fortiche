---
name: fortiche-device-sync-campaign
description: >
  Executable campaign to verify and harden Fortiche's production watch-to-phone
  live-sync path (HKWorkoutSession mirroring + Live Activity) on REAL iPhone +
  Apple Watch hardware. Load this when: running or planning the first real-device
  sync test; debugging mirrored-session delivery, background app launch from the
  watch, Live Activity not appearing during a watch workout, command round-trip
  latency, reconnect/resync after airplane mode or force-kill, or finished-workout
  delivery with the phone dead; or deciding whether the WatchConnectivity debug
  transport can be demoted on device builds. NOT for simulator work, template
  sync, or general build/run tasks — see the "When NOT to use this skill" section.
---

# Fortiche device sync campaign

**Mission.** The production live-sync path — watch-authoritative
`HKWorkoutSession` mirroring with `sendToRemoteWorkoutSession` as the wire, a
background-launched phone peer, and a Live Activity — has **never run
end-to-end outside simulators** (status as of 2026-07). Simulators cannot run
it at all: the mirroring transport is Rapport, and paired sims have no Rapport
link (`docs/SPIKE-M1.5.md`). Everything exercised so far went over the
WatchConnectivity (WC) `sendMessage` debug transport. This skill is the
decision-gated campaign to prove the real path on real hardware, phase by
phase, with exact commands, expected observations, and ranked failure menus.

Each phase is a **gate**: do not advance until the phase's evidence is in the
ledger (template at the end). Record negative results too — they are the point.

## When NOT to use this skill

| You actually want to… | Use instead |
|---|---|
| Build, sign, or fix toolchain/SDK issues | `fortiche-build-and-env` |
| Launch the app, seed demo data, use launch args | `fortiche-run-and-operate` |
| General log/simulator/tooling gotchas | `fortiche-diagnostics-and-tooling` |
| Understand WHY the sync design is shaped this way | `fortiche-architecture-contract` |
| Read the incident history behind the hard rules | `fortiche-failure-archaeology` |
| Triage a bug that is not live-sync | `fortiche-debugging-playbook` |
| Run the test suite / QA passes | `fortiche-validation-and-qa` |
| Ship a build to TestFlight | `fortiche-appstore-and-release` |
| Propose the code changes this campaign motivates | `fortiche-change-control` |

## Fenced-off wrong paths (do not spend time here)

1. **Do not debug mirroring on simulators.** Watch-side `healthd` fails with
   HealthKit error 300 "Remote device is unreachable" (Rapport
   `kNotFoundErr 'rapport:rdid:PairedCompanion'`). Nothing you change in app
   code fixes that. Simulators are only valid for UI, engine logic, and the WC
   debug transport.
2. **Do not trust `startMirroringToCompanionDevice()` resolving without
   error.** healthd enqueues and retries internally; the call "succeeds" even
   when the companion is unreachable. The code already treats it this way
   (`startMirroringWithRetry()` in `ForticheWatch/WatchWorkoutController.swift`
   plus the app-level `requestSnapshot`/`snapshot` handshake). Evidence of a
   working channel is a **received snapshot on the phone**, never the call
   returning.
3. **Do not add a second source of truth to "fix" divergence.** The watch
   engine is authoritative while a watch session runs; the phone runs an
   optimistic peer reconciled by echoed snapshots (stale ones rejected via
   `lastAppliedSeq` — see `adopt(snapshot:)` in
   `FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift`). If
   state diverges, the bug is in delivery or reconciliation; adding CloudKit,
   an extra store, or a "merge" layer creates permanent split-brain. Design
   changes go through `fortiche-change-control`.

## Ground map (read once before phase 1)

### Code you will be observing

| File | Role |
|---|---|
| `ForticheWatch/WatchWorkoutController.swift` | Watch-authoritative host: engine + `HKWorkoutSession`/`HKLiveWorkoutBuilder`, `startMirroringWithRetry()`, snapshot echo after every command, `recoverIfNeeded()` crash recovery, `end()` → local log + `queueFinishedWorkout` |
| `Fortiche/MirroringReceiver.swift` | Phone peer: `install()` sets `workoutSessionMirroringStartHandler` + WC callbacks; `attach(to:)` starts the Live Activity with placeholder content and sends `requestSnapshot`; `ingest(finished:)` upserts by UUID |
| `Fortiche/ForticheApp.swift` | Calls `MirroringReceiver.shared.install()` **synchronously in `init`** (hard rule R3 — lazy installation drops background-delivered sessions) |
| `FortichePack/Sources/FortichePack/Sync/ConnectivityHub.swift` | One `WCSession` wrapper: `applicationContext` = templates phone→watch, `transferUserInfo` = finished workouts watch→phone, `sendMessage` = live debug transport, `sessionReachabilityDidChange` → resync hooks |
| `FortichePack/Sources/FortichePack/Engine/WorkoutCommand.swift` | Wire protocol: `SyncMessage` = `.command(CommandEnvelope)` / `.snapshot(WorkoutState)` / `.requestSnapshot` (JSON-encoded) |
| `FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift` | Per-origin dedup by `seq`, disk journal, `adopt(snapshot:)` stale rejection, `recover(localHost:)` |
| `ForticheWidgets/ForticheWidgetsBundle.swift` + `Shared/LiveActivityIntents.swift` | Live Activity UI + button intents (intents compiled into app AND widget — never into the package; hard rule R1) |

### Both sides currently send on BOTH channels

`sendToPhone(_:)` (watch) and `send(_:)` (phone) each write to the mirrored
session **and** call `ConnectivityHub.shared.sendLive(_:)` unconditionally.
Per-origin sequence dedup absorbs the duplicates. This means: on real devices
you cannot tell from behavior alone which channel delivered a message — see
phase 3 for the honest way to attribute, and phase 5 for when the WC live
sends can be demoted.

### Log subsystems and categories (verified in source, 2026-07)

| Subsystem | Category | Emitted by |
|---|---|---|
| `com.davidruiz.fortiche` | `mirroring` | `MirroringReceiver` — "mirrored session received", "ignored stale snapshot", "ingested finished workout <uuid>", "watch disconnected: …" |
| `com.davidruiz.fortiche` | `workout` | `PhoneWorkoutController` (phone-authoritative path only) |
| `com.davidruiz.fortiche` | `connectivity` | `ConnectivityHub` — "WC activated: …", "live send failed: …", "template push failed: …" |
| `com.davidruiz.fortiche` | `intents` | `WorkoutIntentBridge` — "live-activity intent: …" |
| `com.davidruiz.fortiche.watch` | `workout` | `WatchWorkoutController` — "mirroring started", "mirroring attempt failed: …", "recovered workout <uuid>", "phone disconnected: …", "discarding workout under minimum duration" |
| `com.davidruiz.fortiche.watch` | `demo` | Watch demo hook |

One predicate covers both devices: `subsystem BEGINSWITH "com.davidruiz.fortiche"`.

### Domain rules that shape test design

- Workouts under **3 minutes** are discarded everywhere
  (`WorkoutState.minimumSaveDuration = 3 * 60`): no log, no HealthKit, nothing
  queued to the phone. **Any test that must produce a saved workout has to run
  ≥ 3 minutes of wall clock.** Budget for this.
- Finished workouts arrive over up to two channels (final `.snapshot` with
  `isFinished`, and `transferUserInfo`); both funnel into a UUID upsert, so
  "exactly one History entry" is the correctness check, not "delivered once".
- Weights are canonical kilograms; display conversion is irrelevant to sync
  correctness (see `strength-domain-reference` if a number looks "wrong").

---

## Phase 0 — Prerequisites

Do not start phase 1 until every row checks.

| # | Check | How |
|---|---|---|
| 0.1 | Real iPhone + real paired Apple Watch, both on the 27.0 OS matching the SDKs | Watch app on iPhone → General → About; Settings → General → About |
| 0.2 | Xcode 27 beta selected for this shell | `export DEVELOPER_DIR=/Applications/Xcode-beta.app` (every shell; see `fortiche-build-and-env`) |
| 0.3 | Fresh project | `cd /Users/david/Code/Fortiche && xcodegen generate` |
| 0.4 | Signing: `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM` are already set in `project.yml`; HealthKit entitlements need a paid-team profile (noted in `docs/SPIKE-M1.5.md`) | `grep -n "DEVELOPMENT_TEAM\|CODE_SIGN_STYLE" project.yml` |
| 0.5 | Devices visible to the toolchain | `xcrun devicectl list devices` (phone must be connected/trusted; the paired watch appears via the phone — if it does not, open the project in Xcode once and let it "prepare" the watch) |
| 0.6 | App installed on phone (watch app rides along as the embedded bundle) | Build+install commands below, or run the `Fortiche` scheme from Xcode to the phone |
| 0.7 | Watch app installed on the watch | Watch app on iPhone → Available Apps → Install (automatic install of embedded watch apps is known-flaky on simulators; on device, verify rather than assume) |
| 0.8 | Phone launched **foreground** once; HealthKit sheet approved (workout share) | Mirrored delivery on the phone requires prior HealthKit auth — it is requested in `RootView.task` (`MirroringReceiver.requestAuthorization()`), i.e. only after a foreground launch. **Real devices show the sheet; do not carry over the simulator habit of auto-granted auth.** Never pass `--skip-health` in this campaign. |
| 0.9 | Watch launched once; HealthKit sheet approved on watch | Watch asks on first workout start (`startHealthKitSession()`) |
| 0.10 | Live Activities enabled | iPhone Settings → Fortiche → Live Activities ON (the code gate `ActivityAuthorizationInfo().areActivitiesEnabled` fails **silently**) |
| 0.11 | Templates present on watch | Import on phone (real import, or seed with `--demo-import` — see `fortiche-run-and-operate`), then open the phone app once: `pushTemplatesToWatch` runs every launch via `applicationContext`. Watch day list must show the program. |

Build + install from the CLI (or just use Xcode's Run, which is fine here):

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
cd /Users/david/Code/Fortiche
xcodegen generate
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
# discover the phone's identifier, then install:
xcrun devicectl list devices
xcrun devicectl device install app \
  --device <IDENTIFIER-FROM-LIST> \
  build/Build/Products/Debug-iphoneos/Fortiche.app
```

(`-allowProvisioningUpdates` lets automatic signing mint device profiles from
the CLI. Do not hardcode device UDIDs anywhere — always rediscover.)

### Instrumentation setup (used by every phase)

Live: **Console.app** on the Mac. Select the iPhone under Devices, click
Start, filter `subsystem:com.davidruiz.fortiche`. The paired watch appears as
its own device entry when the phone is connected; select it in a second
Console window and filter the same way (its subsystem is
`com.davidruiz.fortiche.watch`, which the prefix filter catches). Enable
Action → Include Info Messages — the interesting lines are `Logger.info`.

Post-hoc (better timestamps, works after a pocket test):

```sh
sudo log collect --device-name "<phone name from devicectl list>" \
  --last 30m --output /tmp/fortiche-phone.logarchive
log show /tmp/fortiche-phone.logarchive --info \
  --predicate 'subsystem BEGINSWITH "com.davidruiz.fortiche"'
```

(`--info` is mandatory — `Logger.info` lines are invisible without it; same
gotcha as the simulator, see `fortiche-diagnostics-and-tooling`.)

---

## Phase 1 — Baseline: watch start, phone unlocked + app foreground

The easiest possible conditions. If this fails, nothing harder can work.

**Procedure**

1. Phone: app foreground, Console streaming both devices.
2. Watch: pick a day, tap start.

**Expected observations, in order (watch a real clock — "within seconds")**

| # | Where | Signal |
|---|---|---|
| 1.1 | watch `workout` | `mirroring started` (may be preceded by one or two `mirroring attempt failed` retries — backoff starts at 2 s) |
| 1.2 | phone `mirroring` | `mirrored session received` |
| 1.3 | phone | Live Activity appears on Lock Screen / Dynamic Island with placeholder "Connecting to watch…" |
| 1.4 | phone | LA content fills in with the real first exercise (first snapshot arrived — this, not 1.1, is proof the channel works) |
| 1.5 | phone app | Full-screen live-workout cover raises (`mirror.isActive`) |

Complete a set on the watch → phone LA and cover update. That is the phase-1
pass. Record timings in the ledger.

**If it fails — ranked menu, with the observation that discriminates:**

| Rank | Hypothesis | Discriminating observation | Action |
|---|---|---|---|
| 1 | Watch never established mirroring (HK auth, entitlement, or session config rejected) | Watch shows `mirroring attempt failed: <error>` repeating with growing backoff and **no** `mirroring started`; read the error text — an entitlement/config problem is a hard error every attempt, not intermittent | Fix per error: HealthKit auth (0.9), watch entitlement `com.apple.developer.healthkit` (in `project.yml`), `WKBackgroundModes: [workout-processing]` present |
| 2 | Mirroring "started" but delivery failed (Rapport link to this phone) | `mirroring started` on watch, but no `mirrored session received` on phone; check watch Console for `healthd` / error 300 lines | Reboot both devices, verify Bluetooth on, watch actually paired to THIS phone; this is the real-device analogue of the sim failure — do not touch app code first |
| 3 | Phone-side HealthKit auth missing (delivery requires it) | Same as rank 2 from the app's view; differs in that phone Health app shows Fortiche without workout-share permission | Foreground-launch phone, approve sheet (0.8), retry |
| 4 | Snapshot lost but session delivered | `mirrored session received` present, LA stuck on "Connecting to watch…" | Reachability blip at exactly the wrong moment (R4-adjacent); background/foreground the phone app or toggle watch screen — either side's reachability handler triggers a resync; if that heals it, note it and continue (phase 4 covers blips properly) |

Only after two clean phase-1 runs: proceed.

## Phase 2 — Background-launch gate: phone locked, in pocket

This is the R3 window under production conditions and has **never been
observed** (the spike was blocked before reaching it — `docs/SPIKE-M1.5.md`
"re-verify on real devices").

**Procedure**

1. Phone: force-quit is NOT the test here — just lock the phone and put it
   away. Kill Console streaming if you like; you will use `log collect` after.
2. Wait ≥ 2 minutes (let the phone app get suspended/evicted naturally; a
   longer wait, 30+ min, is a stronger test — do both eventually).
3. Watch: start a workout. Do not touch the phone.
4. After ~60 s, look at the phone Lock Screen **without unlocking**.

**Expected:** Live Activity on the Lock Screen, placeholder replaced by real
content. Post-hoc log collect must show `mirrored session received` at a
timestamp when the app was not foreground.

**If the LA is absent — ranked menu:**

| Rank | Hypothesis | Discriminating observation | Action |
|---|---|---|---|
| 1 | Handler installed too late / not in the background launch path (R3 regression) | Log archive shows a process launch of Fortiche around watch-start time but **no** `mirrored session received` | Verify `MirroringReceiver.shared.install()` is still literally the first statement in `ForticheApp.init` and nothing before it can block; any fix routes through `fortiche-change-control` (this is a hard rule with an incident behind it) |
| 2 | No background launch happened at all | Log archive shows no Fortiche process activity at that time; watch shows `mirroring started` | Phone-side HK auth (0.8) is the top suspect — background delivery is gated on it; then Low Power Mode, then Screen Time/Focus restrictions |
| 3 | Launched, session received, LA request failed | `mirrored session received` present, no LA | Two sub-cases: (a) Live Activities toggle off — the `areActivitiesEnabled` guard returns **with no log line** (known instrumentation gap: `Activity.request` failures are swallowed by `try?` in `startLiveActivity`; a temporary error log here is a legitimate candidate change via `fortiche-change-control`); (b) request landed outside the ~10 s window — compare the `mirrored session received` timestamp against process-launch timestamp; if attach itself was late the problem is upstream, not ActivityKit |
| 4 | LA started, first snapshot never arrived (placeholder forever) | LA visible but stuck on "Connecting to watch…" | Same as phase-1 rank 4; also confirm the watch was still reachable (wrist raised, app foreground on watch) |

Note the two-stage nature of LA permission: the OS-level toggle
(Settings → Fortiche → Live Activities) governs `areActivitiesEnabled`, and
users can additionally kill an individual activity from the Lock Screen; a
dismissed activity does not come back until the next `attach` — record this
behavior if you observe it.

Gate: two clean runs including one with a 30+ minute pocket interval.

## Phase 3 — Command round-trips and latency

**Procedure**

1. Baseline conditions (phase 1), workout running.
2. Drive commands **from the phone**, both surfaces:
   - Live Activity button "complete set" → logs `live-activity intent:
     completeCurrentSet` (subsystem `com.davidruiz.fortiche`, category
     `intents`);
   - the in-app live cover controls.
3. For each command, watch for: watch state advances (it is the authority —
   the command applies THERE), snapshot echoes back, phone LA/cover update.
4. Drive commands from the watch; phone follows via snapshot.

**Expected:** every phone command visibly round-trips (phone→watch→snapshot→
phone) fast enough to feel immediate. The design expectation (as of 2026-07,
**unvalidated — validating it is this phase's job**) is that the mirrored
channel delivers in the low hundreds of ms, comfortably beating the WC
`sendMessage` path (~250 ms class). Sub-second round-trips = pass;
multi-second = investigate.

**Measuring honestly.** There is no receive-side log line on either side
(snapshot adoption and command application are silent in the current code),
so log timestamps alone cannot give you round-trip time, and since both sides
send on both channels simultaneously (dedup absorbs the loser), behavior
cannot attribute a delivery to a channel. Two options:

- **Zero-code:** film both devices in one 60 fps video (phone LA + watch
  screen); count frames between phone tap and watch state change, and back.
  Good enough for pass/fail against "sub-second".
- **Attribution / precise:** add temporary `Logger.info` lines in
  `didReceiveDataFromRemoteWorkoutSession` (both controllers) and
  `ConnectivityHub.session(_:didReceiveMessage:)` tagging the channel. This is
  a code change — even a temporary one goes through `fortiche-change-control`
  (propose it as removable instrumentation, or as a permanent debug-level
  log, which is the better ask).

Also verify per-origin dedup is doing its job: a command delivered by both
channels must apply **once** (watch state advances by exactly one set per
tap). Double-application means seq/dedup breakage — stop and file it; do not
"fix" by removing a channel.

**If round-trips are slow or lossy — ranked menu:**

| Rank | Hypothesis | Discriminating observation | Action |
|---|---|---|---|
| 1 | Mirrored channel dead; WC carrying everything | With attribution logging: all receipts tagged WC; without: latency degrades exactly when WC reachability drops (screen off, watch app backgrounded) | Treat as phase-1 rank 2 failure that regressed mid-session; check `watch disconnected` / `phone disconnected` log lines |
| 2 | Reachability blip cancelling WC sends while mirrored also down | `live send failed` on the sender + temporary total silence, then convergence after `sessionReachabilityDidChange` resync (R4) | Expected behavior — verify convergence, record blip duration; no code action |
| 3 | Stale-snapshot rejection loop (phone optimistic edits racing) | phone `mirroring` logs `ignored stale snapshot` repeatedly while UI lags | Expected in bursts; pathological if continuous — capture logs and file via `fortiche-change-control`, do NOT weaken `adopt`'s rejection rule |

Gate: 20+ round-trips from each side, zero double-applies, zero lost commands
(a "lost" command = watch state never advanced), latency recorded.

## Phase 4 — Adversarial: blips, kills, and a dead phone

Run each scenario with a workout that is already past the 3-minute mark
(otherwise the finish scenarios silently discard everything and prove nothing).

### 4a. Airplane-mode the phone mid-workout

1. Mid-workout, enable Airplane Mode on the phone (leave the watch alone).
2. Continue completing sets on the watch for 2+ minutes.
3. Disable Airplane Mode.

Expected: the watch never blocks (it is authoritative and local); the watch
may log `phone disconnected: …` and resume `mirroring attempt failed` retries;
phone LA freezes. On reconnect, **both** resync hooks fire —
`sessionReachabilityDidChange` makes the watch push a fresh snapshot and the
phone send `requestSnapshot` — and the phone LA/cover must converge to the
watch's current state within seconds, with no rolled-back sets.

Phone edits during the gap are a separate, known-weak behavior — score them
against the architecture contract, not against wishful thinking. There is no
offline queue and no UI feedback: `MirroringReceiver.send` is fire-and-forget
(the `sendToRemoteWorkoutSession` completion is ignored and
`ConnectivityHub.sendLive` is best-effort), so an edit made while both
transports are down is applied locally on the phone and then **lost**.
Because the watch never acknowledges the lost seq, `adopt()` rejects every
subsequent snapshot (repeating `ignored stale snapshot` in the `mirroring`
log after reconnect) until either the seq map converges or the finished-state
snapshot arrives — `adopt` short-circuits on `state.isFinished` and tears
down regardless. So the phone's view may stay frozen on its optimistic state
for the rest of the session; that is the documented design gap
(**fortiche-architecture-contract** §7, "No offline phone command queue"),
not a campaign failure. **Explicit 4a deliverable:** attempt one phone edit
during the gap and record what happens — whether the edit is lost, whether
`ignored stale snapshot` repeats after reconnect, and whether the phone view
recovers before the finish snapshot.

### 4b. Force-kill the watch app mid-workout

Swipe-kill the watch app (hold side button → swipe the card), relaunch it.

Expected: `recovered workout <uuid>` (watch `workout` category) —
`recoverIfNeeded()` runs `HKHealthStore.recoverActiveWorkoutSession` plus the
engine journal. Verify the R5 hardening held: the completion re-checks
`engine == nil` (no duplicate engine), and the recovered engine resumes its
sequence counter from `lastAppliedSeq` — observable as: sets completed on the
watch **after** recovery still propagate to the phone (a fresh counter would
self-dedup and go silent; that exact bug happened once).

### 4c. Force-kill the phone app mid-workout

Swipe-kill Fortiche on the phone.

Expected chain: watch logs `phone disconnected`, restarts the mirroring retry
loop → phone gets a fresh background launch → handler installed in
`ForticheApp.init` fires → `mirrored session received` again → LA re-requested
(the `attach` path is the ONLY place a new LA is requested; the WC-snapshot
path only updates existing activities). Two things to record explicitly:

- Does force-quit take the Live Activity down, and does the re-attach bring it
  back? (Untested on hardware; this is exactly the kind of fact this campaign
  exists to establish.)
- How long until re-attach? (Bounded by the watch's retry backoff, which grows
  toward 60 s — a slow re-attach here is the backoff, not a new bug.)

### 4d. Finish with the phone dead

1. Power the phone **off** entirely.
2. Finish the workout on the watch (≥ 3 min total). Watch behavior must be
   fully local: log saved on watch, HealthKit workout finished on watch, no
   hang or error surfaced to the user. `queueFinishedWorkout` puts the
   `FinishedWorkoutDTO` into `transferUserInfo` (queued, survives everything).
3. Power the phone on. `transferUserInfo` may background-launch the app; if
   nothing arrives within a few minutes, launch Fortiche manually.

Expected: phone logs `ingested finished workout <uuid>` (`mirroring`
category), and History shows **exactly one** entry for it. This is also the
dual-channel dedup check: in scenarios where the phone was alive at finish,
the workout legitimately arrives twice (final snapshot + userInfo transfer)
and the UUID upsert must still yield one History row — check after 4a–4c too.

**Failure menu for 4d:**

| Rank | Hypothesis | Discriminating observation |
|---|---|---|
| 1 | Workout was under 3 minutes | Watch logs `discarding workout under minimum duration`; nothing was ever queued — rerun longer, this is by design |
| 2 | Transfer queued but not yet delivered | No `ingested finished workout` yet; WC delivers on its own schedule — foreground the phone app, wait, re-collect logs before concluding loss |
| 3 | Duplicate History rows | Upsert-by-UUID broke (`ingest` in `MirroringReceiver`, `upsert` in `PhoneWorkoutController`) — file it; do not hand-dedupe |

Gate: all four scenarios pass with logs archived.

## Phase 5 — Promotion: demoting the WC debug transport

Today `sendLive` (WC `sendMessage`) runs unconditionally on device builds,
shadowing the mirrored channel. It was built as the **simulator** debug
transport; on hardware it is redundant bandwidth and a mask over mirrored-
channel regressions. Demotion = stop sending/consuming live messages over WC
on real devices (e.g. gate behind `#if targetEnvironment(simulator)`), while
keeping `applicationContext` (templates) and `transferUserInfo` (finished
workouts), which are production channels regardless.

**Evidence required before proposing it (all of it, on hardware):**

- [ ] Phases 1–4 pass, ledger complete, log archives kept.
- [ ] Channel attribution (phase 3 instrumentation) shows the mirrored channel
      delivering during: baseline, background-launch, and post-reconnect
      phases — i.e. the WC path was never load-bearing in any scenario.
- [ ] A full workout run with WC live traffic experimentally disabled (local,
      uncommitted build) reproduces phases 1, 2, and 4a with no behavior
      change.
- [ ] Explicit answer for the 4c LA-restoration question (since the WC
      snapshot path today is a fallback signal for phone UI raise, per the
      comment in `adoptEngine` — confirm the mirrored re-attach alone covers
      it).

Then write the proposal via `fortiche-change-control` — this campaign
produces evidence, not merged code. The proposal must keep the WC transport
fully functional under `targetEnvironment(simulator)` (the sim dev loop
depends on it; R2 is permanent).

If ANY phase shows the WC path carrying production traffic that mirroring
drops, the outcome flips: WC live transport gets **documented as a production
fallback** instead of demoted, and the mirrored-channel gap gets its own
investigation. Both outcomes are wins; pick the one the evidence picks.

---

## Evidence ledger (copy into the campaign notes)

```
Date / OS builds / Xcode:            hardware: iPhone ___ + Watch ___
Phase 0 checklist:                   [ ] 0.1 … [ ] 0.11
P1 run A: session-received latency ___ s   first-snapshot latency ___ s
P1 run B: ...
P2 short-pocket: LA on lock screen? ___   launch→attach gap ___ s
P2 long-pocket (30m+): ...
P3: N round-trips ___  double-applies ___  lost ___  median latency ___ ms
    channel attribution method: video / temp-logging (CC ref: ___)
P4a airplane: convergence after reconnect ___ s   rollbacks observed? ___
    phone edit during gap: lost? ___  'ignored stale snapshot' repeats? ___
    phone view recovered before finish snapshot? ___
P4b watch kill: recovered uuid ___  post-recovery propagation OK? ___
P4c phone kill: LA restored? ___  re-attach delay ___ s
P4d phone dead: ingested uuid ___  history rows for uuid: ___ (must be 1)
Log archives saved to: ___
Promotion verdict: demote WC / keep as fallback / blocked by ___
```

## Provenance and maintenance

Facts above were verified against the repo on 2026-07-05. Before running the
campaign, re-verify the ones that drift:

- Log categories/subsystems: `grep -rn "Logger(" Fortiche ForticheWatch FortichePack/Sources --include="*.swift"`
- Handler installed in app init (R3): `grep -n "install()" Fortiche/ForticheApp.swift`
- Both-channel sending still unconditional: `grep -n "sendLive" Fortiche/MirroringReceiver.swift ForticheWatch/WatchWorkoutController.swift`
- Mirroring retry + non-trust of the call: `grep -n "startMirroringWithRetry" ForticheWatch/WatchWorkoutController.swift`
- 3-minute discard rule: `grep -n "minimumSaveDuration" FortichePack/Sources/FortichePack/Engine/WorkoutState.swift`
- Stale-snapshot rejection: `grep -n "adopt(snapshot" FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift`
- Phone HK auth request site (foreground-gated): `grep -n "requestAuthorization" Fortiche/RootView.swift`
- Entitlements/background modes: `grep -n "healthkit\|WKBackgroundModes\|NSSupportsLiveActivities" project.yml`
- Sim mirroring still broken on current beta (R2): re-read `docs/SPIKE-M1.5.md`; if a new Xcode/OS beta lands, a 10-minute re-run of the spike is cheaper than trusting this doc.
- `devicectl` verb spellings (Xcode beta churn): `xcrun devicectl --help`, `xcrun devicectl device install app --help`.

Volatile / unproven items intentionally labeled as such in the text: the
~250 ms mirrored-vs-WC latency expectation (design prior, unmeasured); LA
survival across force-quit (unknown); background `transferUserInfo` launch
timing (OS-scheduled); watch visibility in `devicectl list devices`.
