# Continue Handoff — resuming in real Xcode

Written at the point where the previous agent session (CLI-only macOS environment, no Xcode.app, no
`xcodegen`, no iOS SDK) handed off to a session running with real Xcode + Claude Code on the SDE
platform. **Read this file first, before 00–03** — it tells you what changed since those docs were
written and what to do differently now that real Xcode tooling exists.

## Why this doc exists

The previous session had `swift`/`swiftc` (Xcode Command Line Tools) but not `Xcode.app`, so:
- No `xcodegen` binary → `project.yml` has never been run through `xcodegen generate`.
- No iOS SDK → `xcodebuild` cannot target iOS at all (`xcodebuild -showsdks` only lists macOS).
- **Never built once, in any form, until now.** Everything below was validated the only way
  possible without those tools: `xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0
  -typecheck` against the files that only import Foundation/Network/Security (frameworks shared
  between macOS and iOS SDKs). That catches real Swift errors (see "Bugs already caught" below) but
  **cannot** catch iOS-SDK-only issues: UIKit availability, Network.framework listener binding
  quirks on-device, VideoToolbox/MapKit specifics, entitlement/capability requirements, or anything
  that only shows up in the Simulator/on-device. Treat the first real `xcodebuild build` in this
  environment as a genuine unknown, per docs/03-CURRENT-STATE.md's original framing — just now it's
  finally possible to run it.

## Do this first, in order

1. `brew install xcodegen` (not installed in the previous environment; may or may not be installed
   here — check with `which xcodegen` first).
2. `cd` into this repo, run `xcodegen generate`. This produces `AuraLink.xcodeproj` from
   `project.yml` — it is gitignored on purpose, regenerate it, don't hand-edit a checked-in project
   file (see `03-CURRENT-STATE.md`).
3. Open `AuraLink.xcodeproj`, select a Simulator (any iPhone, iOS 16+), **Product ▸ Build**. This is
   the actual first build this project has ever had. Fix forward whatever XcodeGen/Xcode surfaces —
   don't assume the Phase 1 files below are bug-free just because they typechecked on macOS.
4. Run `AuraLinkTests` (currently empty — Phase 1 tests are the next task, see below).
5. Only after a clean build: keep going down the phased build order in
   `docs/02-IOS-ARCHITECTURE-PLAN.md`, resuming exactly where this doc says to below.

## Exact current state (as of this handoff)

All of Phase 1's **protocol layer** is written and typechecks cleanly:

| File | Status |
|---|---|
| `Sources/Protocol/PxcFrame.swift` | Done — 16-byte CmdBaseHead framing + full cmd-ID table |
| `Sources/Protocol/ReqBaseFrame.swift` | Done — 8-byte media-plane framing + config-capture structs |
| `Sources/Protocol/QrData.swift` | Done — Carbit/EasyConnect QR parsing (v1 scope: AP-mode only, see file header for what was deliberately dropped vs. the Android original) |
| `Sources/Protocol/RsaKeys.swift` | Done — 1024-bit RSA (matches Kotlin source, NOT the 2048-bit the condensed protocol doc says — Kotlin is ground truth per `00-README-HANDOFF.md`), Keychain-persisted, X.509 SPKI export, PKCS#1 v1.5 raw signing |
| `Sources/Protocol/ClientInfo.swift` | Done — `BikeClientInfo` (loose JSON reader) + `PhoneClientInfo` (our CLIENT_INFO reply, exact field order from Kotlin `basePhoneClientInfo`) |
| `Sources/Protocol/ClockSync.swift` | Done — `HuTimeSync` ported faithfully (byte-exact ack logic); `HuQueryTime` deliberately simplified to the one default mode v1 needs (see file header — the Kotlin `ClockLab` multi-bike testing harness was NOT ported, out of scope) |
| `Sources/Protocol/BikeProfile.swift` | Done — `BikeProfile` protocol + `Cfdl16Profile` (the only registered profile in v1, deliberately — see file header for why the other 7 Kotlin profiles were not ported) |
| `Sources/Protocol/PxcHandshake.swift` | Done — `actor PxcHandshake`, full control-plane dispatch (channel select, CLIENT_INFO, CHECK_SN, heartbeat, HU_TIME_SYNC/HU_QUERY_TIME, generic unknown-cmd ack fallback) |
| `Sources/Services/LogBus.swift` | Done — `actor LogBus` + `LogRedactor`. Every subsequent file should log through `LogBus.shared.log(...)`, prefixed `[TAG]`, per the project convention |

**Not started yet** (this is exactly where to resume):

- `Sources/Networking/PxcTcpServer.swift` — generic `NWListener`/`NWConnection` async wrapper. Design
  intent (not yet written, use your judgement): a `BikeSocket` class wrapping `NWConnection` with
  `async func start()`, `async func send(Data)`, `async func receive(exactly:) -> Data`, `cancel()`;
  and `PxcTcpServer` wrapping `NWListener` bound to a specific local IP+port via
  `parameters.requiredLocalEndpoint`.
- `Sources/Networking/EasyConnProber.swift` — the 3-listener orchestration (ports 10920/10921/10922),
  the one-shot probe to `:10930`, accept loops dispatching by port to `PxcHandshake` (ctrl) or a
  media-plane loop (data), per-channel-socket heartbeat timers (2s, **both** CAR_CTRL and CAR_DATA —
  this was a real field-tested fix in the Android app, do not skip either socket), and
  reconnect/backoff. Ground rule: port the Kotlin file's touch-ghost-filtering, Wi-Fi-Direct P2P,
  VPN-kill-switch detection, and Yunmo SoftAP fallback were all **deliberately scoped out** — v1
  targets one non-touch AP-mode CFDL16 bike, not the Android app's 40-bike matrix. Keep the
  reconnect/backoff constants and the dual-heartbeat fix; that's the part that's load-bearing.
- `Sources/Networking/ConnectionState.swift` — port `Phase` enum + observable state, dropping the
  Android `@StringRes` localization (use plain `String` — no localization system exists in this
  Swift project yet).
- `Sources/Networking/BikeWifiManager.swift` — **read the Apple-console gotcha below before writing
  this file.**
- `Sources/Models/BikeMemory.swift` (minimal slice) — persist last-joined QR/SSID so a reconnect
  doesn't require re-scanning. Full version is Phase 6; Phase 1 only needs enough to remember one
  bike.
- `Tests/PxcFrameTests.swift`, `Tests/QrDataTests.swift` — round-trip encode/decode, magic-XOR
  rejection, QR parsing edge cases. Zero dependencies, should be the first thing you can actually
  run (`xcodebuild test`) once the project builds.

Then continue straight down the rest of `docs/02-IOS-ARCHITECTURE-PLAN.md`'s phased order (Phase 2:
video pipeline with a static test pattern; Phase 3: MapKit; Phase 4: adaptive bitrate + background
survival; Phase 5: UI shell; Phase 6: trips/GPX/button mapping/settings; Phase 7: CI + polish).

## Bugs already caught by the compiler (context for why some code looks unusual)

- **`extension Data { ... withUnsafeBytes(of:) ... }` is ambiguous.** Inside an `extension Data`, a
  bare call to `withUnsafeBytes(of: &v)` resolves to `Data`'s own instance method (wrong meaning —
  reads *this* Data's bytes, not the local variable's) instead of the global
  `Swift.withUnsafeBytes(of:_:)` you actually want. `PxcFrame.swift`'s little-endian helpers
  explicitly qualify with `Swift.withUnsafeBytes` — don't "simplify" that away, it will silently
  compile something else if you do (or fail to compile at all, per the reproduction that caught
  this). Watch for the same trap anywhere else `Data`/`Array` extensions touch raw memory.

## Apple-console / entitlement gotchas for the next phase (BikeWifiManager)

These cannot be fixed by writing code alone — flag them to Miel as soon as you hit them, per the
ground rule in `00-README-HANDOFF.md` about manual Apple-console steps:

1. **`NEHotspotConfiguration` requires the "Hotspot Configuration" capability**, which is a
   *restricted* entitlement (`com.apple.developer.networking.HotspotConfiguration`) — unlike a plain
   Info.plist usage string, this must be added via Xcode's **Signing & Capabilities** tab (or added
   to `project.yml`'s `entitlements.properties` block) AND Apple may ask for a justification when the
   provisioning profile is generated. `project.yml` currently only has
   `com.apple.developer.networking.wifi-info` — the Hotspot Configuration entitlement is **not**
   present yet. Add it when you write `BikeWifiManager.swift`, and tell Miel he may need to accept a
   capability/entitlement request in the Apple Developer portal (this is the kind of "click through
   a web console" step he asked to be told about, not done silently).
2. **Local Network permission prompt**: the first time the app touches Bonjour/local sockets on a
   fresh install, iOS shows a system permission sheet (backed by `NSLocalNetworkUsageDescription`,
   already in `project.yml`). If `EasyConnProber`'s listeners come up before that prompt is answered,
   early connection attempts will silently fail — sequence the UI (Phase 5) so Connect explicitly
   waits for/prompts for this permission before starting the listeners, and log the outcome via
   `LogBus` so a failed first-connect log doesn't look like a protocol bug.
3. **"No internet" Wi-Fi + iOS route selection**: pin `NWParameters.requiredInterfaceType = .wifi`
   (and consider `prohibitedInterfaceTypes = [.cellular]`) on both the listeners and the outbound
   probe connection in `EasyConnProber`, or iOS may prefer/attempt cellular for a network it
   perceives as internet-less, exactly the failure mode `01-PROTOCOL-REFERENCE.md` §2 warns about.
4. **Test the Keychain/RSA path on a physical device early.** `RsaKeys.swift` persists the keypair
   via `SecItemAdd`/`kSecAttrAccessibleAfterFirstUnlock`. This should work identically on Simulator
   and device, but the bike-pairing flow it feeds into can only be end-to-end verified on a real
   iPhone joined to the Aura 150's actual Wi-Fi AP — Simulator networking doesn't let you join an
   arbitrary SSID the way `NEHotspotConfiguration` does on-device.

## Ground rules recap (full detail in `00-README-HANDOFF.md` — don't re-litigate these)

iOS 16+ deployment target · SwiftUI + async/await (actors for shared mutable state, as done in
`LogBus`/`PxcHandshake`) · MapKit not Google Maps · no Android Auto equivalent, AuraLink renders its
own MapKit UI · TestFlight distribution · CFDL16 profile only for v1 · no root/private APIs · AGPLv3
license carried over · one type per file · no force-unwraps in protocol/networking code · every
protocol constant keeps its "verified against X" doc comment · everything diagnosable logs through
`LogBus` with a `[TAG]` prefix, because Miel cannot read Xcode console output or a stack trace —
the exported log (Share Log, still to be built in Phase 5/6) is the entire debugging surface for a
real bike test.
