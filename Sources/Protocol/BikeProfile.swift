// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from BikeProfile.kt, trimmed to the strategy shape + the one profile v1 targets.
//
// The Android app carries ~8 BikeProfile implementations (one per dashboard generation it has been
// field-tested against: CFDL16, CFDL26 in three panel shapes, 800NK/CRCP, Moto Morini, CL-C450...).
// docs/00-README-HANDOFF.md's ground rules are explicit that AuraLink v1 targets ONLY the CFDL16
// profile (the Aura 150's presumed dashboard family) and should not spend effort hardening paths
// the bike will never hit. `BikeProfile` is still a protocol (not a hardcoded struct) precisely so
// a second bike/profile can be added later without restructuring the handshake — see
// docs/01-PROTOCOL-REFERENCE.md's framing that CLIENT_INFO should refine the assumption, not be
// assumed away.
//
// `Cfdl16Profile` below reproduces `LegacyCfdl16Profile` (Kotlin: "BIKE A", sdk 0.9.29.1, the unit
// the whole protocol was reverse-engineered against) byte-for-byte, including its
// `handleUnknownControl` delegation: newer CFDL16-family units send a post-handshake notify burst
// (0x103a0 OTA info, 0x10020 media features, ...) that must be acked `cmd+1` (empty) or the bike
// never opens the media ports — so unknown cmds are logged AND generically acked, not just logged.

import Foundation

protocol BikeProfile: Sendable {
    /// Human-readable label — appears in bike-test logs so a capture is self-describing.
    var name: String { get }

    /// How strongly this profile claims a given CLIENT_INFO. Highest positive score wins; 0 = no claim.
    func score(_ info: BikeClientInfo) -> Int

    /// `supportFunction` value advertised in our own CLIENT_INFO reply.
    var advertisedSupportFunction: Int { get }

    /// Whether this dash has a touchscreen (CFDL16/Aura 150: no — handlebar buttons only).
    var supportsScreenTouch: Bool { get }

    /// Round/fit the bike's requested capture dimensions to what our encoder should target.
    /// Default: round down to a multiple of 16 on each axis (`w & ~15`), per
    /// docs/01-PROTOCOL-REFERENCE.md §4 RLY_RV_CONFIG_CAPTURE.
    func roundCaptureDimensions(width: Int, height: Int) -> (width: Int, height: Int)

    var forceBaseline: Bool { get }
    var videoBitrate: Int { get }
    var videoFrameRate: Int { get }
    var videoIFrameIntervalSec: Int { get }

    /// Handle a control-plane cmd not covered by PxcHandshake's fixed switch. Returns the reply
    /// frame to send (if any). `nil` means "log only, no reply."
    func handleUnknownControl(cmd: Int32, payload: Data) -> PxcFrame?
}

extension BikeProfile {
    func roundCaptureDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        (width & ~15, height & ~15)
    }
    var forceBaseline: Bool { true }
    var videoBitrate: Int { 2_500_000 }
    var videoFrameRate: Int { 30 }
    var videoIFrameIntervalSec: Int { 1 }
}

/// CFDL16 — the dashboard family the whole PXC protocol was reverse-engineered against, and the
/// presumed family for the Aura 150 (see docs/01-PROTOCOL-REFERENCE.md header). Non-touch,
/// landscape ~800×386, handlebar-button navigation only.
struct Cfdl16Profile: BikeProfile {
    let name = "CFDL16 (Aura 150 default)"
    let advertisedSupportFunction = 0
    let supportsScreenTouch = false

    func score(_ info: BikeClientInfo) -> Int {
        // Floor of 1 so this profile always claims *something* (it's also the only registered
        // profile in v1, so `BikeProfiles.select` never actually needs the floor — kept for when a
        // second profile is added later and ties need a deterministic winner).
        var s = 1
        if info.huName.hasPrefix("CFDL16") { s += 4 }
        if info.sdkVersion.hasPrefix("0.9.29") { s += 3 }
        if info.channel.trimmingCharacters(in: .whitespaces) == "37416" { s += 2 }
        return s
    }

    /// Newer CFDL16-family units send the same post-handshake notify burst as CFDL26 dashes
    /// (0x103a0 OTA FTP info, 0x10020 media-feature flags, 0x10780 log report, ...) and will not
    /// open the media ports until each is acked `cmd+1` (empty). HU_TIME_SYNC gets a real body
    /// (see ClockSync.swift); everything else gets a generic empty ack. This is the same fallback
    /// the Kotlin LegacyCfdl16Profile delegates to (`Cfdl26PortraitProfile.handleUnknownControl`).
    func handleUnknownControl(cmd: Int32, payload: Data) -> PxcFrame? {
        if cmd == PxcCmd.huTimeSync {
            let ack = HuTimeSync.ack(for: payload)
            return PxcFrame(cmd: PxcCmd.huTimeSyncAck, payload: ack.payload)
        }
        return PxcFrame(cmd: cmd &+ 1, payload: Data())
    }
}

/// Registry + selection, mirroring `BikeProfiles.select` in the Kotlin source. Only one profile is
/// registered for v1; `select` always returns it. Structured as a lookup (not a hardcoded return)
/// so a confirmed-divergent Aura 150 capture can add a second `BikeProfile` without touching
/// `PxcHandshake`.
enum BikeProfiles {
    static let `default`: BikeProfile = Cfdl16Profile()
    private static let all: [BikeProfile] = [Cfdl16Profile()]

    /// Synchronous by design (pure scoring, no I/O) so actor-isolated callers (PxcHandshake) can log
    /// the returned `scoreLog` themselves with `await` instead of threading a log closure through.
    static func select(_ info: BikeClientInfo) -> (profile: BikeProfile, scoreLog: String) {
        let scored = all.map { ($0, $0.score(info)) }
        let scoreLog = "[profile] scores=" + scored.map { "\($0.0.name)=\($0.1)" }.joined(separator: ", ")
        let chosen = scored.filter { $0.1 > 0 }.max(by: { $0.1 < $1.1 })?.0 ?? Self.default
        return (chosen, scoreLog)
    }
}
