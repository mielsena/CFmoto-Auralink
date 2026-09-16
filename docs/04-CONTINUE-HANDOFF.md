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

**Pushed to GitHub as of 2026-09-16**: `origin` = `https://github.com/mielsena/CFmoto-Auralink.git`,
branch `main`, tracked. Auth is via `gh` CLI (installed this session, `gh auth login` done by Miel
via browser) — `git push`/`pull` work directly, no token/password needed. If a fresh machine needs
this again: `brew install gh && gh auth login` (browser flow), then normal git commands pick up its
stored credentials automatically.

## Exact current state

Local git log (newest first): `xcodegen generate` + `xcodebuild build`/`test` all pass as of the
last commit. Phase numbers below match `docs/02-IOS-ARCHITECTURE-PLAN.md`'s phased build order.

| Phase | Status |
|---|---|
| 0. Scaffold | Done. `xcodegen generate && xcodebuild build` clean. |
| 1. Protocol layer | **Done + tested.** `PxcFrame`, `ReqBaseFrame`, `QrData`, `RsaKeys`, `ClientInfo`, `ClockSync`, `BikeProfile`, `PxcHandshake` all typecheck and build against the real iOS SDK (not just macOS `-typecheck` like the very first pass). `Tests/PxcFrameTests.swift` + `Tests/QrDataTests.swift` — 15 tests, all passing (Swift Testing framework, not XCTest). |
| 1. Networking layer | **Done, unverified on hardware.** `Sources/Networking/PxcTcpServer.swift` (generic `NWListener`/`NWConnection` async wrapper — `BikeSocket` + `PxcTcpServer`), `EasyConnProber.swift` (3-listener orchestration, one-shot probe to `:10930`, ctrl/media read loops, dual-channel-socket heartbeat, reconnect/backoff), `ConnectionState.swift` (`Phase` enum, `@MainActor`/`ObservableObject`), `BikeWifiManager.swift` (`NEHotspotConfiguration` join). `Sources/Models/BikeMemory.swift` — minimal single-bike slice (full Garage version is Phase 6). Builds clean, zero warnings, on the real iOS SDK. **No unit tests possible here** (needs live sockets/a real bike) — first real verification is the bike test. |
| 2. Video pipeline | **Done, unverified on hardware.** `Sources/Video/H264Encoder.swift` (`VTCompressionSession` wrapper, Baseline@3.1, `AllowFrameReordering=false`), `AnnexBConverter.swift` (AVCC→Annex-B + SPS/PPS extraction), `FrameQueue.swift` (bounded drop-oldest queue), `VideoPipeline.swift` (implements `BikeVideoSource`, fixed-rate feed loop that doubles as the repeat-frame keep-alive), `TestPatternSource.swift` (temporary cycling-color test card — delete once Phase 3 is proven on the bike). `EasyConnProber.swift`'s `BikeVideoSource` protocol was extended to pass `bitrate`/`frameRate`/`keyframeIntervalSeconds`/`forceBaseline` through from the active `BikeProfile` instead of hardcoding them. **Nothing wired to the app yet** — no ViewModel/UI creates a `VideoPipeline` + attaches it to `EasyConnProber` + attaches `TestPatternSource` to it. That wiring is deferred to Phase 5 (UI shell) deliberately, since a real end-to-end bike test needs *some* UI trigger anyway (Connect button) and building throwaway scaffolding just to test Phase 2 in isolation without hardware access in this environment wasn't worth it. `Tests/FrameQueueTests.swift` — 6 tests, all passing. |
| 3. MapKit | Not started. |
| 4. Adaptive bitrate + background | Not started. |
| 5. UI shell | Not started — `App/AuraLinkApp.swift` still shows `ScaffoldPlaceholderView`. **This is also where Phase 2/3's actual wiring happens** — see note above. |
| 6. Trips/GPX/buttons/settings | Not started. |
| 7. CI/polish | `.github/workflows/build.yml` running for real in GitHub Actions as of 2026-09-16. **First real run failed** — see "CI gotchas" below — fixed and should be green on the next push; verify with `gh run list` / `gh run view <id> --log-failed` if unsure. |

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
- **Swift 6 strict concurrency caught two real bugs during this session, not just noise:**
  1. A `var resumed = false` captured and mutated inside `NWConnection.stateUpdateHandler` compiled
     with warnings that are errors under Swift 6 (`PxcTcpServer.swift`). Fixed with a small
     `OSAllocatedUnfairLock`-backed `ResumeOnce` latch type.
  2. `CVPixelBuffer` (CoreVideo, not `Sendable`) crossing an actor boundary in
     `PixelBufferSource.currentPixelBuffer()` (`VideoPipeline.swift`). Fixed with a
     `SendablePixelBuffer: @unchecked Sendable` box — the one place it crosses an actor boundary,
     not a blanket `@unchecked Sendable` on the buffer type itself.
  Reuse these patterns (don't reintroduce a bare captured `var`, don't pass CF types across actors
  unboxed) if you add more continuation-based or actor-isolated wrappers later.
- **A real deadlock, caught by `FrameQueueTests.pollTimesOutWhenEmpty` hanging the whole test run**:
  `FrameQueue.poll(timeout:)` originally raced a `withCheckedContinuation` against a `Task.sleep`
  inside `withTaskGroup`. Cancelling the losing child task does NOT resume a bare continuation, so
  the losing task hung forever and `withTaskGroup` could never return (structured concurrency waits
  for all children at scope exit). Fixed by having a plain timer `Task` call back into the actor
  (`expireWaiter(token:)`) to resume the SAME continuation itself, with a monotonic token to
  disambiguate a stale timeout from a newer `poll` call's waiter — mutual exclusion is free since
  actor methods never interleave. **If you write another "wait up to N or return early" pattern
  anywhere else in this codebase, do not use the TaskGroup+cancellation shape — use this token
  pattern instead.**
- **First real GitHub Actions run failed** on `Sources/Video`'s companion push, with `BUILD FAILED`
  and no Swift compiler error — the actual cause was `error: No simulator runtime version from
  [...] available to use with iphonesimulator SDK version <DVTBuildVersion 22A3362>`. The workflow
  had hardcoded `/Applications/Xcode_16.app` (per the original handoff scaffold); that exact version
  string's simulator runtimes didn't match what was actually on the `macos-15` runner image. Fixed
  by selecting `/Applications/Xcode.app` (the symlink GitHub's runner images keep pointed at the
  current default Xcode, always matched with its own runtimes) instead of a pinned version number,
  and by selecting the test destination by UDID (`xcrun simctl list devices available | grep
  iPhone`) instead of a hardcoded device name like `"iPhone 16"`, which can vanish from future
  simulator catalogs. **If CI ever fails with `BUILD FAILED` and no visible Swift error, grep the
  log for "error:" case-sensitively AND search near the top of the Build step — this exact failure
  mode (a toolchain/runtime error, not a compile error) prints its one `error:` line early, long
  before the "(N failures)" summary at the bottom.**

## Do this first when resuming

1. `cd "~/Downloads/CFmotoAuraLink "` (mind the trailing space), `xcodegen generate`.
2. `xcodebuild build -project AuraLink.xcodeproj -scheme AuraLink -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO` — confirm still green before adding more code.
3. **Run tests via a background + log-file pattern, not a foreground blocking call.** A foreground
   `xcodebuild test` hung twice this session — once from a stale process, once from the real
   `FrameQueue` deadlock above. `nohup xcodebuild test ... > /tmp/log 2>&1 &` then polling the log
   file (`tail`/`grep`) is the reliable pattern; it also makes a genuine hang obviously distinct
   from normal test runtime (checking `ps aux | grep xcodebuild` shows near-zero CPU growth if
   truly stuck vs. actively compiling/running). `pkill -9 -f "xcodebuild test"` before retrying.
4. **Check CI status before assuming local-green means everything's fine**: `gh run list --limit 3`
   from inside the repo directory (must `cd` there first — `gh`, like `git`, needs to be run from
   inside the repo, and the shell's cwd resets between tool calls in this environment). If a run
   failed, `gh run view <id> --log-failed > /tmp/ci-fail.log 2>&1` and read the FULL file (grep
   truncation hid the real error once this session — see the CI gotcha above).
5. Continue with **Phase 3**: `Sources/Navigation/DashMapView.swift` (off-screen `MKMapView` host),
   `RouteManager.swift` (`MKDirections` wrapper), `Sources/Video/NavigationCompositor.swift`
   (renders the map into a `CVPixelBuffer` on a timer, replacing `TestPatternSource` as
   `VideoPipeline`'s attached `PixelBufferSource` — port the letterbox/aspect-fit math from Kotlin
   `AaCompositor.kt`'s `mapCanvasToSource`/margin calculation, the only part of that file that
   ports directly per `docs/02-IOS-ARCHITECTURE-PLAN.md`). Success criterion: live, panning map on
   the dash — still needs the real bike, so this and Phase 2 will likely both get their first
   hardware verification together once Phase 5's UI shell gives Miel a Connect button to test with.

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
