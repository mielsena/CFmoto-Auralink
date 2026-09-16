# Continue Handoff — savepoint

**Read this file first, before 00-03.** It is kept up to date as a running savepoint: whenever
Miel says "Continue," the resuming agent should read this file + run `TaskList` to pick up exactly
where the previous session left off, without re-deriving anything below.

## Where the project actually lives

`~/Downloads/CFmotoAuraLink ` (note the **trailing space** in the folder name — it's real, part of
the directory name on disk; `cd` into it with the trailing space or tab-complete). This is the
ONLY project copy — several earlier duplicate scaffolds (`~/Desktop/CFmotoApp`,
`~/Desktop/Aura Mirror App`, `~/Downloads/AuraLink`, `~/Downloads/AuraLink-handoff*`) were found and
deleted on 2026-09-16 because they were empty/stale copies of the same zip with no unique work.
**If you ever see another `AuraLink`-shaped folder appear, stop and ask Miel before touching it —
don't assume the one you're already in is the only one.**

No GitHub remote is configured yet. Miel's GitHub is `github.com/mielsena` (currently zero public
repos). Nothing has been pushed anywhere — the only copy of this work is the local git history in
the folder above. **If a fresh session needs to push, ask Miel for a repo URL first**; we cannot
create GitHub repos ourselves.

## Exact current state

Local git log (newest first): `xcodegen generate` + `xcodebuild build`/`test` all pass as of the
last commit. Phase numbers below match `docs/02-IOS-ARCHITECTURE-PLAN.md`'s phased build order.

| Phase | Status |
|---|---|
| 0. Scaffold | Done. `xcodegen generate && xcodebuild build` clean. |
| 1. Protocol layer | **Done + tested.** `PxcFrame`, `ReqBaseFrame`, `QrData`, `RsaKeys`, `ClientInfo`, `ClockSync`, `BikeProfile`, `PxcHandshake` all typecheck and build against the real iOS SDK (not just macOS `-typecheck` like the very first pass). `Tests/PxcFrameTests.swift` + `Tests/QrDataTests.swift` — 15 tests, all passing (Swift Testing framework, not XCTest). |
| 1. Networking layer | **Done, unverified on hardware.** `Sources/Networking/PxcTcpServer.swift` (generic `NWListener`/`NWConnection` async wrapper — `BikeSocket` + `PxcTcpServer`), `EasyConnProber.swift` (3-listener orchestration, one-shot probe to `:10930`, ctrl/media read loops, dual-channel-socket heartbeat, reconnect/backoff), `ConnectionState.swift` (`Phase` enum, `@MainActor`/`ObservableObject`), `BikeWifiManager.swift` (`NEHotspotConfiguration` join). `Sources/Models/BikeMemory.swift` — minimal single-bike slice (full Garage version is Phase 6). Builds clean, zero warnings, on the real iOS SDK. **No unit tests possible here** (needs live sockets/a real bike) — first real verification is the bike test. |
| 2. Video pipeline | **Not started.** `Sources/Video/` is empty (`.gitkeep` only). |
| 3. MapKit | Not started. |
| 4. Adaptive bitrate + background | Not started. |
| 5. UI shell | Not started — `App/AuraLinkApp.swift` still shows `ScaffoldPlaceholderView`. |
| 6. Trips/GPX/buttons/settings | Not started. |
| 7. CI/polish | `.github/workflows/build.yml` + `fastlane/` are written but **never run in real GitHub Actions** — no remote exists yet to push to and trigger them. |

## Scope decisions made in the networking layer (don't re-litigate)

- **mDNS discovery NOT implemented.** `01-PROTOCOL-REFERENCE.md` §2 explicitly permits skipping it
  ("don't make mDNS a hard dependency"); v1 only ever uses the documented fallback — derive the
  bike's gateway IP from our own Wi-Fi IP/netmask (`en0`, via `getifaddrs`) and probe
  `gatewayIP:10930` directly. Revisit only if a real Aura 150 capture shows this fails.
- **No Wi-Fi-Direct/P2P, no VPN-kill-switch detection, no Yunmo SoftAP fallback, no touch-ghost
  filtering.** All deliberately dropped per `00-README-HANDOFF.md`'s ground rules — v1 targets one
  non-touch AP-mode CFDL16 bike. Kept the two things that were real field-tested fixes even for a
  single bike: the reconnect/backoff constants and the dual heartbeat on BOTH `:10922` channel
  sockets (CAR_CTRL and CAR_DATA) — leaving either idle caused a ~7s disconnect flap on the
  800NK-family unit in the Android app's field logs.
- **`EasyConnProber` has zero video-pipeline dependency.** It talks to a `BikeVideoSource`
  protocol (`configureCanvas`/`onBikeDataStart`/`pollFrame`) that Phase 2's `VideoPipeline` will
  conform to. Right now nothing is attached, so `REQ_RV_DATA_START`/`REQ_RV_DATA_NEXT` just log
  "no video source attached yet" / "no frame ready" — this is expected and matches the phased
  build order's Phase 1 success criterion ("no video yet").
- **`NEHotspotConfiguration` needs the restricted `com.apple.developer.networking.HotspotConfiguration`
  entitlement** — already added to `project.yml`. Apple may ask for justification when generating
  a provisioning profile / archiving for TestFlight. This is a manual Apple-portal step, flag it to
  Miel if `fastlane beta` fails on signing for this reason; nothing to fix in code.
- **Swift 6 strict concurrency caught a real bug during this session**: a `var resumed = false`
  captured and mutated inside `NWConnection.stateUpdateHandler` compiled with warnings that are
  errors under Swift 6 (`PxcTcpServer.swift`). Fixed with a small `OSAllocatedUnfairLock`-backed
  `ResumeOnce` latch type — reuse that pattern (don't reintroduce a bare captured `var Bool`) if
  you add more continuation-based Network.framework wrappers later.

## Do this first when resuming

1. `cd "~/Downloads/CFmotoAuraLink "` (mind the trailing space), `xcodegen generate`.
2. `xcodebuild build -project AuraLink.xcodeproj -scheme AuraLink -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO` — confirm still green before adding more code.
3. **Run tests via a background + log-file pattern, not a foreground blocking call** — a foreground
   `xcodebuild test` hung for 5+ minutes in this session for no clear reason (possibly a stale
   simulator/xctest process from an earlier destination-name typo); backgrounding with
   `nohup ... > /tmp/log 2>&1 &` then polling the log file completed in ~15-20s reliably. If a test
   run seems to hang, `pkill -9 -f "xcodebuild test"` and retry via the background pattern before
   assuming something is actually broken.
4. Continue with **Phase 2**: `Sources/Video/H264Encoder.swift` (`VTCompressionSession` wrapper),
   `AnnexBConverter.swift` (AVCC→Annex-B), `FrameQueue.swift`, `VideoPipeline.swift` (implements
   `BikeVideoSource` from `EasyConnProber.swift`, ties encoder + a **static test pattern** —
   NOT MapKit yet — per the phased build order's explicit instruction to isolate video-path bugs
   from MapKit-rendering bugs). Read `docs/01-PROTOCOL-REFERENCE.md` §5 and Kotlin
   `reference/android-source/java/dev/zanderp/opencfmoto/VideoPipeline.kt` before writing.
   Success criterion: bike shows *something* on screen without disconnecting (proves the 9s-timeout
   / repeat-frame handling works) — this needs the real Aura 150, so flag to Miel once Phase 2 code
   is written and building that it's ready for a bike test.

## Ground rules recap (full detail in `00-README-HANDOFF.md`/`04` history above — don't re-litigate)

iOS 16+ deployment target (no `@Observable` macro — use `ObservableObject`/`@Published`) · SwiftUI +
async/await (actors for shared mutable state) · MapKit not Google Maps · no Android Auto
equivalent · TestFlight distribution · CFDL16 profile only for v1 · no root/private APIs · AGPLv3
license carried over · one type per file · no force-unwraps in protocol/networking code · every
protocol constant keeps its "verified against X" doc comment · everything diagnosable logs through
`LogBus` with a `[TAG]` prefix — Miel cannot read Xcode console output or a stack trace, the
exported log (Share Log, still to be built in Phase 5/6) is the entire debugging surface for a real
bike test. **Savepoint discipline (added 2026-09-16, Miel's explicit instruction): keep this file
current as work progresses, not just at context-limit time, so "Continue" always has an accurate
place to resume from.**
