---
name: fortiche-debugging-playbook
description: >
  Symptom-driven triage runbook for Fortiche (iOS 27 / watchOS 27 strength app).
  Start here when you have a symptom but no hypothesis — something is BROKEN
  at runtime and you need the discriminating
  experiment: Live Activity buttons do nothing, the phone never shows a
  watch-run workout, workout state diverges between watch and phone, a workout
  vanished after a crash or app kill, the template parser produces wrong
  sets/weights, the app icon looks stale on the simulator, `log show` returns
  nothing, or the watch app won't launch after install. Each entry gives exact
  commands and the output lines that decide between causes. Not for build/setup
  errors (see fortiche-build-and-env) or for launching demo flows
  (see fortiche-run-and-operate).
---

# Fortiche debugging playbook

Symptom → discriminating experiment → verdict. Every command below was
verified against the repo as of 2026-07; volatile OS-level details are
date-stamped. Run commands from the repo root.

## When NOT to use this skill

- **Build fails, wrong SDK, xcodegen questions** → `fortiche-build-and-env`.
- **You just want to run/demo the app** (launch args, seeding, screenshots) → `fortiche-run-and-operate`.
- **General simulator/log/sqlite tooling reference** (not tied to one symptom) → `fortiche-diagnostics-and-tooling`.
- **The full story of WHY a rule exists** (incident narratives) → `fortiche-failure-archaeology`.
- **Design rationale for the sync protocol / engine** → `fortiche-architecture-contract`.
- **Test-matrix and QA process** → `fortiche-validation-and-qa`.
- **Real-device mirroring test campaign** → `fortiche-device-sync-campaign`.
- **FoundationModels / guided-generation details** → `fortiche-intelligence-reference`.

## Ground rules for every session

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app   # Xcode 27 beta; nothing works without this
```

Discover identifiers instead of hard-coding them:

```sh
xcrun simctl list devices booted            # booted sim UDIDs
xcrun simctl list pairs                     # phone↔watch pairing state ("(active, connected)")
# Built app bundle for the iOS-sim configuration:
APP="$(xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
  | awk '/BUILT_PRODUCTS_DIR/{print $3; exit}')/Fortiche.app"
```

Bundle IDs (from `project.yml`): app `com.davidruiz.fortiche`, watch
`com.davidruiz.fortiche.watchkitapp`, widget ext `com.davidruiz.fortiche.widgets`.

Logger subsystems/categories (grep-verified against the sources):

| Process | Subsystem | Categories |
|---|---|---|
| iPhone app | `com.davidruiz.fortiche` | `mirroring` (MirroringReceiver), `workout` (PhoneWorkoutController), `intents` (WorkoutIntentBridge), `connectivity` (ConnectivityHub) |
| Watch app | `com.davidruiz.fortiche.watch` | `workout` (WatchWorkoutController), `demo` (launch-arg hook) |

**Almost everything is logged at `.info` — see symptom 7 before concluding "no logs".**

## Symptom index

| # | Symptom | First check |
|---|---|---|
| 1 | Live Activity buttons do nothing | `chronod` "no metadata" line; `Metadata.appintents` in the built app |
| 2 | Phone never shows a watch-run workout | Simulator? Then mirroring CANNOT work — check WC reachability instead |
| 3 | State diverges between watch and phone | `lastAppliedSeq` maps + "ignored stale snapshot" |
| 4 | Workout lost after crash/kill | Journal file exists? Under 3 minutes? Host mismatch? |
| 5 | Parser wrong sets/weights | Reproduce with the deterministic parser first |
| 6 | App icon looks stale | SpringBoard cache, not your asset |
| 7 | Logs seem empty | You forgot `--info` / `--level info` |
| 8 | Watch app won't launch after install | Embedded auto-install is flaky; install the inner bundle directly |

---

## 1. Live Activity buttons do nothing

Tapping Complete Set / Skip Rest / Pause on the Live Activity has no effect,
no log line, no error. The intents are `CompleteSetIntent`, `SkipRestIntent`,
`PauseResumeIntent` in `Shared/LiveActivityIntents.swift` (compiled into BOTH
the app and widget targets — never into FortichePack; see rule below).

### Step 1 — did the tap reach the app at all?

```sh
xcrun simctl spawn booted log show --info --last 5m \
  --predicate 'subsystem == "com.davidruiz.fortiche" AND category == "intents"'
```

- **EXPECTED (healthy):** `live-activity intent: completeCurrentSet` (from
  `WorkoutIntentBridge` in `FortichePack/Sources/FortichePack/LiveActivity/WorkoutIntents.swift`).
- **If you instead see** `completeCurrentSet: no engine — attempting journal recovery`
  followed by `dropped, no active workout` → the intent RAN but no engine was
  live. That is symptom 4 territory (recovery), not a metadata problem.
- **Nothing at all** → the system never invoked the intent. Continue.

### Step 2 — ask chronod (the Live Activity daemon)

```sh
xcrun simctl spawn booted log show --info --last 10m \
  --predicate 'process == "chronod" AND eventMessage CONTAINS "metadata"'
```

- **EXPECTED failure signature (the R1 incident):**
  `There is no metadata for CompleteSetIntent in com.davidruiz.fortiche`
- If you see that line, the App Intents metadata index for the bundle is
  missing/empty. Continue to linkd (the OS daemon that indexes App Intents
  metadata from installed bundles into `appintents.sqlite3`).

### Step 3 — check the built product's metadata and the debug-dylib setting

One-command alternative: steps 3–4 are automated by
`.claude/skills/fortiche-diagnostics-and-tooling/scripts/intent-doctor.sh`
(run from the repo root) — see `fortiche-diagnostics-and-tooling` for
interpretation. The manual steps below are the explain-what-it-checks layer.

```sh
ls "$APP/Metadata.appintents/"            # must exist and be non-trivial
grep -rc CompleteSetIntent "$APP/Metadata.appintents/" ; echo "(want >0 matches)"
ls "$APP" | grep -i 'debug.dylib'          # EXPECTED: no output
grep -n ENABLE_DEBUG_DYLIB project.yml     # EXPECTED: ENABLE_DEBUG_DYLIB: NO
```

If `Fortiche.debug.dylib` exists in the app bundle, or `ENABLE_DEBUG_DYLIB`
is not `NO`, that IS the bug: linkd cannot parse the debug-dylib stub main
executable, logs `Failed to resolve package data ... EINVAL` in its audit
table, and then indexes NOTHING for the bundle — every intent tap dies with
the chronod line above. Same failure if any `AppIntent` lives inside the
FortichePack Swift package (statically-linked package intents emit
`extract.packagedata` entries linkd also rejects).

### Step 4 — inspect linkd's audit database (optional, decisive)

Path is discovered, never hard-coded (as of 2026-07, simulator):

```sh
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
DB=$(find ~/Library/Developer/CoreSimulator/Devices/$UDID/data -name 'appintents.sqlite3' 2>/dev/null | head -1)
sqlite3 "$DB" '.tables'                    # look for an audit/errors table
sqlite3 "$DB" 'SELECT * FROM audit_errors;' 2>/dev/null | grep -i fortiche
```

- **EXPECTED failure signature:** rows containing
  `Failed to resolve package data ... Invalid argument` referencing the
  Fortiche bundle. (Table name `audit_errors` is from the 2026-07 incident;
  if the schema drifted, use `.tables` output.)

### Fix

Never move intents into FortichePack; keep `ENABLE_DEBUG_DYLIB: NO` in
`project.yml` (comment at `settings.base` explains it); Live Activity intents
stay in `Shared/` (compiled into app AND widget); Siri intents +
`ForticheShortcuts: AppShortcutsProvider` stay in `Fortiche/Intents/`
(Apple requires the provider in the app target). After any change:
`xcodegen generate`, rebuild, reinstall, **then reboot the sim or respring**
(linkd re-indexes on install). Full incident: `fortiche-failure-archaeology`.
Changing these settings is change-controlled: `fortiche-change-control`.

---

## 2. Phone never shows a watch-run workout

Watch is mid-workout; the phone app shows no live session / no Live Activity.

### Step 0 — are you on simulators?

**HKWorkoutSession mirroring does not work between paired simulators**
(as of Xcode 27 beta, 2026-07). Watch-side `healthd` fails with
`Error Domain=com.apple.healthkit Code=300 "Remote device is unreachable"`
caused by Rapport `kNotFoundErr ('rapport:rdid:PairedCompanion' not found)`.
Worse: `startMirroringToCompanionDevice()` **resolves without error anyway**
— never treat the call's success as evidence of anything. Full spike:
`docs/SPIKE-M1.5.md`. On simulators the ONLY live channel is the
WatchConnectivity debug transport (`WCSession.sendMessage`), which
`WatchWorkoutController.sendToPhone` always uses in parallel.

Confirm which channel you should expect:

```sh
xcrun simctl list pairs        # sims: expect "(active, connected)" — necessary for WC, irrelevant for mirroring
```

### Step 1 — is the watch actually sending snapshots?

One-command alternative: `.claude/skills/fortiche-diagnostics-and-tooling/scripts/mirror-trace.sh`
(run from the repo root) captures both sides of this conversation at once and
scans for the known signatures — see `fortiche-diagnostics-and-tooling` for
interpretation. The manual steps below explain what it looks for.

The watch echoes a full snapshot after EVERY applied command
(`adoptEngine` wires `onStateChange` → `sendToPhone(.snapshot)`), and
re-sends on every reachability gain.

```sh
WATCH=$(xcrun simctl list devices booted | grep -i watch | grep -oE '[0-9A-F-]{36}')
xcrun simctl spawn $WATCH log show --info --last 5m \
  --predicate 'subsystem == "com.davidruiz.fortiche.watch" OR (subsystem == "com.davidruiz.fortiche" AND category == "connectivity")'
```

- **EXPECTED (healthy sim path):** `WC activated: 2` and no repeating
  `live send failed: ...` lines.
- `live send failed: ...` repeating → WC delivery failing; check pairing,
  and remember R4: **WC sends during reachability blips are silently
  cancelled** (`shouldCancel: YES` in WC's own logs). Both sides self-heal on
  `sessionReachabilityDidChange` — watch re-sends its snapshot, phone sends
  `.requestSnapshot` — so a blip should recover within seconds of
  reachability returning. If it doesn't, the phone app probably isn't running
  (WC `sendMessage` needs a reachable counterpart; launch the phone app).
- On real devices also expect `mirroring started`, or repeated
  `mirroring attempt failed: ...` (the watch retries with backoff for the
  life of the workout — by design, because of the lying success).

### Step 2 — is the phone receiving?

```sh
xcrun simctl spawn booted log show --info --last 5m \
  --predicate 'subsystem == "com.davidruiz.fortiche" AND (category == "mirroring" OR category == "connectivity")'
```

- **EXPECTED (real devices):** `mirrored session received` — proves the
  system delivered the mirrored `HKWorkoutSession`. If a workout is running
  on the watch and this never appears on a real phone: verify the handler is
  installed **synchronously in `ForticheApp.init`** (R3 — it is today, via
  `MirroringReceiver.shared.install()`; if someone made it lazy, that's the
  regression). Background launch delivers the session immediately at process
  start; the Live Activity must be requested inside that handler's ~10 s
  window with placeholder content (`startLiveActivity(title: "Workout")`
  does this).
- **EXPECTED (sims):** no mirroring lines ever; instead the phone UI raises
  once a WC snapshot arrives. Trigger the handshake manually by
  foregrounding the phone app — reachability gain fires
  `send(.requestSnapshot)`.
- `ignored stale snapshot` → not a delivery problem; go to symptom 3.

### Step 3 — finished workout missing from phone history

Finished workouts travel on TWO channels: the final `.snapshot` (live) and
`transferUserInfo` (queued, survives phone-dead). Ingest is idempotent by
UUID. Check:

```sh
xcrun simctl spawn booted log show --info --last 10m \
  --predicate 'subsystem == "com.davidruiz.fortiche" AND category == "mirroring"'
```

- **EXPECTED:** `ingested finished workout <UUID>`.
- `ignoring finished workout under minimum duration` → by design: workouts
  under **3 minutes** (`WorkoutState.minimumSaveDuration = 3 * 60`) are
  discarded everywhere — no log, no HealthKit, nothing queued. Not a bug.
- Nothing → `transferUserInfo` delivers on next phone-app run; launch the
  phone app and re-check. Real-device campaign: `fortiche-device-sync-campaign`.

---

## 3. State diverges between watch and phone

Phone shows different completed sets / weights than the watch during a live
session.

Mental model (one-home: `fortiche-architecture-contract`): the watch is
authoritative while a watch session runs. The phone runs an optimistic peer
engine; its local edits are applied immediately AND forwarded as
`CommandEnvelope`s (per-origin monotonic `seq`); the watch applies them and
echoes a full snapshot. The phone's `adopt(snapshot:)` **rejects any snapshot
whose `lastAppliedSeq[phone]` hasn't caught up to the phone's own last sent
seq** (`acknowledged < nextSeq - 1` in `ActiveWorkoutEngine.adopt`) so
optimistic edits never visibly roll back. Duplicate/out-of-order envelopes
are dropped by `apply()` (`seq <= lastAppliedSeq[origin]`).

### Discriminating experiment

1. Watch the phone's mirroring log while making one edit on the phone:

```sh
xcrun simctl spawn booted log stream --level info \
  --predicate 'subsystem == "com.davidruiz.fortiche" AND category == "mirroring"'
```

- **A short burst of `ignored stale snapshot` right after a phone edit is
  NORMAL** — the echo of an older state raced your newer command.
- **`ignored stale snapshot` repeating indefinitely with no convergence** →
  the watch is not acknowledging phone commands: either the phone→watch
  command channel is down (symptom 2, step 1) or the seq bookkeeping broke.

2. Inspect the authoritative seq map in the watch journal (single source of
truth for what the watch has applied):

```sh
WATCH=$(xcrun simctl list devices booted | grep -i watch | grep -oE '[0-9A-F-]{36}')
WDATA=$(xcrun simctl get_app_container $WATCH com.davidruiz.fortiche.watchkitapp data)
python3 -m json.tool "$WDATA/Library/Application Support/active-workout.json" | grep -A3 lastAppliedSeq
```

- **EXPECTED:** a map like `{"watch": N, "phone": M}` where `M` advances
  every time you edit on the phone. If `phone` never appears/advances, phone
  commands aren't arriving (symptom 2) — the divergence is a delivery
  problem, not an engine bug.
- Note: the phone's MIRROR engine is constructed with `journalURL: nil`
  (`MirroringReceiver.adopt`) — there is deliberately **no phone-side journal
  to inspect for a watch-run workout**. Only phone-authoritative workouts
  journal on the phone.

3. Force convergence to test the self-heal path: toggle reachability (on
sims: quit and relaunch the phone app). On reachability gain the phone sends
`.requestSnapshot` and the watch replies with full state — both sides must
match afterwards. If they match after a forced snapshot but drift again
during edits, suspect envelope loss mid-session (R4 blips).

Engine-level invariants are unit-tested — before blaming the engine, run:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
swift test --package-path FortichePack --filter EngineTests    # dedup, adopt-rejection, recovery seq
```

---

## 4. Workout lost after crash / app kill

### Checklist, in order of likelihood

1. **Was it under 3 minutes?** Discarded by design
   (`WorkoutState.minimumSaveDuration`). Log line on either host:
   `discarding workout under minimum duration`. Not a bug — stop here.
2. **Does the journal exist?** Every applied command journals full state to
   `Application Support/active-workout.json`; it is deleted when the state is
   finished (`isFinished`) or on clean `end()`.

```sh
PDATA=$(xcrun simctl get_app_container booted com.davidruiz.fortiche data)
ls -l "$PDATA/Library/Application Support/active-workout.json"
python3 -m json.tool "$PDATA/Library/Application Support/active-workout.json" | head -20
```

   - **File exists with unfinished state** → recovery should trigger on next
     launch. Relaunch and check the log:

```sh
xcrun simctl launch booted com.davidruiz.fortiche
xcrun simctl spawn booted log show --info --last 2m \
  --predicate 'subsystem == "com.davidruiz.fortiche" AND category == "workout"'
```

   - **EXPECTED:** `recovered in-progress workout <UUID>` (phone) — from
     `PhoneWorkoutController.recoverIfNeeded()`, called in `RootView.task`
     and as the Live Activity `recoveryFallback` (background relaunch by a
     button tap has no UI, so the bridge restores the engine itself).
     Watch equivalent: `recovered workout <UUID>` under subsystem
     `com.davidruiz.fortiche.watch`.
   - **File exists but no recovery line** → check the host field:
     `python3 -m json.tool ... | grep '"host"'`. Recovery requires
     `state.host` to match the local host (`recovered.state.host == .phone`
     / `.watch`) — a journal written by the other role is intentionally
     ignored. Also check `phase`: a finished (`ended`) state is skipped by
     `ActiveWorkoutEngine.recover`.
3. **Watch-specific races (R5)** — both are guarded in code today; if you
   see duplicates or self-ignoring commands, check for regressions at these
   exact points in `ForticheWatch/WatchWorkoutController.swift`:
   - `healthStore.recoverActiveWorkoutSession` completion can fire AFTER the
     user already started a NEW workout — the completion re-checks
     `self.engine == nil` before adopting. Removing that guard once caused a
     duplicate engine adoption.
   - Recovery must resume the sequence counter:
     `nextSeq = lastAppliedSeq[localHost] + 1` in `ActiveWorkoutEngine.init`.
     A fresh counter's commands get deduped by the device's own restored
     `lastAppliedSeq` (this happened; the comment on init documents it).
   - Orphan HK session with no journal → the controller calls
     `session.end()` on it. That's the intended path, not a lost workout.
4. **Workout finished on watch but phone history is empty** → symptom 2,
   step 3 (dual-channel ingest; launch the phone app to drain
   `transferUserInfo`).

---

## 5. Parser produces wrong sets / weights

Template import mangles a program: wrong set counts, phantom weights,
bodyweight rows getting "0 kg", OHP unmatched.

### Step 1 — separate the model from the deterministic pipeline

Two parsers implement `ProgramParsing`
(`FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift`):
`IntelligentProgramParser` (FoundationModels guided generation, one
`@Generable GeneratedDay` per day-chunk, temperature 0) and
`HeuristicProgramParser` (pure regex, the availability fallback AND the
reference implementation). Segmentation into day chunks is deterministic for
both (`ProgramSegmenter`). Per-day model failures silently degrade to the
heuristic parser (`usedFallback: true`) — so a "model bug" may actually be a
heuristic-parser bug on one day.

Deterministic reproduction (no model, runs anywhere, verified 2026-07):

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
swift test --package-path FortichePack --skip IntelligentParserTests
# EXPECTED: "passed" with zero failures (full suite minus the 2 model-dependent
# IntelligentParserTests; totals live in fortiche-build-and-env)
swift test --package-path FortichePack --filter HeuristicProgramParserTests
# EXPECTED: "Test run with 2 tests in 1 suite passed"
```

Add your failing program text as a case in
`FortichePack/Tests/FortichePackTests/ParsingTests.swift`
(suites: `SegmenterTests`, `HeuristicLineParserTests`,
`HeuristicProgramParserTests`). If the heuristic parser reproduces the bug,
fix it there — done.

Live-model integration tests run ONLY where Apple Intelligence is available
(gated by `@Suite(.enabled(if: IntelligentProgramParser.availability == .available))`);
on this Mac they run as part of the full suite:

```sh
swift test --package-path FortichePack --filter IntelligentParserTests
# EXPECTED where AI is available: 2 tests pass (each budgeted 3 min); elsewhere: skipped
```

### Step 2 — known model quirks (R6) before filing an engine bug

- **Zero means "not specified".** The small model emits `0` for unspecified
  rest, weight, and percent. Sanitization lives in
  `ParsedDay.init(generated:)` (TemplateParser.swift): `restSeconds` ≤ 0 →
  nil, `weightKg` ≤ 0 → nil (bodyweight), `percent` ≤ 0 → nil, setCount
  clamped to 1...30. A "0 kg" reaching the UI means this conversion layer
  was bypassed or regressed — fix THERE, not in the prompt.
- **Set groups, not per-set arrays.** The schema is
  setCount + one prescription (`GeneratedSetGroup`) expanded with `flatMap`;
  per-set array emission was unreliable on the small model. Don't "improve"
  it back.
- **"Overhead press" does not exist in the dataset.** The bundled
  free-exercise-db (873 entries) only says "shoulder press" / "military
  press". Verified:

```sh
python3 -c "import json;d=json.load(open('FortichePack/Sources/FortichePack/ExerciseLibrary/Resources/exercises.json'));print(len(d), sum('overhead press' in e['name'].lower() for e in d))"
# EXPECTED: 873 0
```

  Matching is handled by the alias table in `ExerciseMatcher.swift`
  (`"ohp": "shoulder press"`, etc.) plus Damerau-Levenshtein with a
  conservative auto-assign; unmatched names legitimately stay free-form.
  Test: `swift test --package-path FortichePack --filter ExerciseMatcherTests`.

Model/prompt-level details and watchOS limitations (R7: no on-watch local
model): `fortiche-intelligence-reference`.

---

## 6. App icon looks stale on the simulator

You regenerated the icon but the home screen shows the old one. SpringBoard
caches icons **across reinstalls**.

```sh
swift Scripts/generate_icon.swift --catalog        # regenerate into the asset catalogs (never hand-edit)
xcodegen generate
# Rebuild + reinstall (full recipe with the watch-app workaround:
# fortiche-run-and-operate §1.2–1.3):
PHONE=$(xcrun simctl list devices booted | grep -i iphone | grep -oE '[0-9A-F-]{36}' | head -1)
DD=/tmp/fortiche-dd
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination "platform=iOS Simulator,id=$PHONE" \
  -derivedDataPath "$DD" build
xcrun simctl install "$PHONE" "$DD/Build/Products/Debug-iphonesimulator/Fortiche.app"
# Icon still old? It's the cache:
xcrun simctl uninstall booted com.davidruiz.fortiche   # then reinstall — most reliable
# or respring without uninstalling:
xcrun simctl spawn booted launchctl kickstart -k system/com.apple.SpringBoard
```

Verdict rule: if `Assets.xcassets/AppIcon.appiconset` contents changed
(check file hashes/dates) but the home screen didn't, it is ALWAYS the cache
— do not touch the generator script. Icon pipeline ownership:
`fortiche-build-and-env`; the generated-artifacts rule (R8) forbids
hand-editing catalog output.

---

## 7. Logs seem empty

One-command alternative: `.claude/skills/fortiche-diagnostics-and-tooling/scripts/applog.sh`
(run from the repo root) applies the correct flags for you — see
`fortiche-diagnostics-and-tooling` for the option set.

Nearly all Fortiche logging is `Logger.info`, and (as of 2026-07, iOS 27
sims) the `log` tool hides info-level by default:

```sh
# log show: REQUIRES --info, or every Logger.info line is invisible:
xcrun simctl spawn booted log show --info --last 5m \
  --predicate 'subsystem == "com.davidruiz.fortiche"'
# log stream: REQUIRES --level info:
xcrun simctl spawn booted log stream --level info \
  --predicate 'subsystem == "com.davidruiz.fortiche"'
```

Discriminating experiment: launch the app and look for the WC activation
line, which fires on every phone launch:

- **EXPECTED with the flags:** `WC activated: 2` (category `connectivity`).
- Same command without `--info` shows nothing → your flags were the problem,
  not the app.

Watch side: same flags, subsystem `com.davidruiz.fortiche.watch`, spawn on
the watch UDID. The `--demo-workout` hook logs
`demo hook: templates=<n> args=...` at watch launch — a handy liveness probe.

---

## 8. Watch app won't launch after install

The watch app auto-install from the embedded iOS bundle is flaky on paired
simulators (as of Xcode 27 beta). Install the inner watch bundle directly:

```sh
# 1) Find the built iOS app (see Ground rules) — the watch app is nested inside it:
ls "$APP/Watch/"                          # EXPECTED: ForticheWatch.app
# 2) Install it straight onto the watch sim:
WATCH=$(xcrun simctl list devices booted | grep -i watch | grep -oE '[0-9A-F-]{36}')
xcrun simctl install $WATCH "$APP/Watch/ForticheWatch.app"
# 3) Launch headlessly (no permission sheets, auto-start first day):
xcrun simctl launch $WATCH com.davidruiz.fortiche.watchkitapp --demo-workout --skip-health
```

- **EXPECTED:** launch prints a PID; then the `demo` category logs appear
  (symptom 7 flags!): `demo hook: templates=<n> ...`. `templates=0` means the
  watch has no catalog yet — push one by launching the phone app with
  `--demo-import` (every phone launch re-pushes the catalog via
  `applicationContext`), or start a day manually in the watch UI.
- Install error about a missing companion → check `xcrun simctl list pairs`;
  the pair must exist and both sims be booted. (Pairing state matters for
  WC; it does NOT enable HK mirroring — symptom 2, step 0.)
- Note Xcode 27 replaced Simulator.app with Device Hub
  (`/Applications/Xcode-beta.app/Contents/Applications/DeviceHub.app`) — use
  it to see both screens.

---

## Provenance and maintenance

Verified against the repo on 2026-07-05 (Xcode 27 beta, iOS/watchOS 27.0
sims). Re-verify before trusting, in one line each:

- Intent names + shared-target rationale: `sed -n 1,20p Shared/LiveActivityIntents.swift`
- Bridge log strings ("no engine", "dropped"): `grep -n 'logger' FortichePack/Sources/FortichePack/LiveActivity/WorkoutIntents.swift`
- `ENABLE_DEBUG_DYLIB: NO` + comment: `grep -n -B6 ENABLE_DEBUG_DYLIB project.yml`
- Bundle IDs: `grep -n PRODUCT_BUNDLE_IDENTIFIER project.yml`
- Logger subsystems/categories: `grep -rn 'Logger(subsystem' Fortiche ForticheWatch Shared FortichePack/Sources`
- Mirroring-sim verdict, HK error 300, lying `startMirroringToCompanionDevice`: `cat docs/SPIKE-M1.5.md`
- Snapshot echo / requestSnapshot / retry-with-backoff: `grep -n 'sendToPhone\|requestSnapshot\|startMirroringWithRetry' ForticheWatch/WatchWorkoutController.swift Fortiche/MirroringReceiver.swift`
- Stale-snapshot rejection + seq resume + journal path: `grep -n 'nextSeq\|lastAppliedSeq\|active-workout.json\|acknowledged' FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift`
- Phone mirror engine has no journal: `grep -n 'journalURL: nil' Fortiche/MirroringReceiver.swift`
- 3-minute discard: `grep -n 'minimumSaveDuration' FortichePack/Sources/FortichePack/Engine/WorkoutState.swift`
- Recovery call sites + engine==nil recheck: `grep -rn 'recoverIfNeeded\|engine == nil' Fortiche ForticheWatch | grep -i recover`
- Zero-sanitization in conversion: `grep -n 'treat as' FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift`
- Package tests green (totals live in fortiche-build-and-env / fortiche-validation-and-qa): `export DEVELOPER_DIR=/Applications/Xcode-beta.app && swift test --package-path FortichePack --skip IntelligentParserTests 2>&1 | tail -1`
- Dataset naming (873 entries, no "overhead press"): the python3 one-liner in symptom 5
- Icon script flag: `grep -n 'catalog' Scripts/generate_icon.swift | head -3`

Likely-to-drift (re-test on each Xcode beta): the paired-sim mirroring
failure (symptom 2 step 0), linkd's `appintents.sqlite3` schema (symptom 1
step 4), `log` default-level behavior (symptom 7), the flaky watch
auto-install (symptom 8), and Device Hub's location.
