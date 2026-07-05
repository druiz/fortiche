---
name: fortiche-diagnostics-and-tooling
description: >
  Measurement tools and interpretation guides for diagnosing Fortiche at
  runtime: tailing os_log on simulators without the --level info trap
  (applog.sh), the Live Activity / App Intents health check that inspects
  Metadata.appintents and linkd's appintents.sqlite3 (intent-doctor.sh),
  dual-simulator live-sync log capture for healthd/chronod/WatchConnectivity
  (mirror-trace.sh), plus assetutil, PlistBuddy, SDK header/swiftinterface
  grepping, and reading WC state from log lines. Load this when Live Activity
  buttons do nothing, logs look silent, watch-phone sync misbehaves, you need
  to verify what actually shipped inside a built .app, or you are about to
  claim "it works" without having measured it. These are the instruments the
  debugging playbook's checks invoke — load this alongside
  fortiche-debugging-playbook when you already know what to measure; start
  with the playbook when you only have a symptom.
---

# Fortiche diagnostics and tooling

**Rule zero: MEASURE, don't eyeball.** "The button does nothing" has at least
four distinct causes with four distinct log signatures. Every claim about
runtime behavior must be backed by a log line, a database row, or a file in
the built bundle. This skill gives you the instruments and tells you what
healthy vs. broken output looks like.

## When NOT to use this skill

- You want the *story* behind a failure signature (why intents left the
  package, why mirroring is sim-broken) → `fortiche-failure-archaeology`.
- You need symptom→hypothesis reasoning before you know what to measure →
  `fortiche-debugging-playbook`.
- You just need to build, or the build itself fails → `fortiche-build-and-env`.
- You need to launch the app, seed demo data, or drive it headlessly
  (`--demo-import`, `--skip-health`, …) → `fortiche-run-and-operate`.
- You are testing on real paired devices → `fortiche-device-sync-campaign`.
- Architecture invariants (engine, sync channels, SwiftData rules) →
  `fortiche-architecture-contract`.

## Prerequisites and jargon

Everything below assumes the Xcode 27 beta toolchain (as of 2026-07):

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
```

All three scripts export this themselves if you forget (they respect an
existing `DEVELOPER_DIR`).

| Term | Meaning |
|---|---|
| UDID | Simulator device identifier. Discover with `xcrun simctl list devices booted`. Never hardcode one. |
| appex | An app extension bundle (`ForticheWidgets.appex` under the app's `PlugIns/`). |
| `Metadata.appintents` | Directory the build emits inside each bundle; `extract.actionsdata` (JSON) lists every App Intent compiled into that binary. |
| linkd | The system daemon that indexes App Intents metadata into `appintents.sqlite3` per simulator device. If linkd didn't index it, the intent does not exist as far as the OS is concerned. |
| chronod | The daemon that renders Live Activities and dispatches their button intents. |
| healthd | HealthKit daemon; carries HKWorkoutSession mirroring over Rapport. |
| WC | WatchConnectivity. Fortiche's sim debug transport and its template/finished-workout channels. |
| Rapport | Apple's device-to-device link layer; absent between paired simulators (hence R2). |

Log subsystems in this repo (re-verify: `grep -rn 'Logger(subsystem' --include='*.swift' .`):
`com.davidruiz.fortiche` (iOS app + package code linked into it) and
`com.davidruiz.fortiche.watch` (watch app). Categories: `workout`,
`mirroring`, `intents`, `connectivity`, `demo`.

Scripts live in `.claude/skills/fortiche-diagnostics-and-tooling/scripts/`.
They take UDIDs as flags and auto-discover booted devices when possible. All
examples below assume this one-time setup (works from any cwd inside the
repo):

```sh
SCRIPTS="$(git rev-parse --show-toplevel)/.claude/skills/fortiche-diagnostics-and-tooling/scripts"
```

---

## 1. applog.sh — see the app's logs at all

**The trap this script exists for:** `Logger.info` lines are invisible unless
you pass `--level info` to `log stream` or `--info` to `log show`. Forgetting
the flag makes a perfectly chatty app look dead, and people then "fix" code
that was never broken. (Documented in `docs/SPIKE-M1.5.md`.)

```sh
"$SCRIPTS"/applog.sh                                   # stream app logs, booted sim
"$SCRIPTS"/applog.sh -m show -l 10m                    # dump last 10 minutes
"$SCRIPTS"/applog.sh -u <UDID>                         # required when >1 sim booted
"$SCRIPTS"/applog.sh -s com.davidruiz.fortiche.watch   # watch-side (pass watch UDID too)
"$SCRIPTS"/applog.sh -c connectivity                   # single Logger category
"$SCRIPTS"/applog.sh -s '' -P healthd -m show -l 5m    # filter by process instead
```

Flags: `-u` udid (default `booted`), `-s` subsystem (default
`com.davidruiz.fortiche`), `-c` category, `-P` process, `-m stream|show`,
`-l` window for show mode (default `5m`).

### Interpreting output

Healthy `show` output starts with a header and then timestamped lines:

```
# device=73D33331-… predicate: subsystem == "com.davidruiz.fortiche"
getpwuid_r did not find a match for uid 501        ← harmless simctl-spawn noise, ignore
Timestamp               Ty Process[PID:TID]
2026-07-05 18:23:06.381 I  Fortiche[…] [com.davidruiz.fortiche:workout] …
```

- **Header + zero lines** = the tool worked; the app genuinely logged nothing
  in that window (usually: app not running, or wrong device/subsystem). It is
  NOT a broken command.
- `-u booted` errors with "matches multiple devices" when several sims are
  booted — pass an explicit `-u <UDID>`.
- Raw equivalents, for when you need something custom:
  `xcrun simctl spawn <UDID> log stream --level info --predicate '…'` and
  `xcrun simctl spawn <UDID> log show --last 10m --info --predicate '…'`.

---

## 2. intent-doctor.sh — the Live Activity intent health check

Runs the full R1 chain-of-custody check for App Intents. Use it whenever Live
Activity buttons do nothing, after touching `project.yml`, intent files, or
anything under `Shared/`, and before claiming intents work.

```sh
"$SCRIPTS"/intent-doctor.sh                  # first booted iPhone sim, com.davidruiz.fortiche
"$SCRIPTS"/intent-doctor.sh -u <UDID>
"$SCRIPTS"/intent-doctor.sh -b <bundle-id>
```

What it checks, in order:

1. **App bundle metadata** — `Metadata.appintents/extract.actionsdata` (JSON)
   in the installed `.app` must list the three Live Activity intents
   (`CompleteSetIntent`, `PauseResumeIntent`, `SkipRestIntent`; source of
   truth `Shared/LiveActivityIntents.swift`) plus the Siri intents from
   `Fortiche/Intents/`.
2. **Widget appex metadata** — same check inside
   `PlugIns/ForticheWidgets.appex`; the LA intents must appear in BOTH
   binaries (that is the whole point of `Shared/` being compiled into both
   targets — see `fortiche-architecture-contract`).
3. **No `extract.packagedata`** — its presence means an `AppIntentsPackage` /
   package-hosted intent snuck back in; linkd fails it with EINVAL and then
   indexes NOTHING (hard rule R1).
4. **No debug-dylib stub** — `ENABLE_DEBUG_DYLIB` must stay `NO`
   (`project.yml` line ~30); the stub executable was the other EINVAL source
   in the R1 incident.
5. **linkd's index** — finds `appintents.sqlite3` under the device's
   `data/Containers/Data/System/*/index/`, then verifies: a
   `canonical_bundles` row for the bundle, `intent_metadata` rows for every
   LA intent, `effective_bundle_identifiers` rows covering BOTH
   `com.davidruiz.fortiche` and `com.davidruiz.fortiche.widgets`, and zero
   `audit_errors` rows mentioning the app.

### Healthy output (real run, 2026-07-05)

```
  PASS  app: extract.actionsdata present — actions: CompleteSetIntent LogSetIntent NextExerciseIntent PauseResumeIntent SkipRestIntent SkipRestSiriIntent StartForticheWorkoutIntent
  PASS  appex ForticheWidgets.appex: extract.actionsdata present — actions: CompleteSetIntent PauseResumeIntent SkipRestIntent
  PASS  no debug-dylib stub (ENABLE_DEBUG_DYLIB is NO)
  PASS  canonical bundle indexed (id=68)
  PASS  intents indexed: CompleteSetIntent LogSetIntent NextExerciseIntent PauseResumeIntent SkipRestIntent SkipRestSiriIntent StartForticheWorkoutIntent
  PASS  effective bundle identifiers cover the widget appex: com.davidruiz.fortiche com.davidruiz.fortiche.widgets
  PASS  no audit_errors rows reference this app
== verdict: HEALTHY — intents extracted, indexed, and mapped; Live Activity buttons should work ==
```

### Known-bad signatures (from the R1 incident)

| Where | Signature | Meaning |
|---|---|---|
| chronod log (phone) | `There is no metadata for CompleteSetIntent in com.davidruiz.fortiche` | linkd never indexed the intent; button taps dropped silently. |
| `audit_errors` table | `Failed to resolve package data … EINVAL` | linkd choked on `extract.packagedata` (package-hosted intents) or the debug-dylib stub executable, then indexed nothing for the bundle. |
| bundle contents | `extract.packagedata` exists | An intent moved back into FortichePack. Move it to the target (LA intents in `Shared/`, Siri intents in `Fortiche/Intents/`). |
| bundle contents | `Fortiche.debug.dylib` exists | `ENABLE_DEBUG_DYLIB` flipped back on. Set `NO` in `project.yml`, `xcodegen generate`, rebuild. |
| linkd DB | canonical bundle row exists but zero `intent_metadata` rows | The R1 end-state exactly. |

**If the app was just (re)installed and rows are missing:** launch the app
once and re-run — linkd indexes on install/launch, not instantly. If still
missing, the audit_errors dump in the script output is your answer. Full
incident narrative: `fortiche-failure-archaeology`.

---

## 3. mirror-trace.sh — dual-simulator live-sync capture

Captures healthd, chronod, WatchConnectivity, and Fortiche subsystems from
BOTH members of a booted simulator pair, then (in `show` mode) scans for the
known signatures and prints a verdict per signature.

```sh
"$SCRIPTS"/mirror-trace.sh                   # auto-discovers the booted+booted pair, last 5m
"$SCRIPTS"/mirror-trace.sh -l 15m            # bigger window
"$SCRIPTS"/mirror-trace.sh -m stream         # live tail, [phone]/[watch] prefixed, Ctrl-C to stop
"$SCRIPTS"/mirror-trace.sh -p <PHONE_UDID> -w <WATCH_UDID> -o /path/outdir
```

`show` mode writes full captures to `phone.log` / `watch.log` in the output
dir (defaults under `$TMPDIR`), so you can grep beyond the built-in scan.
Note: `log show` over both devices takes ~1–2 minutes; that's normal.

### Reading the signature scan

**Expected-bad on simulators (R2 — this is the documented state, not a regression):**

```
Error Domain=com.apple.healthkit Code=300 "Remote device is unreachable"
  ← RPErrorDomain Code=-6727 kNotFoundErr ('rapport:rdid:PairedCompanion' not found)
```

HK mirroring does not work between paired sims — no Rapport link, even when
`simctl list pairs` says `(active, connected)`. AND
`startMirroringToCompanionDevice()` resolves without error anyway, so never
treat the successful call as evidence. On the sim, live state must be flowing
over the **WC debug transport** instead; on real devices these same
signatures ARE a bug. See `docs/SPIKE-M1.5.md` and
`fortiche-device-sync-campaign`.

**Bad anywhere:**

| Signature | Meaning | Action |
|---|---|---|
| `shouldCancel: YES` (WC) | WC silently cancelled a send during a reachability blip (R4). Data was NOT delivered and no error surfaced to the app. | Verify both sides resync on `sessionReachabilityDidChange` (watch re-sends snapshot; phone requests one). Look for the resync lines right after. |
| `no metadata for …Intent` (chronod) | Live Activity intent unresolvable | Run `intent-doctor.sh`. |
| Phone shows no `com.davidruiz.fortiche` lines during an active watch workout | Phone peer engine isn't receiving; or phone app never launched in background | Check the mirroring handler was installed in `ForticheApp.init` (R3), then check WC lines. |

**Healthy live-sync window** shows: watch-side `com.davidruiz.fortiche.watch`
`workout`/`connectivity` lines as commands are submitted, phone-side
`com.davidruiz.fortiche` `mirroring`/`connectivity` lines as snapshots arrive,
and (on device) healthd mirroring traffic without Code=300. Background
healthd chatter (`data_collection`, `activitycache` lines) is normal noise —
ignore it.

### WC state from log lines

WatchConnectivity's own subsystem is `com.apple.watchconnectivity` (captured
by the script). What to look for:

- **Activation**: lines mentioning `activationDidComplete` / session state —
  remember the template catalog is buffered until WC activation
  (`ConnectivityHub`, category `connectivity`).
- **Reachability**: `sessionReachabilityDidChange` transitions bracket every
  blip; sends attempted inside a blip may show `shouldCancel: YES` (R4).
- **Queued transfers**: `transferUserInfo` items (finished workouts
  watch→phone) survive phone-dead and show delivery on reconnect; duplicates
  are expected and handled by UUID upsert (see
  `fortiche-architecture-contract`).

---

## 4. Manual instrument rack

### Inspecting a built app bundle

Find the installed bundle (never hardcode container paths — they change every
install):

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
APP=$(xcrun simctl get_app_container <UDID> com.davidruiz.fortiche app)
ls "$APP"                       # Fortiche, Assets.car, Metadata.appintents, PlugIns/, Watch/, …
```

The device's data root (for linkd DB hunting etc.) is discoverable, not
guessable: `xcrun simctl list devices -j` → the device's `"dataPath"` field.

### Compiled assets: assetutil

```sh
xcrun assetutil --info "$APP/Assets.car" | head -40   # JSON: catalog version, then one entry per asset
```

Use to verify icons/colors actually shipped after `swift
Scripts/generate_icon.swift --catalog` (generated artifacts are never
hand-edited — R8). Grep the JSON for `"Name"` to list asset names. Remember
SpringBoard caches icons across reinstalls — a stale icon on screen with a
correct `Assets.car` means respring or delete the app, not a build problem
(see `fortiche-run-and-operate`).

### Info.plist: PlistBuddy

```sh
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :NSSupportsLiveActivities" "$APP/Info.plist"   # → true
/usr/libexec/PlistBuddy -c "Print" "$APP/Info.plist" | less                      # whole thing
```

Binary plists are fine; PlistBuddy reads them natively (`plutil -p` also
works). Useful checks: `NSSupportsLiveActivities`, `WKCompanionAppBundleIdentifier`
in the embedded watch app (`$APP/Watch/ForticheWatch.app/Info.plist`),
`MinimumOSVersion`.

### SDK ground truth: headers and swiftinterface

When you need to know what an API *actually* declares on this beta (not what
memory says), grep the SDK. Two locations, and the split matters:

```sh
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)      # or watchsimulator / iphoneos
# ObjC-rooted API → Headers/*.h  (this is where HK mirroring lives):
grep -rl "workoutSessionMirroringStartHandler" "$SDK/System/Library/Frameworks/HealthKit.framework/Headers"
# Swift-only API → Modules/<F>.swiftmodule/<arch>.swiftinterface:
WSDK=$(xcrun --sdk watchsimulator --show-sdk-path)
grep -B3 "class SystemLanguageModel" \
  "$WSDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64-apple-watchos-simulator.swiftinterface"
```

That second grep is how R7 was established: the declaration is preceded by
`@available(watchOS, unavailable)` — no on-watch local model. If a symbol is
in neither Headers nor the swiftinterface for a platform, it does not exist
there, whatever the docs imply. (Availability semantics belong to
`fortiche-intelligence-reference`; this is just the measurement technique.)

### linkd's database by hand

`intent-doctor.sh` automates this, but for ad-hoc queries:

```sh
DB=$(find "$(xcrun simctl list devices -j | python3 -c '
import json,sys
u=sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"]==u: print(d["dataPath"])' <UDID>)/Containers/Data/System" -name appintents.sqlite3)
sqlite3 -readonly "$DB" "SELECT identifier FROM intent_metadata im JOIN canonical_bundles cb ON im.canonicalBundleId=cb.id WHERE cb.bundleIdentifier='com.davidruiz.fortiche';"
sqlite3 -readonly "$DB" "SELECT * FROM audit_errors WHERE issue LIKE '%fortiche%';"
```

Always `-readonly` — this is a live system database; never write to it.
Schema note (as of iOS 27 beta): `intent_metadata.identifier` is a generated
column extracted from a JSON `metadata` blob; other useful tables are
`effective_bundle_identifiers`, `appintent_sources`, `metadata_file_sources`
(maps each `extract.actionsdata` file to its source bundle).

### Intent metadata JSON by hand

`extract.actionsdata` is plain JSON (`jq` is available at `/usr/bin/jq`):

```sh
jq -r '.actions | keys[]' "$APP/Metadata.appintents/extract.actionsdata"
jq -r '.actions | keys[]' "$APP/PlugIns/ForticheWidgets.appex/Metadata.appintents/extract.actionsdata"
```

---

## Provenance and maintenance

Facts above were verified against the repo and live simulators on 2026-07-05
(Xcode 27 beta, iOS/watchOS 27.0 sims). Re-verification one-liners:

| Claim | Re-verify with |
|---|---|
| Subsystem/category names | `grep -rn 'Logger(subsystem' --include='*.swift' /Users/david/Code/Fortiche` |
| LA intent struct names | `grep -n 'struct .*Intent' Shared/LiveActivityIntents.swift Fortiche/Intents/WorkoutIntentsSiri.swift` |
| Bundle IDs, ENABLE_DEBUG_DYLIB | `grep -n 'PRODUCT_BUNDLE_IDENTIFIER\|ENABLE_DEBUG_DYLIB' project.yml` |
| `extract.actionsdata` is JSON with `.actions` dict | `jq '.actions|keys' "$APP/Metadata.appintents/extract.actionsdata"` |
| linkd DB location/schema | `find <dataPath>/Containers/Data/System -name appintents.sqlite3` then `sqlite3 -readonly <db> .schema` (schema may drift across betas) |
| `--level info` / `--info` traps | `docs/SPIKE-M1.5.md` (bottom bullets) |
| kNotFoundErr / Code=300 signatures | `docs/SPIKE-M1.5.md` (Verdict section) |
| Mirroring API in ObjC headers | `grep -rl workoutSessionMirroringStartHandler "$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/HealthKit.framework/Headers"` |
| SystemLanguageModel watchOS-unavailable | swiftinterface grep in §4 |
| Scripts still run | `"$SCRIPTS"/applog.sh -u <booted-udid> -m show -l 1m`; `"$SCRIPTS"/intent-doctor.sh`; `"$SCRIPTS"/mirror-trace.sh -l 2m` |

Volatile: the `audit_errors`/`intent_metadata` schema and the
`Containers/Data/System/*/index/` location are Apple-internal and may move in
any beta — if `intent-doctor.sh` can't find the DB, re-run the `find` above
and update the script, not just the doc. The `shouldCancel: YES` phrasing is
an observed log string (R4 incident), not API — treat grep misses as "not
observed", not "not happening".
