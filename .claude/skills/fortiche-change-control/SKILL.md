---
name: fortiche-change-control
description: >
  How changes are made to Fortiche: the eight non-negotiable rules (App Intents
  placement, simulator mirroring limits, mirroring handler timing, WC resync,
  recovery races, LLM zero-sentinels, watchOS model availability, generated
  artifacts), the pre-review checklist (tests, both platform builds, xcodegen),
  change risk classification, commit-message conventions, PR evidence
  expectations, and the doc-comment house style. Load this BEFORE writing any
  code, editing project.yml, moving files between targets, touching the
  engine/sync layer, committing, or opening a PR. Also load it when reviewing
  someone else's change or when unsure whether an edit needs regeneration
  instead of hand-editing.
---

# Fortiche change control

This is the process skill: what you must do (and must never do) when changing
this repo. It exists because several of the rules below each cost days to
learn the hard way. `CONTRIBUTING.md` says it plainly: loading the relevant
skill before touching a subsystem "is not optional politeness".

Repo root in this document means the directory containing `project.yml` and
`CLAUDE.md`. All commands below run from the repo root.

## When NOT to use this skill

- **Diagnosing a bug or reading logs** → `fortiche-debugging-playbook`.
- **Full forensic detail on a past incident** (log excerpts, exact failure
  chains) → `fortiche-failure-archaeology`. This skill only summarizes each
  incident enough to justify its rule.
- **Why the architecture is shaped this way** (command sourcing, authority
  model, sync channels) → `fortiche-architecture-contract`.
- **Setting up the toolchain, SDKs, XcodeGen** → `fortiche-build-and-env`.
- **Launching the app, simulators, demo launch args** → `fortiche-run-and-operate`.
- **Log/simulator tooling gotchas** → `fortiche-diagnostics-and-tooling`.
- **Manual QA passes and acceptance checks** → `fortiche-validation-and-qa`.
- **The paired-device live-sync test procedure** → `fortiche-device-sync-campaign`.
- **Shipping to TestFlight / App Store** → `fortiche-appstore-and-release`.
- **Training-domain questions** (sets, 1RM, plates) → `strength-domain-reference`.
- **FoundationModels / parsing internals** → `fortiche-intelligence-reference`.
- **Speculative/unproven ideas** → `fortiche-research-frontier`.

## The non-negotiable rules (R1–R8)

Each rule has a real incident behind it. Never contradict one; when your
change brushes against one, say so in the PR and explain how you complied.
Full incident forensics live in `fortiche-failure-archaeology`.

| # | Rule (short form) | Blast radius if violated |
|---|---|---|
| R1 | App Intents never in a Swift package; `ENABLE_DEBUG_DYLIB: NO` | Live Activity buttons silently do nothing |
| R2 | Never trust paired-simulator HKWorkoutSession mirroring | False confidence; live sync "works" but doesn't |
| R3 | Mirroring handler installed synchronously in `ForticheApp.init`; Live Activity requested inside its ~10s window | Background-launched watch sessions dropped; no Live Activity |
| R4 | Resync both sides on `sessionReachabilityDidChange` | State divergence after WC reachability blips |
| R5 | Re-check `engine == nil` in workout-recovery completions; restore seq counter from `lastAppliedSeq` | Duplicate engines; engine dedupes its own commands |
| R6 | Sanitize LLM zero-sentinels; dataset says "shoulder press", never "overhead press" | Imported templates with bogus 0 kg / 0 s values; failed exercise matches |
| R7 | No on-watch local language model on watchOS 27 | Code that cannot compile or silently unavailable features |
| R8 | Regenerate generated artifacts; never hand-edit | Divergence that the next regeneration silently reverts |

### R1 — App Intents never live in a Swift package; `ENABLE_DEBUG_DYLIB` stays NO

**Incident.** Live Activity buttons did nothing, on device *and* simulator,
with no error anywhere in the app. `chronod` logged "There is no metadata for
CompleteSetIntent in com.davidruiz.fortiche"; `linkd`'s appintents metadata
database showed "Failed to resolve package data ... EINVAL" for (a) the
debug-dylib stub main executable and (b) the `extract.packagedata` entries
that `AppIntentsPackage` registrations emit for statically linked packages —
after which linkd indexed *nothing* for the bundle.

**Rule in practice.**
- Siri intents live in `Fortiche/Intents/` (app target).
- Live Activity button intents live in `Shared/LiveActivityIntents.swift`,
  which is compiled into BOTH the app and widget targets (see
  `sources: [Fortiche, Shared]` and `sources: [ForticheWidgets, Shared]` in
  `project.yml`). Each binary gets its own registered copy of the type.
- The package (`FortichePack`) may hold only the *bridge* the intents call
  (`FortichePack/Sources/FortichePack/LiveActivity/WorkoutIntents.swift`,
  `WorkoutIntentBridge`) — never an `AppIntent` conformance.
- `ENABLE_DEBUG_DYLIB: NO` is set in `project.yml` (line ~30). Do not flip it
  back to YES "to speed up debugging".
- `AppShortcutsProvider` must be in the app target (Apple requirement).

Verify before merging any intent-related change:

```sh
grep -rn "AppIntent" FortichePack/Sources | grep -v Bridge   # should print nothing
grep -n "ENABLE_DEBUG_DYLIB" project.yml                      # must say NO
```

### R2 — Paired-simulator mirroring does not work, and the API lies about it

`HKWorkoutSession` mirroring between paired simulators fails: the watch's
`healthd` cannot find the Rapport companion link (kNotFoundErr
`rapport:rdid:PairedCompanion`) and surfaces HK error 300 "Remote device is
unreachable". Worse, `startMirroringToCompanionDevice()` **resolves without
error anyway** — a successful call proves nothing. That is why the app-level
`requestSnapshot`/snapshot handshake exists and is mandatory: it is the only
proof the channel is alive. Production live-sync changes need real devices;
the WatchConnectivity (WC) `sendMessage` debug transport covers the simulator
loop. Details: `docs/SPIKE-M1.5.md` and `fortiche-device-sync-campaign`.

### R3 — Install the mirroring handler synchronously; request the Live Activity in its window

When the watch starts a workout, iOS may launch the phone app in the
*background* and deliver the mirrored session immediately.
`workoutSessionMirroringStartHandler` must therefore be installed
synchronously in `ForticheApp.init` — lazy installation (e.g. in a view's
`.task`) drops the session. The Live Activity must be requested inside that
handler's ~10-second window, with placeholder content if real state hasn't
arrived yet.

### R4 — WC sends during reachability blips are silently cancelled

Observed in logs as `shouldCancel: YES` with no error surfaced to the sender.
Any change to the sync layer must preserve the recovery behavior: on
`sessionReachabilityDidChange`, the watch re-sends a snapshot and the phone
requests one. Never assume a WC send that didn't throw actually arrived.

### R5 — Recovery races: re-check engine, restore the sequence counter

Two separate incidents, one rule pair:
- `HKHealthStore.recoverActiveWorkoutSession`'s completion can fire AFTER the
  user already started a new workout. Re-check `engine == nil` *inside* the
  completion, or you adopt a duplicate engine (happened once).
- A recovered engine must resume its per-origin sequence counter from
  `state.lastAppliedSeq` — a fresh counter re-issues already-seen sequence
  numbers and the dedup logic silently drops the engine's own commands
  (also happened once). See the `nextSeq` initialization in
  `FortichePack/Sources/FortichePack/Engine/ActiveWorkoutEngine.swift`.

### R6 — LLM zero-sentinels and dataset naming

The on-device model emits `0` for "not specified" (rest seconds, weight,
percent). Zero means bodyweight/unset and must be sanitized at conversion —
never persist a literal 0 kg prescription because the model didn't say.
The exercise dataset (free-exercise-db, 873 entries, public domain) uses
"shoulder press"/"military press" and never "overhead press"; matching relies
on the alias table (OHP → shoulder press). Details:
`fortiche-intelligence-reference`.

### R7 — No on-watch local model

watchOS 27 has `LanguageModelSession`, but `SystemLanguageModel` and
`@Generable` are `@available(watchOS, unavailable)`. On-watch parsing is
cloud-backed only, and that path is untested (as of 2026-07). Do not add code
that assumes a local model on the watch; guard with availability and platform
conditions as the existing parsing code does.

### R8 — Generated artifacts are never hand-edited

If you hand-edit a generated file, the next regeneration silently destroys
your edit — or worse, your edit and the generator drift apart forever.

| Artifact | Source of truth | Regenerate with |
|---|---|---|
| `Fortiche.xcodeproj` | `project.yml` | `xcodegen generate` (project file is git-ignored) |
| App icons / colorways | `Scripts/generate_icon.swift` | `swift Scripts/generate_icon.swift --catalog` |
| Bundled exercise dataset | `ThirdParty/free-exercise-db/` | `python3 Scripts/import_exercises.py` |
| App Store screenshots | demo launch args (`--demo-import`, `--demo-history`, `--demo-workout`, `--tab`) | see `fortiche-appstore-and-release` |

## Classifying your change

Decide the tier first; it sets the evidence bar.

| Tier | What falls in it | Required before review |
|---|---|---|
| **High risk** | Anything under `FortichePack/Sources/FortichePack/Engine/` or `Sync/`, command/snapshot schemas, journal/recovery paths, WC/HK transport code, `Shared/` intents | Unit tests covering the new behavior in `FortichePack/Tests/`; full checklist below; a two-device simulator check of the live-sync loop over the WC debug transport (procedure: `fortiche-device-sync-campaign`); note in the PR whether real-device verification is still owed (R2) |
| **Medium risk** | UI (SwiftUI views in `Fortiche/`, `ForticheWatch/`, `ForticheWidgets/`), models, parsing, stats | Full checklist below; screenshots or a described manual pass for visible changes |
| **Low risk** | `docs/`, `Scripts/` (non-generator behavior), comments, metadata in `AppStore/` | Tests + builds still run if any target source was touched at all; otherwise a careful read is enough |

Two escalators regardless of directory:
- Editing `project.yml` is at least medium risk (it shapes every target) and
  always requires `xcodegen generate` + both platform builds.
- Any change that adds/moves a file between targets can trip R1 — check where
  intents end up.

## Pre-review checklist

Everything must pass before you ask for review (`CONTRIBUTING.md`: "Tests
green before review"). Xcode 27 beta is required and is not the selected
toolchain, so export `DEVELOPER_DIR` first (details: `fortiche-build-and-env`).

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app

# 1. If you touched project.yml (or added/moved/deleted target source files):
xcodegen generate

# 2. Unit tests — 64 tests in 14 suites as of 2026-07, all must pass.
#    Runs on the macOS host; no simulator needed.
swift test --package-path FortichePack

# 3. Both platform builds:
xcodebuild -project Fortiche.xcodeproj -scheme Fortiche \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Fortiche.xcodeproj -scheme ForticheWatch \
  -destination 'generic/platform=watchOS Simulator' build
```

Checklist form:

- [ ] Tier classified; high-risk extras done (unit tests, two-sim check)
- [ ] `xcodegen generate` run if `project.yml` or target file layout changed
- [ ] `swift test --package-path FortichePack` green
- [ ] iOS build green, watchOS build green
- [ ] No generated artifact hand-edited (R8)
- [ ] No `AppIntent` conformance in `FortichePack`; `ENABLE_DEBUG_DYLIB` still NO (R1)
- [ ] New logic lives in `FortichePack` where possible — app-target dirs are
      for target-only sources (`CLAUDE.md` layout rule)
- [ ] Evidence collected for the PR (next section)

## Commit messages

Conventions as visible in `git log` (verify with `git log --oneline`):

- Subject: `type: summary`, lower-case type, no trailing period. Types in use:
  `feat:`, `fix:`, `docs:`. Early history used milestone prefixes (`M1:` …
  `M5:`) — do not resurrect those; milestones are done.
- The summary often uses an em-dash subtitle for the headline + gist shape,
  e.g. `feat: app icon — indigo dumbbell, generated with CoreGraphics`.
- Body: wrapped bullet list of concrete changes; name files/scripts/flags;
  state what was *verified*, not just what was edited (e.g. "Verified
  end-to-end in the simulator: picker renders, switching to Ember updates
  the home-screen icon").
- Agent-authored commits carry the trailer
  `Co-Authored-By: <agent name> <noreply@anthropic.com>`.
- One logical change per commit; a fix whose root cause was hunted down says
  so (`fix: make Live Activity buttons actually dispatch — root cause found`).

## PR evidence expectations

From `CONTRIBUTING.md`: **small and focused beats broad; include the evidence
that convinced you it works.** Concretely, per tier:

- **High risk**: test output (the `swift test` summary line), relevant log
  excerpts from the two-device check (see `fortiche-diagnostics-and-tooling`
  for the `log show --info` / `log stream --level info` gotchas), and an
  explicit statement of what remains simulator-only vs. real-device-verified
  (R2 makes this distinction mandatory for live-sync paths).
- **Medium risk**: build/test summary plus screenshots for anything visible.
- **Low risk**: a sentence on what you checked.

Never claim device verification you didn't do. Simulator evidence is fine —
labeled as such.

## Docs and comments house style

This applies to doc comments, `// NOTE:` blocks, and the markdown docs.

1. **Explain purpose, constraints, and why — never restate the code.**
   `/// Called after every state mutation.` earns its line;
   `/// Sets the state` does not.
2. **When a line of code guards against a past incident, say so at the site.**
   The repo does this deliberately, e.g. in `ActiveWorkoutEngine.init`:
   `// Resume the sequence counter after recovery — a fresh counter would
   collide with the restored lastAppliedSeq and dedupe local commands.`
   A future refactorer must not be able to "simplify" the guard away without
   tripping over the reason it exists.
3. **Cross-file rules get a `// NOTE:` at the surprising location.** Example:
   the package-side `WorkoutIntents.swift` opens with a NOTE explaining that
   the actual intents live in `Shared/` and why (R1). If your file layout is
   the least obvious part of your change, document the layout where a reader
   will look first.
4. **Density: sparse and load-bearing.** Public types and every non-obvious
   public member get a `///`; private helpers usually get nothing unless
   there is a why. As a reference point, `ActiveWorkoutEngine.swift` (the
   most rule-laden file) carries ~30 `///` lines; plain model files carry
   ~10. Do not blanket-comment.
5. **Markdown docs**: imperative runbook voice, copy-pasteable commands,
   date-stamp volatile facts ("as of 2026-07"), and never present unproven
   things as proven — candidates stay labeled candidates.
6. Doc comments compile into both platforms — keep platform-specific claims
   inside the relevant `#if` regions or phrase them per-platform.

## Provenance and maintenance

Facts verified against the repo on 2026-07-05. One-line re-verification for
each claim that can drift:

```sh
# Test count / green status (CLAUDE.md's count may lag; this is the truth):
export DEVELOPER_DIR=/Applications/Xcode-beta.app && swift test --package-path FortichePack 2>&1 | tail -1

# R1 invariants:
grep -n "ENABLE_DEBUG_DYLIB" project.yml
grep -rn "AppIntent" FortichePack/Sources | grep -v Bridge

# Shared/ compiled into app + widget:
grep -n "sources:" project.yml

# Intent file locations:
ls Fortiche/Intents Shared FortichePack/Sources/FortichePack/LiveActivity

# Commit conventions:
git log --oneline -15 && git log -1 --format=%B

# PR evidence + ground rules:
sed -n '1,60p' CONTRIBUTING.md

# Generators still exist:
ls Scripts/generate_icon.swift Scripts/import_exercises.py Scripts/release.sh
```

If any of these disagree with this skill, the repo wins — update this file.
