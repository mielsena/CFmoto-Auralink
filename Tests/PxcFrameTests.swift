// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.

import Testing
import Foundation
@testable import AuraLink

struct PxcFrameTests {
    @Test func roundTripEmptyPayload() throws {
        let frame = PxcFrame(cmd: PxcCmd.heartbeatAck)
        let encoded = frame.encoded()
        #expect(encoded.count == 16)
        let (cmd, totalLen) = try PxcFrame.decodeHeader(encoded.prefix(16))
        #expect(cmd == PxcCmd.heartbeatAck)
        #expect(totalLen == 16)
    }

    @Test func roundTripWithJsonPayload() throws {
        let payload = Data(#"{"status":true}"#.utf8)
        let frame = PxcFrame(cmd: PxcCmd.mdnsRespondAck, payload: payload)
        let encoded = frame.encoded()
        #expect(encoded.count == 16 + payload.count)

        let (cmd, totalLen) = try PxcFrame.decodeHeader(encoded.prefix(16))
        #expect(cmd == PxcCmd.mdnsRespondAck)
        #expect(Int(totalLen) == 16 + payload.count)
        let decodedPayload = encoded.suffix(from: 16)
        #expect(decodedPayload == payload)
    }

    @Test func magicIsCmdXorTotalLen() throws {
        let frame = PxcFrame(cmd: PxcCmd.clientInfo, payload: Data([1, 2, 3]))
        let encoded = frame.encoded()
        let magic = encoded.readLE(Int32.self, at: 8)
        let cmd = encoded.readLE(Int32.self, at: 0)
        let totalLen = encoded.readLE(Int32.self, at: 4)
        #expect(magic == (cmd ^ totalLen))
    }

    @Test func decodeHeaderRejectsBadMagic() {
        var header = Data(capacity: 16)
        header.appendLE(PxcCmd.heartbeat)
        header.appendLE(Int32(16))
        header.appendLE(Int32(0xDEAD)) // wrong magic — should be heartbeat ^ 16
        header.appendLE(Int32(0))

        #expect(throws: PxcFrameError.self) {
            _ = try PxcFrame.decodeHeader(header)
        }
    }

    @Test func decodeHeaderRejectsShortHeader() {
        let short = Data([0, 1, 2, 3])
        #expect(throws: PxcFrameError.self) {
            _ = try PxcFrame.decodeHeader(short)
        }
    }

    @Test func cmdHexFormatsAsUnsignedHex() {
        let frame = PxcFrame(cmd: PxcCmd.mdnsRespond)
        #expect(frame.cmdHex == "0x70000010")
    }

    @Test func payloadTextDecodesUtf8() {
        let frame = PxcFrame(cmd: PxcCmd.checkSn, payload: Data(#"{"sn":"abc"}"#.utf8))
        #expect(frame.payloadText == #"{"sn":"abc"}"#)
    }

    @Test func payloadTextIsEmptyForEmptyPayload() {
        let frame = PxcFrame(cmd: PxcCmd.heartbeatAck)
        #expect(frame.payloadText == "")
    }
}
