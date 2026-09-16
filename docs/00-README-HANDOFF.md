# AuraLink — Handoff Brief for the Implementing Agent

You (the reading agent — Claude Code, running somewhere with real Xcode/macOS access) are taking over
an in-progress iOS port. This folder is the complete knowledge transfer. **Read the docs below before
writing/changing code.**

| File | What it contains |
|------|------------------|
| `00-README-HANDOFF.md` | This file — orientation, goal, ground rules, how to work. |
| `01-PROTOCOL-REFERENCE.md` | Condensed, authoritative reference for the Carbit EasyConnect/PXC wire protocol — everything you need to implement the networking + handshake layer without re-deriving it. |
| `02-IOS-ARCHITECTURE-PLAN.md` | The target Swift architecture: what ports 1:1 from Android, what needs an iOS-native rewrite, file-by-file mapping, and the phased build order. |
| `03-CURRENT-STATE.md` | Exactly what already exists in this package (scaffold, project.yml, folder layout) vs. what's still a stub. Read this so you don't redo finished work or silently skip missing pieces. |
| `../reference/android-source/java/` | **Full original Android Kotlin source** (147 files, the real, working, bike-tested implementation). This is ground truth — when a Swift port decision is ambiguous, the Kotlin source is the tie-breaker, not this doc. |
| `../reference/android-docs/` | The original Android project's own reverse-engineering + architecture docs (fuller detail than doc `01` here, including debug war-stories in `05-DEBUG-KNOWLEDGE.md`). |

## The one-paragraph story so far

**OpenCfMoto** is a mature, actively-used open-source Android app (AGPLv3, github.com/zanderp/open-cfmoto,
v2.0.18, 40+ confirmed bike models) that streams Android Auto (Google Maps/Waze) to CFMoto "MotoPlay" /
Carbit "EasyConnect" motorcycle dashboards over Wi-Fi — no T-Box subscription required. The protocol has
been fully reverse-engineered and is documented byte-for-byte. **AuraLink** is a from-scratch iOS port,
targeting specifically a **CFMoto Aura 150** (CFDL16-class dash: 800×386 landscape, non-touch, handlebar
buttons only) owned by the project owner (Miel — not a developer, doesn't read/write code, relies on you
for every technical decision). Distribution is via **TestFlight** (Apple Developer account, $99/yr already
budgeted) — up to 10,000 external testers, no per-device UDID registration, closest to "professional
standard practice" without a full App Store listing.

## Ground rules & decisions already made (do not re-litigate)

- **Platform: iOS only, Swift/SwiftUI, iOS 16.0+ deployment target.** No Android parallel work.
- **Navigation engine: Apple MapKit** (chosen over Google Maps SDK — zero external account/API key
  needed, native, fast to integrate). If MapKit later proves insufficient for a nav-app "feel," revisit,
  but don't switch without discussing tradeoffs with Miel first (Google Maps needs a Cloud account +
  billing on Miel's end).
- **iOS has NO Android Auto equivalent — do not attempt to embed/reverse AAP on iOS.** The Android
  app's `aa/` package (AapTransport, VideoDecoder, AaReceiver, etc.) exists ONLY to receive Google's
  Android Auto video and re-encode it for the bike. On iOS there is no such source: **AuraLink renders
  its own MapKit-based navigation UI directly and encodes that.** Skip the entire Android `aa/` package
  as a porting target — read it only to understand the *downstream* video pipeline shape (encoder
  config, frame queue, letterboxing), which IS reused.
- **Distribution: TestFlight**, Apple Developer Program membership assumed available (or in progress).
  CI should build, sign, and be ready to upload via fastlane/App Store Connect API — do not hand-wave
  this, actually wire it (see `02-IOS-ARCHITECTURE-PLAN.md` → CI/CD section), but note actual TestFlight
  upload requires Miel to supply App Store Connect API key secrets in GitHub Actions — flag this as an
  explicit manual step for Miel rather than something you can complete unattended.
- **Bike is required to test the PXC path end-to-end**, exactly like the Android project. You (or Miel,
  relaying your instructions) cannot fully validate the handshake without live hardware. **Design so a
  single bike test session yields a diagnosable log** — every meaningful step must log through a central
  `LogBus`-equivalent, with a Share Log action, exactly like the Android app's convention. This matters
  even more here because Miel cannot read a stack trace or interpret a crash — the log needs to be
  self-explanatory in plain terms.
- **Target dash: CFDL16 profile only for v1** (Aura 150 — landscape 800×386, non-touch, handlebar
  buttons). Support other `BikeProfile` variants (CFDL26, WiFi-Direct/P2P, etc.) only if trivial to keep
  from the Android port; don't spend effort hardening paths Miel's bike will never hit.
- **No root/jailbreak, no private APIs.** Everything must be App-Store-review-safe even though initial
  distribution is TestFlight — Miel may want the public App Store later, and TestFlight beta review
  already checks for private API usage.
- **License:** match the Android project — **AGPLv3**. Preserve attribution; this is a derivative/port of
  AGPLv3 code, so AuraLink's Swift source must also ship under AGPLv3 with NOTICE/LICENSE carried over
  (copy `reference/android-source`'s LICENSE and adapt NOTICE for the Swift port's own dependencies).

## How to work (Miel's workflow — he is not a developer)

- Miel cannot debug Xcode errors, read Swift compiler output, or interpret crash logs. **Every build
  must be automated (GitHub Actions).** Miel's job is: run `xcodegen generate` if working locally (or
  just trigger CI), install the TestFlight build, ride the bike, and relay **plain-language descriptions
  and the exported log file** back to you. Do not ask him to attach a debugger or read console output.
- Keep changes **incremental and independently testable** — same philosophy as the Android project.
  Ship something that connects to the bike and shows *any* frame before polishing UI.
- Everything user-visible/diagnostic goes through a central logging singleton (see
  `02-IOS-ARCHITECTURE-PLAN.md` → `LogBus`). Prefix logs with a stage tag, e.g. `[PXC]`, `[VIDEO]`,
  `[:10922]`, mirroring the Android convention so Miel's exported logs are diagnosable the same way.

## Coding conventions

- Swift 5.9+, SwiftUI for all UI, `async/await` + `Task` for concurrency (not Combine, unless a specific
  API forces it — e.g. `NWListener` state updates are naturally callback-based, wrap them into
  `AsyncStream` where it simplifies call sites).
- Package/target name: `AuraLink`. Bundle ID: `com.amielsena.auralink`.
- One type per file, file name matches the primary type, mirroring the Android app's one-class-per-file
  layout so the Kotlin ↔ Swift file mapping in `02-IOS-ARCHITECTURE-PLAN.md` stays literal and
  discoverable.
- No force-unwraps (`!`) in networking/protocol code — this runs against a live bike with quirky
  firmware; a crash mid-ride is worse than a logged, recoverable error. Use `guard let` / `if let` /
  explicit error types.
- Every protocol constant (cmd IDs, ports, magic values) must carry the same doc-comment context as the
  Kotlin source (which bike/firmware it was verified against, what log confirmed it) — don't strip that
  context when porting, it's the reason the protocol is trustworthy.
