# Contributing to Fortiche

Fortiche aims to be the ultimate open-source workout app: on-device-AI-native,
deeply integrated with iOS/watchOS, and private by architecture. Contributions
from humans and their AI agents are equally welcome — this repo is set up for
both.

## Ground rules (human or agent)

- **Read `CLAUDE.md` first** — build commands, simulator caveats, and the
  project's non-negotiables live there.
- **The skill library is the project's memory.** `.claude/skills/` contains
  runbooks, the failure archaeology, and the architecture contract. Loading
  the relevant skill before touching a subsystem is not optional politeness —
  it's how you avoid re-fighting battles that already cost days (Live
  Activity intent dispatch, simulator mirroring, CloudKit model rules…).
- **Everything is generated where possible**: the Xcode project comes from
  `project.yml` (XcodeGen), icons from `Scripts/generate_icon.swift`, the
  exercise dataset from `Scripts/import_exercises.py`, screenshots from the
  demo launch args. Never hand-edit generated artifacts.
- **Tests green before review**: `swift test --package-path FortichePack`,
  plus both platform builds.
- Weights are stored in kilograms, engine state mutates only through
  commands, SwiftData models stay CloudKit-compatible, and App Intents never
  live in a Swift package. The skills explain *why* — with the incidents that
  made each rule.

## Working with an AI agent on this repo

Point your agent at the repo root; `CLAUDE.md` and `.claude/skills/` will do
the heavy lifting. For substantial contributions, have the agent load
`fortiche-change-control` first.

### Regenerating or extending the skill library

The skill library was seeded by the project's original author-agent. If it
drifts from reality, or you want it rebuilt to a higher standard, hand your
agent the prompt in [`docs/SKILL_LIBRARY_PROMPT.md`](docs/SKILL_LIBRARY_PROMPT.md)
— it is written for exactly that task: discovery, parallel authoring,
adversarial review, and fixing, with the audience being mid-level engineers
and Sonnet-class models.

## Practical notes

- Requires Xcode 27 / the iOS 27 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- The paired-simulator HealthKit mirroring path does not work (Rapport link
  missing) — live-sync work needs real devices; a WatchConnectivity debug
  transport covers the simulator loop. See `docs/SPIKE-M1.5.md`.
- PRs: small and focused beats broad; include the evidence (test output,
  screenshots, log excerpts) that convinced you it works.
