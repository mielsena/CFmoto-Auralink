// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Minimal slice of BikeMemory.kt for Phase 1: just enough to reconnect to the one bike Miel owns
// without re-scanning the QR every session. The real BikeMemory.kt also tracks per-SSID learned
// panel geometry across a multi-bike Garage — that's Phase 6 scope (docs/02-IOS-ARCHITECTURE-PLAN.md
// lists `BikeMemory.swift` under Models there too); this deliberately-small version exists so the
// Phase 1 networking/reconnect path has somewhere to persist/read the last-joined bike.

import Foundation

struct RememberedBike: Codable, Equatable {
    let ssid: String
    let password: String
    let auth: String?
    let mac: String?
    let name: String?
    let modelId: String?
}

enum BikeMemory {
    private static let key = "com.amielsena.auralink.lastBike"

    static func save(_ qr: QrData) {
        let remembered = RememberedBike(
            ssid: qr.ssid, password: qr.password, auth: qr.auth,
            mac: qr.mac, name: qr.name, modelId: qr.modelId
        )
        guard let data = try? JSONEncoder().encode(remembered) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func lastBike() -> RememberedBike? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RememberedBike.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
