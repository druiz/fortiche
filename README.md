<p align="center">
  <img src="Fortiche/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="Fortiche app icon">
</p>

# Fortiche

Hi, I'm David. I'm a software engineer that loves to workout. Like many, I'm
using AI to create my gym programs. I've used Anthropic Fable to build me the
perfect workout app that takes in a Gemini/Claude/ChatGPT workout plan in full
text and generate a workout program to track reps/sets/weights. I'm very
pleased with the results. The app is extensively using iOS 27 APIs so will be
available (for free) in September upon the new OS releases.

A strength-training app for iPhone and Apple Watch, built exclusively on the
iOS 27 / watchOS 27 SDKs. Paste any workout program as plain text and on-device
Apple Intelligence turns it into a structured, trackable plan.

> "Fortiche" is French slang for someone who's really good at something.

<p align="center">
  <img src="AppStore/screenshots/iphone-6.9/01-programs.png" width="215" alt="Programs list with the next training day highlighted">
  <img src="AppStore/screenshots/iphone-6.9/02-live-workout.png" width="215" alt="Live workout with one-tap set logging and last-time ghost">
  <img src="AppStore/screenshots/iphone-6.9/03-history.png" width="215" alt="History with weekly volume chart and personal records">
  <img src="AppStore/screenshots/iphone-6.9/04-settings.png" width="215" alt="Settings with selectable app icons and plate calculator">
</p>
<p align="center">
  <img src="AppStore/screenshots/watch/01-days.png" width="180" alt="Apple Watch day list with next-up suggestion">
  &nbsp;&nbsp;
  <img src="AppStore/screenshots/watch/02-live-set.png" width="180" alt="Apple Watch live set card">
</p>

## Features

- **Text → program**: paste a program in any reasonable format ("Bench 3x5 @ 80kg",
  rep ranges, AMRAP, %1RM, RPE, rest times). Parsed on-device with the
  FoundationModels framework — nothing leaves the phone. A deterministic parser
  covers devices without Apple Intelligence.
- **Live workouts on either device**: full iPhone-only mode, or a watch-run
  session with heart rate. During watch workouts the phone shows a live,
  editable mirror — change weight/reps/sets from whichever device is closer.
- **Quick workouts** ⚡: crunches in front of the TV count too. Two steps —
  pick an exercise (recents first), confirm sets × reps — and you're in a
  real live session with rest timer and Live Activity, no program needed.
  Short sessions with logged sets always save. Or just tell Siri:
  "Start 3 sets of 20 crunches in Fortiche."
- **Built for sweaty hands**: one giant action per screen, Digital Crown weight
  adjustment, Double Tap to complete a set, no fiddly gestures.
- **Rest timer** with watch haptics, phone notifications, and a Live Activity
  countdown in the Dynamic Island.
- **Live Activity** with interactive Done Set / Skip Rest / Pause buttons.
- **Apple Health**: workouts save with one `HKWorkoutActivity` per exercise;
  they count toward your rings.
- **Siri / App Intents**: "Start my push day", "Log 8 reps at 80 kilos",
  "Skip my rest" — hands-free while lifting.
- **History**: personal records (estimated 1RM), weekly volume chart,
  last-session ghost while lifting, plate calculator, kg/lb.

## Architecture

| Piece | Role |
|---|---|
| `FortichePack/` | Shared SwiftPM package: SwiftData models, the workout engine, parsing, sync protocol, stats, App Intents |
| `Fortiche/` | iOS app |
| `ForticheWatch/` | watchOS app |
| `ForticheWidgets/` | Live Activity + widgets |

Key design decisions:

- **Command-sourced workout engine** (`ActiveWorkoutEngine`): every mutation is
  a sequence-numbered command. The watch is authoritative during watch
  sessions; the phone applies edits optimistically and reconciles against
  echoed snapshots. State journals to disk on every command, so a crash
  restores mid-set.
- **Transports**: live sync rides `HKWorkoutSession` mirroring on real
  devices, with a WatchConnectivity fallback for simulators (mirroring's
  Rapport link doesn't exist between paired simulators — see
  `docs/SPIKE-M1.5.md`). Templates push phone → watch via
  `applicationContext`; finished workouts return dual-channel and upsert by
  UUID.
- **Weights are always stored in kilograms**; `WeightUnit` converts only at
  display/input boundaries.
- **CloudKit-ready SwiftData models**: optional/defaulted properties, no
  unique constraints, explicit order fields.

## Building

Requires Xcode 27 (the project targets the iOS 27 / watchOS 27 SDKs) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate       # regenerate Fortiche.xcodeproj after editing project.yml
open Fortiche.xcodeproj
```

Tests live in the package:

```sh
swift test --package-path FortichePack
```

Set `DEVELOPMENT_TEAM` in `project.yml` for device builds. See `CLAUDE.md`
for CLI build commands and simulator caveats.

## Contributing — humans and agents welcome

This repo is deliberately structured so that AI coding agents can contribute
at full quality. If you're pointing an agent (Claude Code or similar) at it:

1. **Start at the repo root.** `CLAUDE.md` carries the build commands,
   simulator caveats, and the hard rules; agents that respect it avoid the
   expensive mistakes.
2. **Load the skill library.** `.claude/skills/` contains the project's
   institutional memory: a debugging playbook, the failure archaeology
   (every trap that cost real time, with the evidence that settled it), the
   architecture contract, diagnostic scripts, and a decision-gated campaign
   for the hardest open problem (real-device live-sync verification). Have
   your agent load `fortiche-change-control` before making any change, and
   the relevant sibling skill before touching a subsystem.
3. **Prove it, don't eyeball it.** Tests green
   (`swift test --package-path FortichePack`), both platforms building, and
   PRs that include the evidence — test output, screenshots, log lines. UI
   claims need screenshots; sync claims need logs; and nothing about
   watch↔phone mirroring may be claimed from simulator runs (it can't work
   there — see `docs/SPIKE-M1.5.md`).
4. **Don't hand-edit generated artifacts.** The Xcode project comes from
   `project.yml` (`xcodegen generate`), icons from
   `Scripts/generate_icon.swift`, the exercise dataset from
   `Scripts/import_exercises.py`.

Humans: same rules, fewer tokens. Full details in
[CONTRIBUTING.md](CONTRIBUTING.md). If the skill library ever drifts from
reality, regenerate it by handing your agent
[docs/SKILL_LIBRARY_PROMPT.md](docs/SKILL_LIBRARY_PROMPT.md).

## Acknowledgements

Exercise data from [free-exercise-db](https://github.com/yuhonas/free-exercise-db)
(public domain), originally derived from exercises.json by Ollie Jennings.
