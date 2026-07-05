---
name: fortiche-intelligence-reference
description: >
  FoundationModels (Apple Intelligence) as used in Fortiche. Load when touching
  template-import parsing, @Generable/@Guide schemas, guided generation,
  LanguageModelSession, SystemLanguageModel availability handling, the heuristic
  parser fallback, on-device context limits, temperature/GenerationOptions,
  FoundationModels test gating, watchOS FoundationModels availability, or when
  evaluating unadopted iOS 27 APIs (PrivateCloudComputeLanguageModel, image
  Attachments, ToolCallingMode). Also load to learn how to inspect SDK
  swiftinterface files for platform-availability ground truth.
---

# Fortiche Intelligence Reference

How Fortiche uses Apple's FoundationModels framework (the on-device LLM behind
Apple Intelligence) to parse pasted strength-training programs into structured
templates — and how to verify what the framework actually supports on each
platform.

Jargon used once and defined here:

- **FoundationModels** — Apple's framework (iOS 26+/macOS 26+) exposing the
  on-device language model (`SystemLanguageModel`) and, in iOS 27, a
  cloud-backed model (`PrivateCloudComputeLanguageModel`).
- **Guided generation** — constrained decoding: you declare a Swift type with
  the `@Generable` macro, the framework injects that type's schema into the
  prompt and guarantees the response parses into the type.
- **`@Guide`** — per-property macro that attaches a natural-language description
  (and optional constraints) steering what the model puts in that property.
- **Heuristic parser** — Fortiche's deterministic regex line parser; always
  available, no model needed.

## When NOT to use this skill

- Build commands, SDK setup, `DEVELOPER_DIR`, XcodeGen → **fortiche-build-and-env**.
- Exercise-name matching semantics, alias table, the free-exercise-db dataset
  ("shoulder press" vs "overhead press") → **strength-domain-reference**.
- General test-suite policy and QA gates → **fortiche-validation-and-qa**.
- Adopting the unadopted iOS 27 APIs listed at the bottom (PCC, attachments,
  tool calling) → that is new-feature work: **fortiche-research-frontier** for
  the open questions, **fortiche-change-control** before changing anything.
- Live Activity / App Intents rules, watch↔phone sync → **fortiche-architecture-contract**
  and **fortiche-device-sync-campaign**.
- Debugging a running app (log commands, simulator quirks) → **fortiche-debugging-playbook**
  and **fortiche-diagnostics-and-tooling**.

## File map (all verified 2026-07)

| Path | What lives there |
|---|---|
| `FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift` | `ProgramParsing` protocol, `ParserAvailability`, `HeuristicProgramParser`, `IntelligentProgramParser`, the `@Generable` schema (`GeneratedDay`/`GeneratedExercise`/`GeneratedSetGroup`/`GeneratedWeightUnit`), zero-sanitizing conversion to `ParsedDay` |
| `FortichePack/Sources/FortichePack/Parsing/ProgramSegmenter.swift` | Pass 1: deterministic day segmentation (`segment(_:)`, `isDayHeader(_:)`) |
| `FortichePack/Sources/FortichePack/Parsing/HeuristicLineParser.swift` | Regex line parser (fallback + reference implementation) |
| `FortichePack/Sources/FortichePack/Parsing/ParsedProgram.swift` | Parse-result value types |
| `FortichePack/Sources/FortichePack/Parsing/ProgramNamer.swift` | Auto-names a program from its parsed days |
| `FortichePack/Tests/FortichePackTests/IntelligentParserTests.swift` | Availability-gated integration tests against the real model |
| `Fortiche/TemplateImport/TemplateImportModel.swift` | Parser selection + paste→parse→review→save flow |
| `Fortiche/TemplateImport/TemplateImportView.swift` | `availabilityFooter` user messaging per availability state |
| `Fortiche/RootView.swift` (`runDemoImportIfRequested`) | `--demo-import` seeds Push/Pull/Legs through the real parser path |

## Pipeline: two-pass parse

```
raw text ──pass 1──> [DayChunk]  ──pass 2 (one model request per chunk)──> [ParsedDay]
          ProgramSegmenter        IntelligentProgramParser.parseDay          │
          (deterministic regex,   fresh LanguageModelSession per day,        └─> canonicalized()
           no model involved)     @Generable GeneratedDay, temperature 0         fuzzy library match
                                  │ on ANY error for that day
                                  └──> HeuristicLineParser for that chunk only
```

Why two passes instead of one big generation request:

1. **Context budget.** The on-device model's context is small — the schema is
   injected into the prompt on top of instructions and program text (see
   "Context budget" below). A multi-week program in one request blows the
   window; one day per request stays comfortably inside it.
2. **Failure isolation.** A guardrail refusal, context overflow, or malformed
   generation costs only that day: `IntelligentProgramParser.parse` catches any
   error from `parseDay` and substitutes `HeuristicLineParser.parse(chunk:defaultUnit:)`
   for that chunk, setting `usedFallback = true` (surfaced in
   `TemplateReviewView`). The catch is intentionally a catch-all `catch` — do
   not narrow it to specific `GenerationError` cases (which are deprecated in
   iOS 27 anyway, replaced by `LanguageModelError.contextSizeExceeded` /
   `.rateLimited` / `.guardrailViolation`).
3. **Progressive UI.** Each finished day streams out through the `onDay`
   closure; `TemplateImportModel` appends it to `parsedDays` so the review UI
   fills in day by day.

Pass 1 (`ProgramSegmenter.segment`) is pure regex/heuristics: markdown headers,
"Day N"/"Week N" (English + French), weekday names, short colon-terminated
lines. Lines containing set notation (`3x8`, `@`) are never headers. Bodyless
chunks and a set-notation-free leading preamble are dropped. It is fully unit
tested (`SegmenterTests`) and shared by both parsers, so intelligent and
heuristic output have identical day boundaries.

A **fresh `LanguageModelSession` per day** is deliberate: sessions accumulate
transcript, so reusing one across days would grow context linearly and couple
failures across days.

## The @Generable schema — and why set GROUPS

The schema in `TemplateParser.swift`:

- `GeneratedDay { name, exercises: [GeneratedExercise] }`
- `GeneratedExercise { name, setGroups: [GeneratedSetGroup], restSeconds: Int? }`
- `GeneratedSetGroup { setCount, reps, repsUpper, weight: Double?, unit: GeneratedWeightUnit?, rpe: Double? }`
- `GeneratedWeightUnit { kilograms | pounds | percentOfMax }`

**Set groups, not per-set arrays.** The schema models "3x8 @ 100kg" as ONE
group with `setCount: 3`, not three array elements. Asking the small on-device
model to expand "3x8" into three identical array entries was unreliable (wrong
counts, drifting values between entries). Counting is hard for a ~3B-class
model; copying a count into an integer field is not. Expansion to individual
`ParsedSet`s happens deterministically in Swift
(`ParsedDay.init(generated:fallbackName:)`), with `setCount` clamped to 1...30.
Groups still express varied schemes: "5/3/1" = three groups with `setCount: 1`.
The `@Guide` description on `setGroups` teaches exactly this — keep the guide
text and the schema shape in sync if you ever touch either.

**Temperature 0.** `parseDay` passes `GenerationOptions(temperature: 0)`.
Parsing is extraction, not creativity: greedy decoding makes runs repeatable
and makes the integration tests meaningful.

**Zero-means-unset sanitation** (incident-backed, see R6 in
**fortiche-change-control**, where the numbered hard rules R1–R8 live): the
model emits `0` for "not specified" despite optional fields. The
conversion layer treats `restSeconds <= 0`, `weight <= 0`, `percent <= 0` as
nil (bodyweight/unset). Never remove this sanitation; add the same treatment to
any new numeric field.

**Deep nesting degrades guided generation.** The schema is intentionally three
levels (day → exercise → set group). If you extend it, prefer flat fields over
another nesting level, and re-run the integration tests on a real device, not
just the Mac.

## Context budget

- The schema of the `@Generable` type is injected into the prompt — visible in
  the SDK signatures as `includeSchemaInPrompt: Bool = true` on
  `respond`/`streamResponse`. Budget = instructions + schema + day text +
  response, all inside one window.
- Measured on the host Mac (2026-07, macOS 27 beta):
  `SystemLanguageModel.default.contextSize` returned **4096** tokens. Treat
  "~4-8K depending on OS/model revision" as the planning envelope; check at
  runtime, never hardcode:

```swift
import FoundationModels
let m = SystemLanguageModel.default
print(m.availability, m.contextSize)   // runnable as a script on the Mac: swift ctx.swift
```

- There are also `tokenCount(for:)` async APIs on `SystemLanguageModel`
  (prompt, instructions, tools, schema, transcript entries) if you need to
  budget precisely.

## Availability handling

`IntelligentProgramParser.availability` maps SDK availability to the app's
`ParserAvailability`:

| `SystemLanguageModel.default.availability` | `ParserAvailability` | Meaning / UI |
|---|---|---|
| `.available` | `.available` | Use `IntelligentProgramParser` |
| `.unavailable(.modelNotReady)` | `.downloading` | Transient — model assets still downloading. UI footer: "using the basic parser until it's ready" |
| `.unavailable(.deviceNotEligible)` | `.unavailable(reason:)` | Hardware can't run Apple Intelligence — heuristic only |
| `.unavailable(.appleIntelligenceNotEnabled)` | `.unavailable(reason:)` | Off in Settings — heuristic only |
| `.unavailable(other)` | `.unavailable(reason:)` | Future-proof catch: new reasons degrade gracefully |

Selection is a plain ternary at both call sites (`TemplateImportModel.parse()`
and `RootView.runDemoImportIfRequested()`):

```swift
let parser: any ProgramParsing = availability == .available
    ? IntelligentProgramParser()
    : HeuristicProgramParser()
```

Anything other than `.available` (including `.downloading`) uses the heuristic
parser — a download can take a long time and the user pasted text NOW.
`HeuristicProgramParser` also implements `ProgramParsing`, so downstream code
(canonicalization, naming, review UI) is identical either way; only
`usedFallback` differs.

Simulator note: the iOS simulator inherits the host Mac's Apple Intelligence —
if the Mac has it enabled and downloaded, `--demo-import` in the sim exercises
the real model path.

## Testing strategy

- **Model-agnostic seam:** everything after parsing consumes `ProgramParsing` /
  `ParsedProgram`. Unit tests for segmentation (`SegmenterTests`), line parsing
  (`HeuristicLineParserTests`), end-to-end heuristic flow
  (`HeuristicProgramParserTests`) run everywhere, deterministic, no model.
- **Integration tests against the real model** live in
  `IntelligentParserTests.swift`, gated at the suite level:

```swift
@Suite(.enabled(if: IntelligentProgramParser.availability == .available))
```

  They run wherever Apple Intelligence is actually available — in practice the
  host Mac, since **macOS has FoundationModels** (the package tests run on the
  Mac; verify with the commands below). On CI or Macs without Apple
  Intelligence they are skipped, not failed. Each test carries
  `.timeLimit(.minutes(3))` because first-token latency after a cold start is
  real.
- Assertions are tolerance-aware where the model has latitude (name checked via
  `.contains`, weight conversion via `abs(kg - expected) < 0.5`) and exact
  where guided generation guarantees structure (set counts, reps).

Run them:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app
swift test --package-path FortichePack                                   # whole suite
swift test --package-path FortichePack --filter IntelligentParserTests   # model tests only
swift test --package-path FortichePack --list-tests | grep Intelligent   # confirm they're compiled in
```

If `IntelligentParserTests` silently pass in 0s, availability was not
`.available` and the suite was skipped — check
`SystemLanguageModel.default.availability` with the script snippet above
before concluding the tests are green.

## Platform truth table (verified 2026-07 against Xcode 27 beta SDKs on disk)

| Symbol | iOS 27 | watchOS 27 device slice | watchOS 27 simulator slice | macOS 27 |
|---|---|---|---|---|
| `SystemLanguageModel` (local model) | yes | **NO** (`@available(watchOS, unavailable)`) | **NO** | yes |
| `LanguageModelSession` class | yes | yes (watchOS 27.0) | yes | yes |
| `LanguageModelSession(model: SystemLanguageModel = .default, ...)` inits | yes | **NO** — the whole extension is watchOS-unavailable | **NO** | yes |
| `LanguageModelSession(model: some LanguageModel, ...)` inits (iOS 27 additions) | yes | yes | yes | yes |
| `@Generable` macro / `Generable` protocol | yes | yes — marked `watchOS 27.0` in the current beta interface (see drift note) | yes | yes |
| `GenerationOptions(temperature:)` | yes | yes | yes | yes |
| `PrivateCloudComputeLanguageModel` | yes (iOS 27) | yes (watchOS 27) | yes | yes |

Net effect, unchanged: **there is no on-device local model on the watch.** The
only session you can construct on watchOS takes `some LanguageModel`, and the
only shipping conformer there is the cloud-backed
`PrivateCloudComputeLanguageModel` (untested by us). Parsing is iPhone-side by
design; the guard in `TemplateParser.swift` stays:

```swift
#if canImport(FoundationModels) && !os(watchOS)
```

Without `!os(watchOS)` the file fails to compile for the watch target at
`SystemLanguageModel.default.availability` and
`LanguageModelSession(instructions:)` — verified by type-checking a probe file
against the watchOS 27.0 SDK (error: "'init(model:tools:instructions:)' is
unavailable in watchOS").

**Beta drift notes (as of 2026-07, re-verify each beta):**
- Earlier verification (recorded in the `TemplateParser.swift` comment and
  project hard-rule R7, defined in **fortiche-change-control**) observed
  `@Generable` itself as watchOS-unavailable. In
  the beta currently on disk, the macro and protocol are marked
  `watchOS 27.0` and a bare `@Generable` struct type-checks against both watch
  slices. The operative rule is unaffected — no local model on watch — but the
  precise symbol list moves between betas. Trust the swiftinterface on disk.
- The claim "watch-simulator slice: everything unavailable" is also stale in
  the current beta: the simulator swiftinterface now carries identical
  availability annotations to the device slice (44 `watchOS, unavailable`
  markers in each).

## iOS 27 additions present in the SDK but NOT adopted by Fortiche

Label these as candidates only; adoption goes through **fortiche-change-control**
and the open questions live in **fortiche-research-frontier**.

- **`PrivateCloudComputeLanguageModel`** (iOS 27, watchOS 27): construct with
  `PrivateCloudComputeLanguageModel()` (there is NO `.default` — verified by
  typecheck), own `availability` with `UnavailableReason.deviceNotEligible /
  .systemNotReady`, `quotaUsage` (status `.belowLimit/.limitReached`,
  `resetDate`, `limitIncreaseSuggestion`), and `contextSize` as `async throws`
  (reported ~32K in Apple materials — NOT verified here; read it at runtime).
  **OPEN question: whether an entitlement is required** — resolve before any
  adoption work.
- **Image attachments** (iOS 27): `Attachment<ImageAttachmentContent>` with
  inits from `CGImage`, `CIImage`, `CVPixelBuffer`, or `imageURL:`, usable as
  `PromptRepresentable`. Candidate use: parsing a photographed program sheet.
  Unbuilt, unscoped.
- **`ToolCallingMode`** (iOS 27): `GenerationOptions.toolCallingMode` with
  `.allowed / .required / .disallowed`. Fortiche uses no tools; if tools ever
  appear, `.disallowed` is the correct explicit setting for the parser path.
- Also in the 27 SDK: `LanguageModelError` (replaces the now-deprecated
  `LanguageModelSession.GenerationError` cases) and `Usage` token accounting on
  the session. The repo's catch-all error handling needs no change for the
  deprecation.

## How to inspect SDK truth yourself

The `.swiftinterface` files inside each platform SDK are the ground truth for
what compiles where — more reliable than docs or memory, especially on betas.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app

# Locate the interfaces (one per architecture slice):
ls "$DEVELOPER_DIR/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/"
ls "$DEVELOPER_DIR/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/"
ls "$DEVELOPER_DIR/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/"

# Availability of a symbol = the @available lines immediately ABOVE its declaration:
WIFACE="$DEVELOPER_DIR/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64_32-apple-watchos.swiftinterface"
grep -n -B4 "final public class SystemLanguageModel" "$WIFACE"
grep -n -B4 "public macro Generable" "$WIFACE"
```

When a grep is ambiguous, settle it empirically with a type-check probe (no
device needed):

```bash
cat > /tmp/probe.swift <<'EOF'
import FoundationModels
@Generable struct P { var name: String }
let s = LanguageModelSession(instructions: "hi")   // SystemLanguageModel-backed init
EOF
xcrun -sdk watchos swiftc -typecheck -target arm64_32-apple-watchos27.0 /tmp/probe.swift
```

Compiler errors name the exact unavailable symbol. Adjust `-sdk`/`-target` for
other platforms (`iphoneos` / `arm64-apple-ios27.0`, `watchsimulator` /
`arm64-apple-watchos27.0-simulator`).

## Provenance and maintenance

All claims verified 2026-07-05 against the working tree and the Xcode 27 beta
SDKs at `/Applications/Xcode-beta.app`. One-liners to re-verify what may drift:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app
# Schema, availability mapping, watchOS guard still as described:
grep -n "setGroups\|temperature: 0\|canImport(FoundationModels) && !os(watchOS)\|modelNotReady" FortichePack/Sources/FortichePack/Parsing/TemplateParser.swift
# Parser selection sites unchanged:
grep -rn "IntelligentProgramParser.availability" Fortiche/
# Integration-test gating unchanged:
grep -n "enabled(if:" FortichePack/Tests/FortichePackTests/IntelligentParserTests.swift
# Tests still compile and the gated suite is present:
swift test --package-path FortichePack --list-tests | grep -c Intelligent   # expect 2
# Host-Mac context size and availability (drifts with OS/model updates):
printf 'import FoundationModels\nprint(SystemLanguageModel.default.availability, SystemLanguageModel.default.contextSize)\n' > /tmp/ctx.swift && swift /tmp/ctx.swift
# watchOS symbol availability (drifts between betas):
grep -n -B4 "final public class SystemLanguageModel" "$DEVELOPER_DIR/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64_32-apple-watchos.swiftinterface"
# PCC entitlement question — still OPEN? Check fortiche-research-frontier and Apple release notes.
```
