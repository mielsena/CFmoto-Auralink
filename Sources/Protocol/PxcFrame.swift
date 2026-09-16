// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from OpenCfMoto's PxcFrame.kt. Cmd IDs and framing verified live against a CFDL16-class
// dash (cfmoto-tcp-v5.log, see ../../docs/01-PROTOCOL-REFERENCE.md and
// ../../reference/android-docs/01-REVERSE-ENGINEERING.md). Treat every constant here as confirmed
// against real hardware, not a guess — do not "clean up" values that look redundant.

import Foundation

/// 16-byte CmdBaseHead frame used on the PXC control socket (:10922) and the one-shot probe to the
/// bike's :10930 endpoint.
///
///     offset  0 : cmd       Int32  (little-endian)
///     offset  4 : totalLen  Int32  (= 16 + payload.count)
///     offset  8 : magic     Int32  (= cmd ^ totalLen — the bike DROPS the connection on mismatch)
///     offset 12 : reserved  Int32  (always 0 on write; ignored on read)
///     payload[totalLen - 16] bytes (usually UTF-8 JSON; empty for most acks)
struct PxcFrame {
    let cmd: Int32
    let payload: Data

    init(cmd: Int32, payload: Data = Data()) {
        self.cmd = cmd
        self.payload = payload
    }

    var cmdHex: String { "0x" + String(UInt32(bitPattern: cmd), radix: 16) }

    /// UTF-8 decode of the payload for logging; never throws (mirrors the Kotlin `asText()` helper).
    var payloadText: String {
        guard !payload.isEmpty else { return "" }
        return String(data: payload, encoding: .utf8) ?? "<\(payload.count)b>"
    }

    func encoded() -> Data {
        let totalLen = Int32(16 + payload.count)
        let magic = cmd ^ totalLen
        var header = Data(capacity: 16)
        header.appendLE(cmd)
        header.appendLE(totalLen)
        header.appendLE(magic)
        header.appendLE(Int32(0))
        return header + payload
    }

    /// Validates a 16-byte header and returns (cmd, totalLen). Throws on a magic mismatch — the
    /// caller must close the connection, exactly like the bike would.
    static func decodeHeader(_ header: Data) throws -> (cmd: Int32, totalLen: Int32) {
        guard header.count == 16 else { throw PxcFrameError.shortHeader(header.count) }
        let cmd = header.readLE(Int32.self, at: 0)
        let totalLen = header.readLE(Int32.self, at: 4)
        let magic = header.readLE(Int32.self, at: 8)
        guard (cmd ^ totalLen) == magic else {
            throw PxcFrameError.badMagic(cmd: cmd, totalLen: totalLen, magic: magic)
        }
        return (cmd, totalLen)
    }
}

enum PxcFrameError: Error, CustomStringConvertible {
    case shortHeader(Int)
    case badMagic(cmd: Int32, totalLen: Int32, magic: Int32)

    var description: String {
        switch self {
        case .shortHeader(let n):
            return "PxcFrame: header was \(n) bytes, expected 16"
        case .badMagic(let cmd, let totalLen, let magic):
            return "PxcFrame: bad magic cmd=\(cmd) len=\(totalLen) magic=\(magic)"
        }
    }
}

/// PXC / EasyConn command IDs. Names and comments mirror `PxcFrame.Companion` in the Kotlin
/// source verbatim — the comments are the verification history, not decoration.
enum PxcCmd {
    // ---- Channel-selection cmds. First frame on a fresh :10922 socket selects which PXC channel
    // this connection belongs to. Server (phone) echoes back channelId+1 on accept. ----
    static let channelCarCtrl: Int32 = 0x10000   // ack = 0x10001
    static let channelCarData: Int32 = 0x20000   // ack = 0x20001
    static let channelRvCtrl: Int32 = 0x30000    // ack = 0x30001 — Carbit "RV" (regular bike), unused by CFDL16
    static let channelRvData: Int32 = 0x40000    // ack = 0x40001

    // ---- Standard Car PXC — the protocol the CFDL16-class dash (and presumed Aura 150) uses. ----
    // Verified live in cfmoto-tcp-v5.log. Phone = server; bike connects back & sends these.
    static let mdnsRespond: Int32 = 0x70000010       // phone→bike probe on :10930 (JSON); ack 0x70000011
    static let mdnsRespondAck: Int32 = 0x70000011    // bike→phone {"status":true|false}
    static let heartbeat: Int32 = 0x70000000         // ↔ ack = 0x70000001
    static let heartbeatAck: Int32 = 0x70000001
    static let clientInfo: Int32 = 0x10010           // C2P (both directions)
    static let clientInfoReply: Int32 = 0x10011      // phone→bike reply to CLIENT_INFO
    static let querySpeed: Int32 = 0x10690           // bike→phone {usbSpeed,wifiSpeed}; reply 0x10691
    static let querySpeedReply: Int32 = 0x10691
    static let checkSn: Int32 = 0x103e0              // bike→phone {client_set,sn}; reply 0x103e1 + result
    static let checkSnAck: Int32 = 0x103e1
    static let checkSnResult: Int32 = 0x201c0        // phone→bike {isOk,...}; bike acks 0x201c1
    static let checkSnResultAck: Int32 = 0x201c1

    // Bike wall-clock / keepalive (~2s). Payload: 16-byte header + 29 ASCII "yyyy-MM-dd HH:mm:ss.SSS000000".
    static let huTimeSync: Int32 = 0x10600
    static let huTimeSyncAck: Int32 = 0x10601
    // ECP_C2P_QUERY_TIME — bike asks for wall clock (often empty). Empty 0x10451 is the safe default.
    static let huQueryTime: Int32 = 0x10450
    static let huQueryTimeAck: Int32 = 0x10451

    // Post-CHECK_SN notify burst some CFDL16/CFDL26-family units send before opening media ports.
    // The Android app found these MUST be acked cmd+1 (empty) or the bike never opens the media
    // sockets — see BikeProfile.handleUnknownControl. Likely N/A for a clean Aura 150 connect but
    // kept so an unexpected frame gets a safe, generic ack instead of stalling the link.
    static let logReport: Int32 = 0x10780            // CFDL26-family log/report JSON
    static let logReportAck: Int32 = 0x10781
    static let otaFtpInfo: Int32 = 0x103a0           // {port,userName,pwd} for OTA FTP server
    static let mediaFeatureCfg: Int32 = 0x10020      // {music,talkie,tts,vr,autoChangeToBT}
    static let sockServerInfo: Int32 = 0x104a0
    static let sockServerInfoAck: Int32 = 0x104a1

    static func name(of cmd: Int32) -> String {
        switch cmd {
        case logReport: return "LOG_REPORT"
        case logReportAck: return "LOG_REPORT_ACK"
        case otaFtpInfo: return "OTA_FTP_INFO"
        case mediaFeatureCfg: return "MEDIA_FEATURE_CFG"
        case sockServerInfo: return "SOCK_SERVER_INFO"
        case sockServerInfoAck: return "SOCK_SERVER_INFO_ACK"
        case huTimeSync: return "HU_TIME_SYNC"
        case huTimeSyncAck: return "HU_TIME_SYNC_ACK"
        case huQueryTime: return "HU_QUERY_TIME"
        case huQueryTimeAck: return "HU_QUERY_TIME_ACK"
        case clientInfo: return "CLIENT_INFO"
        case clientInfoReply: return "CLIENT_INFO_REPLY"
        case checkSn: return "CHECK_SN"
        case checkSnResult: return "CHECK_SN_RESULT"
        case channelCarCtrl: return "CHANNEL_CAR_CTRL"
        case channelCarData: return "CHANNEL_CAR_DATA"
        case heartbeat: return "HEARTBEAT"
        case heartbeatAck: return "HEARTBEAT_ACK"
        case mdnsRespond: return "MDNS_RESPOND"
        case mdnsRespondAck: return "MDNS_RESPOND_ACK"
        case querySpeed: return "QUERY_SPEED"
        case querySpeedReply: return "QUERY_SPEED_REPLY"
        default: return "?"
        }
    }
}

// MARK: - Little-endian byte helpers shared by PxcFrame / ReqBaseFrame.

extension Data {
    // NOTE: `Swift.` qualification is required here, not decorative — inside `extension Data`, a
    // bare `withUnsafeBytes(of:)` resolves to `Data`'s own `withUnsafeBytes(_:)` instance method
    // (which reads THIS Data's bytes, wrong arity/meaning) instead of the global
    // `Swift.withUnsafeBytes(of:_:)` we actually want (bytes of the local `var v`). Confirmed via
    // `swiftc -typecheck` — dropping the qualifier fails to compile with an ambiguity error.
    mutating func appendLE(_ value: Int32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Int16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// Reads a fixed-width little-endian integer at `offset`. Callers are expected to have already
    /// validated `count`; this traps (like an out-of-bounds array access) on malformed input rather
    /// than silently returning garbage.
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        precondition(offset + size <= count, "readLE out of range: offset=\(offset) size=\(size) count=\(count)")
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest, from: offset..<(offset + size))
        }
        return T(littleEndian: value)
    }
}
