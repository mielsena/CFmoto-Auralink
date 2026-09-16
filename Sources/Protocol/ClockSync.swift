// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from the `HuTimeSync` object in BikeProfile.kt and HuQueryTime.kt. The Android app grew an
// elaborate per-bike "ClockLab" testing harness for these two cmds (several firmwares handled empty
// vs. echoed vs. phone-supplied timestamps differently). We only need the *default* behavior that
// its own docs call out as correct for the latest/mainline firmware family (2.0.13): HU_TIME_SYNC
// echoes a sane bike timestamp and only substitutes phone time for an epoch/blank one; HU_QUERY_TIME
// gets an empty ack. If the Aura 150 turns out to need one of the other dialects (see
// docs/01-PROTOCOL-REFERENCE.md §7), extend this file rather than reintroducing the full ClockLab
// knob system — v1 targets one bike, not forty.

import Foundation

/// Builds the ack body for cmd 0x10601 (reply to bike HU_TIME_SYNC, 0x10600).
///
/// Live bike payload (45 bytes): little-endian header `i32 flags(-2) | i32 channel | i32 seq | i32 0`
/// followed by 29 ASCII chars `yyyy-MM-dd HH:mm:ss.SSS000000`. Some firmware sends fewer/zero bytes.
///
/// Strategy (matches the Kotlin default / "echo" mode):
///  - if the request already carries a plausible (non-epoch, non-blank) timestamp → echo the whole
///    payload back unchanged.
///  - otherwise synthesize the phone's local wall-clock time into the same 29-byte field.
/// Never replies empty — an empty ack read as epoch/1970 on some firmware in the original project.
enum HuTimeSync {
    private static let payloadLen = 45
    private static let timeOffset = 16
    private static let timeLen = 29
    private static let stampRegex = try! NSRegularExpression(pattern: #"^(\d{4})-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}"#)

    struct Ack {
        let payload: Data
        let mode: String
        let stamp: String
    }

    static func ack(for request: Data) -> Ack {
        let len = max(payloadLen, request.count)
        var out = [UInt8](repeating: 0, count: len)
        if !request.isEmpty {
            out.replaceSubrange(0..<min(request.count, len), with: [UInt8](request.prefix(len)))
        }
        if request.count < timeOffset {
            var header = Data(capacity: 16)
            header.appendLE(Int32(-2))
            header.appendLE(Int32(0))
            header.appendLE(Int32(1))
            header.appendLE(Int32(0))
            out.replaceSubrange(0..<16, with: [UInt8](header))
        }

        let bikeStamp = extractStamp(Data(out))
        let stamp: String
        let mode: String
        if shouldEcho(bikeStamp, request) {
            stamp = bikeStamp
            mode = "echo"
        } else {
            stamp = phoneStamp()
            mode = "phone"
            let ascii = [UInt8](stamp.utf8)
            let end = min(timeLen, ascii.count)
            out.replaceSubrange(timeOffset..<(timeOffset + end), with: ascii.prefix(end))
        }
        return Ack(payload: Data(out), mode: mode, stamp: stamp)
    }

    static func extractStamp(_ buf: Data) -> String {
        guard buf.count >= timeOffset else { return "" }
        let n = min(timeLen, buf.count - timeOffset)
        let slice = buf.subdata(in: timeOffset..<(timeOffset + n))
        let s = String(data: slice, encoding: .ascii) ?? ""
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}\u{0} ").union(.whitespaces))
    }

    /// Echo unless the bike sent epoch (1969-1971) or blank/all-zero — those still need phone time.
    static func shouldEcho(_ stamp: String, _ request: Data) -> Bool {
        guard request.count >= timeOffset else { return false }
        if stamp.isEmpty || stamp.allSatisfy({ $0 == "\u{0}" || $0 == " " }) { return false }
        let range = NSRange(stamp.startIndex..., in: stamp)
        if let match = stampRegex.firstMatch(in: stamp, range: range),
           let yearRange = Range(match.range(at: 1), in: stamp),
           let year = Int(stamp[yearRange]) {
            if (1969...1971).contains(year) { return false }
        }
        return true
    }

    private static func phoneStamp() -> String {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let ms = Int(now.timeIntervalSince1970 * 1000) % 1000
        return String(format: "%@.%03d000000", f.string(from: now), ms)
    }
}

/// Reply to cmd 0x10450 (HU_QUERY_TIME). Latest mainline firmware default: empty 0x10451 ack.
enum HuQueryTime {
    static func emptyAck() -> Data { Data() }
}
