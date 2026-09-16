// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// iOS has no equivalent of Android's `WifiNetworkSpecifier` (BikeWifi.kt) — apps can't silently
// join arbitrary Wi-Fi. `NEHotspotConfiguration` is the closest match: it can join a network given
// SSID+password with no MDM, but shows a one-time system confirmation sheet on the FIRST join for
// a given SSID (silent on every join after that). See docs/04-CONTINUE-HANDOFF.md's Apple-console
// gotcha #1 — this requires the restricted "Hotspot Configuration" entitlement
// (`com.apple.developer.networking.HotspotConfiguration`), which Apple may ask for justification
// on when generating a provisioning profile. That's a manual Apple-portal step for Miel, not
// something this code can complete unattended — flag it if the TestFlight archive step fails here.

import Foundation
import NetworkExtension

enum BikeWifiError: Error, CustomStringConvertible {
    case system(Error)
    case notAssociatedAfterJoin

    var description: String {
        switch self {
        case .system(let e): return "BikeWifiManager: \(e.localizedDescription)"
        case .notAssociatedAfterJoin: return "BikeWifiManager: joined but not confirmed on the bike's SSID yet"
        }
    }
}

/// Joins the bike's SoftAP and confirms association. WPA2-PSK only — matches the QR's
/// `auth=wpa2-psk` (docs/01-PROTOCOL-REFERENCE.md §1); the Aura 150's AP is not expected to be open.
actor BikeWifiManager {
    static let shared = BikeWifiManager()

    /// Applies (or silently reuses, if already approved) an `NEHotspotConfiguration` for
    /// `ssid`/`password`, then polls until the phone is actually associated with it — `apply`'s
    /// completion can fire before iOS finishes the join, and the bike's Wi-Fi has no internet
    /// access, so system heuristics doing a "is this network any good" check can be slow.
    func join(ssid: String, password: String) async throws {
        await LogBus.shared.log("[wifi] requesting join: \(ssid)…")
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = false // stay associated across app restarts/backgrounding.

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                if let nsError = error as NSError? {
                    let alreadyAssociated = nsError.domain == NEHotspotConfigurationErrorDomain
                        && nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
                    if alreadyAssociated {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: BikeWifiError.system(nsError))
                    }
                } else {
                    continuation.resume()
                }
            }
        }

        guard await waitUntilAssociated(ssid: ssid) else {
            throw BikeWifiError.notAssociatedAfterJoin
        }
        await LogBus.shared.log("[wifi] joined: \(ssid)")
    }

    /// Removes our hotspot configuration for `ssid` (Garage "forget bike" flow, Phase 6).
    func forget(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    /// Currently-associated Wi-Fi SSID, or `nil` if not on Wi-Fi / not yet resolved.
    func currentSSID() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    private func waitUntilAssociated(ssid: String, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await currentSSID() == ssid { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return await currentSSID() == ssid
    }
}
