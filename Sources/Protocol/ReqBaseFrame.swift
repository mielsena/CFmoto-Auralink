// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from the `Protocol.ReqBase` framing used in OpenCfMoto's EasyConnProber.kt (media plane,
// ports :10921/:10920). See docs/01-PROTOCOL-REFERENCE.md §4.

import Foundation

/// 8-byte header used on the media control (:10921) and media data (:10920) sockets.
///
///     offset 0 : cmdType  Int16   (little-endian)
///     offset 2 : cmdLen   UInt16  (body length, little-endian)
///     offset 4 : token    Int32   (little-endian; echoed, not otherwise meaningful to us)
///     body[cmdLen] bytes
struct ReqBaseFrame {
    let cmdType: Int16
    let token: Int32
    let body: Data

    init(cmdType: Int16, token: Int32 = 0, body: Data = Data()) {
        self.cmdType = cmdType
        self.token = token
        self.body = body
    }

    func encoded() -> Data {
        var header = Data(capacity: 8)
        header.appendLE(cmdType)
        header.appendLE(UInt16(truncatingIfNeeded: body.count))
        header.appendLE(Int32(0))
        return header + body
    }

    static func decodeHeader(_ header: Data) throws -> (cmdType: Int16, cmdLen: Int, token: Int32) {
        guard header.count == 8 else { throw ReqBaseFrameError.shortHeader(header.count) }
        let cmdType = header.readLE(Int16.self, at: 0)
        let cmdLen = Int(header.readLE(UInt16.self, at: 2))
        let token = header.readLE(Int32.self, at: 4)
        return (cmdType, cmdLen, token)
    }
}

enum ReqBaseFrameError: Error, CustomStringConvertible {
    case shortHeader(Int)

    var description: String {
        switch self {
        case .shortHeader(let n): return "ReqBaseFrame: header was \(n) bytes, expected 8"
        }
    }
}

/// Media-plane cmdTypes (§4 of the protocol reference). Every one of these is bike→phone; the
/// paired reply cmdType is `request + 1` except the raw frame pull (114), which replies with a raw
/// length-prefixed access unit, not a ReqBase frame at all — see `sendFrameRaw` in EasyConnProber.
enum ReqCmd {
    static let reqRvConfigCapture: Int16 = 16      // → reply 17 (RLY_RV_CONFIG_CAPTURE)
    static let rlyRvConfigCapture: Int16 = 17
    static let reqGetVersion: Int16 = 48           // → reply 49 (two Int32 LE: version, subVersion)
    static let rlyGetVersion: Int16 = 49
    static let reqHeartbeat: Int16 = 64            // → reply 65 (empty)
    static let rlyHeartbeat: Int16 = 65
    static let reqConfigCaptureExtend: Int16 = 96  // → reply 97 (JSON {"state":0})
    static let rlyConfigCaptureExtend: Int16 = 97
    static let reqRvDataStart: Int16 = 112         // → reply 113 (empty) — "start the encoder now"
    static let rlyRvDataStart: Int16 = 113
    static let reqRvDataNext: Int16 = 114          // on the data socket (:10920) — reply is a raw frame
    static let reqTouch: Int16 = 32                // dash touchscreen event (unused: CFDL16 is non-touch)
}

/// REQ_RV_CONFIG_CAPTURE (16) body — little-endian, from the bike's requested capture config.
struct RvConfigCaptureRequest {
    let deviceWidth: Int
    let deviceHeight: Int
    let wantFps: Int32
    let wantEncoder: Int32
    let encryptedHUID: String

    /// Parses as much of the body as is present — the Android app tolerates a short/legacy body by
    /// reading only the fields available, so we do too (guarded reads, no force-unwraps).
    static func parse(_ body: Data) -> RvConfigCaptureRequest {
        let w = body.count >= 2 ? Int(body.readLE(UInt16.self, at: 0)) : 0
        let h = body.count >= 4 ? Int(body.readLE(UInt16.self, at: 2)) : 0
        let fps = body.count >= 8 ? body.readLE(Int32.self, at: 4) : 0
        let encoder = body.count >= 12 ? body.readLE(Int32.self, at: 8) : 2
        var huid = ""
        if body.count > 30 {
            huid = String(data: body.suffix(from: 30), encoding: .utf8) ?? ""
        }
        return RvConfigCaptureRequest(deviceWidth: w, deviceHeight: h, wantFps: fps, wantEncoder: encoder, encryptedHUID: huid)
    }
}

/// RLY_RV_CONFIG_CAPTURE (17) reply body — encoder(i32) | width&~15(s16) | height&~15(s16) | ext(u8).
struct RvConfigCaptureReply {
    let encoder: Int32
    let captureWidth: Int
    let captureHeight: Int
    let supportExtendProtocol: UInt8

    func encoded() -> Data {
        var d = Data(capacity: 9)
        d.appendLE(encoder)
        d.appendLE(Int16(truncatingIfNeeded: captureWidth))
        d.appendLE(Int16(truncatingIfNeeded: captureHeight))
        d.append(supportExtendProtocol)
        return d
    }
}
