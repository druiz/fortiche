# M1.5 mirroring spike — findings (2026-07-05, Xcode 27 beta / iOS 27.0 24A5355p / watchOS 27.0 24R5289n)

Setup: paired simulators (iPhone 17 + Apple Watch Ultra 3, both 27.0), spike code in
`ForticheWatch/SpikeWorkoutController.swift` + `Fortiche/MirroringReceiver.swift`.

## Verdict

**HKWorkoutSession mirroring does NOT work between paired simulators on this beta.**
Watch-side `healthd` fails delivery with:

```
Error Domain=com.apple.healthkit Code=300 "Remote device is unreachable"
  ← RPErrorDomain Code=-6727 kNotFoundErr ('rapport:rdid:PairedCompanion' not found)
```

The mirroring transport is Rapport, and paired sims have no Rapport companion link,
even though `simctl list pairs` shows the pair as `(active, connected)`.

## Consequences for M3/M4

1. **Real devices required** to exercise the mirroring path (David has an iPhone 17 Pro Max
   + Watch Ultra 2 on 27.0 attached — needs `DEVELOPMENT_TEAM` in project.yml + HealthKit
   needs a paid/ADP profile). Simulators remain fine for everything else (UI, engine,
   HealthKit store, Live Activity rendering).
2. `startMirroringToCompanionDevice()` **resolves without error even when the companion is
   unreachable** — healthd enqueues the transaction and retries. The app-level snapshot/
   resync handshake in the M3 design is therefore mandatory; never assume the phone is
   attached because the call succeeded.
3. For the simulator dev loop, M3's transport abstraction gets a **WatchConnectivity debug
   transport** (WC messaging does work between paired sims) selected automatically when the
   mirrored channel never connects. Production transport stays `sendToRemoteWorkoutSession`.

## Also verified

- Watch side works end-to-end in sim: HK auth flow, `HKWorkoutSession` +
  `HKLiveWorkoutBuilder` start/end, state transitions, `startMirroringToCompanionDevice`
  accepted.
- iPhone HealthKit workout auth auto-grants in simulator (no sheet).
- Background launch of the iOS app via mirroring could not be observed (blocked by the
  Rapport failure) — re-verify on real devices.
- Xcode 27 replaces Simulator.app with **Device Hub** (`Contents/Applications/DeviceHub.app`).
- `log stream` needs `--level info` to capture `Logger.info`.
