// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// JSON shapes for cmd 0x10010 (CLIENT_INFO). See docs/01-PROTOCOL-REFERENCE.md §3 step 3 for the
// exact field set the phone must reply with, and BikeProfile.kt's `basePhoneClientInfo` (Kotlin
// ground truth) for field ordering/defaults.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The bike's CLIENT_INFO payload (cmd 0x10010). Field names/casing vary slightly across bike
/// firmware (`HUID` vs `huid`, etc.), so this wraps a loosely-typed JSON object with
/// `optString`/`optBool`-style accessors instead of a strict `Decodable`, mirroring how the Kotlin
/// side reads `org.json.JSONObject` defensively.
/// `@unchecked Sendable`: `raw` holds JSONSerialization output (NSString/NSNumber/NSNull/etc.), which
/// is immutable value data in practice even though `Any` isn't statically `Sendable`. Safe to pass
/// across the `PxcHandshake` actor boundary as a snapshot of one CLIENT_INFO frame.
struct BikeClientInfo: @unchecked Sendable {
    let raw: [String: Any]
    let rawText: String

    static func parse(_ data: Data) -> BikeClientInfo? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BikeClientInfo(raw: [:], rawText: text)
        }
        return BikeClientInfo(raw: obj, rawText: text)
    }

    func string(_ key: String) -> String {
        (raw[key] as? String) ?? ""
    }

    func bool(_ key: String, default def: Bool = false) -> Bool {
        (raw[key] as? Bool) ?? def
    }

    func int(_ key: String, default def: Int = 0) -> Int {
        if let n = raw[key] as? Int { return n }
        if let n = raw[key] as? NSNumber { return n.intValue }
        return def
    }

    /// Bike's HUID — case varies (`HUID` on most units, lowercase `huid` seen on some).
    var huid: String? {
        let v = string("HUID")
        return v.isEmpty ? (string("huid").isEmpty ? nil : string("huid")) : v
    }

    var huName: String { string("HUName") }
    var channel: String { string("channel") }
    var sdkVersion: String { string("sdkVersion") }
    var flavor: String { string("flavor") }
    var packageName: String { string("package_name") }
    var versionName: String { string("version_name") }
    var supportScreenTouch: Bool { bool("supportScreenTouch") }
    var socketTimeoutPeriodWifi: Int { int("socketTimeoutPeriodWifi", default: 9) }
}

/// What the phone sends back as its own CLIENT_INFO (cmd 0x10011). Field order matches the Kotlin
/// `basePhoneClientInfo` so a byte-diff against a known-good Android capture stays meaningful.
struct PhoneClientInfo: Encodable {
    var pxcVersion = "1.0.2"
    let phoneUUID: String
    var phoneBrand = "Apple"
    let phoneModel: String
    let phoneOsVersion: String
    var phoneOs = "iOS"
    let package: String
    var versionCode = 1
    var token = 0
    let pubkey: String
    let encryptedHUID: String
    var bluetoothName = "AuraLink"
    var supportH264IFrame = true
    var supportFunction: Int
    /// Deliberately false — the Kotlin app found that claiming this made some firmware apply the
    /// HU_TIME_SYNC ack aggressively (jumping the dash clock even when it was already correct). We
    /// still answer every HU_TIME_SYNC (see ClockSync.swift) so a bike that needs it is unaffected.
    var supportSyncCorrectTime = false
    var appVersionFingerPrint = "auralink-1"
    /// Only emitted when true (some profiles only claim touch when the rider forces it) — see
    /// `encode(to:)`.
    var supportScreenTouch: Bool?

    enum CodingKeys: String, CodingKey {
        case pxcVersion, phoneUUID, phoneBrand, phoneModel, phoneOsVersion, phoneOs, package
        case versionCode, token, pubkey, encryptedHUID, bluetoothName, supportH264IFrame
        case supportFunction, supportSyncCorrectTime, appVersionFingerPrint, supportScreenTouch
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pxcVersion, forKey: .pxcVersion)
        try c.encode(phoneUUID, forKey: .phoneUUID)
        try c.encode(phoneBrand, forKey: .phoneBrand)
        try c.encode(phoneModel, forKey: .phoneModel)
        try c.encode(phoneOsVersion, forKey: .phoneOsVersion)
        try c.encode(phoneOs, forKey: .phoneOs)
        try c.encode(package, forKey: .package)
        try c.encode(versionCode, forKey: .versionCode)
        try c.encode(token, forKey: .token)
        try c.encode(pubkey, forKey: .pubkey)
        try c.encode(encryptedHUID, forKey: .encryptedHUID)
        try c.encode(bluetoothName, forKey: .bluetoothName)
        try c.encode(supportH264IFrame, forKey: .supportH264IFrame)
        try c.encode(supportFunction, forKey: .supportFunction)
        try c.encode(supportSyncCorrectTime, forKey: .supportSyncCorrectTime)
        try c.encode(appVersionFingerPrint, forKey: .appVersionFingerPrint)
        if let t = supportScreenTouch, t {
            try c.encode(t, forKey: .supportScreenTouch)
        }
    }

    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Builds the reply for a given bike HUID (nil if CLIENT_INFO carried none) and our persistent
    /// phone UUID. `supportFunction`/`supportScreenTouch` come from the active `BikeProfile`.
    static func build(
        huid: String?,
        phoneUUID: String,
        supportFunction: Int,
        advertiseTouch: Bool
    ) -> PhoneClientInfo {
        let encryptedHUID = huid.flatMap { try? RsaKeys.shared.signHuid($0) } ?? ""
        return PhoneClientInfo(
            phoneUUID: phoneUUID,
            phoneModel: devicePhoneModel(),
            phoneOsVersion: deviceOsVersion(),
            package: Bundle.main.bundleIdentifier ?? "com.amielsena.auralink",
            pubkey: RsaKeys.shared.publicKeyBase64,
            encryptedHUID: encryptedHUID,
            supportFunction: supportFunction,
            supportScreenTouch: advertiseTouch ? true : nil
        )
    }

    private static func devicePhoneModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "iPhone"
        #endif
    }

    private static func deviceOsVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
