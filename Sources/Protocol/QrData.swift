// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from QrData.kt, trimmed to the Carbit/EasyConnect SoftAP QR shape documented in
// docs/01-PROTOCOL-REFERENCE.md §1 — the format the Aura 150's dash is expected to show. The
// Android app also handles Moto Morini/Thinkerride/phone-hotspot/Wi-Fi-Direct QR dialects for its
// 40+ supported bikes; those are out of scope for v1 (CFDL16/Aura 150 only, AP mode only — see
// docs/00-README-HANDOFF.md ground rules). Add them back here if a later bike needs them.

import Foundation

/// Parsed pairing QR shown on the bike's dash — a URL whose query string carries the bike's SoftAP
/// Wi-Fi credentials and coarse identity.
struct QrData: Equatable {
    let ssid: String
    let password: String
    let auth: String?
    let mac: String?
    let name: String?
    /// Bitmask: bit0 = AP, bit1 = AP+internet, bit3 = P2P/Wi-Fi-Direct, bit6 = BT. v1 only ever
    /// joins via AP (bit0), so this is retained for logging/diagnostics, not branching.
    let action: Int
    let modelId: String?
    /// Random nonce that changes every scan — not used in the connection flow.
    let sn: String?
    let channel: String?

    var supportsAp: Bool { (action & 1) != 0 || (action & 2) != 0 }

    /// Parses the Carbit/EasyConnect query-string QR:
    ///   http://www.carbit.com.cn/downsdk/...?modelid=37416&sn=...&action=9
    ///     &ssid=CFMOTO-f46457&pwd=...&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457
    static func parse(_ raw: String) -> QrData? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let query = queryParams(trimmed)
        let ssid = (query["ssid"] ?? "").trimmingCharacters(in: .whitespaces)
        let pwd = query["pwd"] ?? ""
        guard !ssid.isEmpty, !pwd.isEmpty else { return nil }
        let action = Int(query["action"] ?? "") ?? 0
        return QrData(
            ssid: ssid,
            password: pwd,
            auth: query["auth"],
            mac: formatMac(query["mac"]),
            name: query["name"]?.isEmpty == false ? query["name"] : nil,
            action: action,
            modelId: query["modelid"],
            sn: query["sn"],
            channel: query["channel"]
        )
    }

    /// Query map from a URL (before any `#` fragment). Keys are lower-cased, values percent-decoded.
    private static func queryParams(_ raw: String) -> [String: String] {
        let query = raw
            .split(separator: "?", maxSplits: 1).last.map(String.init) ?? ""
        let beforeFragment = query.split(separator: "#", maxSplits: 1).first.map(String.init) ?? query
        guard !beforeFragment.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for part in beforeFragment.split(separator: "&") {
            guard !part.isEmpty else { continue }
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard let key = pieces.first, !key.isEmpty else { continue }
            let rawValue = pieces.count > 1 ? String(pieces[1]) : ""
            let value = rawValue.removingPercentEncoding ?? rawValue
            out[key.lowercased()] = value
        }
        return out
    }

    /// "aabbccddeeff" / "aa:bb:…" → colon form; nil if not recognizable as a MAC.
    private static func formatMac(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let hex = raw.filter { $0.isHexDigit }
        if hex.count == 12 {
            var out: [String] = []
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2)
                out.append(String(hex[idx..<next]).lowercased())
                idx = next
            }
            return out.joined(separator: ":")
        }
        return raw.contains(":") && raw.count >= 11 ? raw : nil
    }

    /// Synthesizes a `QrData` for manual SSID/password entry (Garage screen "add bike manually"),
    /// for dashes that print SSID+password directly instead of a scannable QR.
    static func manual(ssid: String, password: String, displayName: String? = nil) -> QrData? {
        let s = ssid.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !password.isEmpty else { return nil }
        let name = displayName?.trimmingCharacters(in: .whitespaces)
        return QrData(
            ssid: s,
            password: password,
            auth: "wpa2-psk",
            mac: nil,
            name: (name?.isEmpty == false) ? name : s,
            action: 1,
            modelId: nil,
            sn: nil,
            channel: nil
        )
    }
}
