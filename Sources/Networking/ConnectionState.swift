// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from ConnectionState.kt's `Phase` enum + `ConnectionState` object, with the Android
// `@StringRes` localization dropped (no localization system exists in this Swift project yet —
// add a display-string mapping in the UI layer later without touching this file). Trimmed to the
// phases v1's simplified reconnect model (no AA/mirroring modes) actually reaches.

import Foundation

enum ConnectionPhase: String, Sendable, Equatable {
    case idle
    case joiningWifi
    case pxcConnecting
    case streaming
    case reconnecting
    case waitingForBike
    case stopped
    case error

    /// English label for logs/support — mirrors Kotlin `Phase.logLabel`.
    var logLabel: String {
        switch self {
        case .idle: return "Ready"
        case .joiningWifi: return "Connecting to bike Wi-Fi…"
        case .pxcConnecting: return "Linking to dashboard…"
        case .streaming: return "Connected — projecting to dash"
        case .reconnecting: return "Link dropped — reconnecting…"
        case .waitingForBike: return "Bike out of range — waiting…"
        case .stopped: return "Stopped"
        case .error: return "Error — see logs"
        }
    }

    var isBusy: Bool {
        switch self {
        case .joiningWifi, .pxcConnecting, .reconnecting, .waitingForBike: return true
        case .idle, .streaming, .stopped, .error: return false
        }
    }
}

/// Process-wide connection status. `EasyConnProber`/`PxcHandshake` publish transitions here; the
/// UI (Phase 5) observes them. `@MainActor` + `ObservableObject`/`@Published` rather than the
/// `@Observable` macro, which needs iOS 17 — this project's deployment target is iOS 16
/// (see project.yml).
@MainActor
final class ConnectionState: ObservableObject {
    static let shared = ConnectionState()

    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var detail: String = ""

    private init() {}

    /// Moves to `newPhase`. Pass `detail` to change the trailing detail (bike name, retry count,
    /// error text); omit it to keep whatever detail is already set — mirrors Kotlin
    /// `ConnectionState.set(newPhase, newDetail = null)`.
    func set(_ newPhase: ConnectionPhase, detail newDetail: String? = nil) async {
        phase = newPhase
        if let newDetail { detail = newDetail }
        let text = detail.isEmpty ? newPhase.logLabel : "\(newPhase.logLabel) — \(detail)"
        await LogBus.shared.log("[state] \(text)")
    }
}
