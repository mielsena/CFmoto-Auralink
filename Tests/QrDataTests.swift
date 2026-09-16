// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.

import Testing
@testable import AuraLink

struct QrDataTests {
    /// Example pairing QR from docs/01-PROTOCOL-REFERENCE.md §1.
    private static let sampleQr = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9" +
        "&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk" +
        "&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457"

    @Test func parsesCarbitPairingUrl() throws {
        let qr = try #require(QrData.parse(Self.sampleQr))
        #expect(qr.ssid == "CFMOTO-f46457")
        #expect(qr.password == "59a9cddc94")
        #expect(qr.auth == "wpa2-psk")
        #expect(qr.mac == "6c:09:4a:0f:6c:f8")
        #expect(qr.name == "CFMOTO-f46457")
        #expect(qr.modelId == "37416")
        #expect(qr.sn == "peTz")
        #expect(qr.action == 9)
        #expect(qr.supportsAp)
    }

    @Test func rejectsEmptyString() {
        #expect(QrData.parse("") == nil)
    }

    @Test func rejectsUrlWithoutSsid() {
        #expect(QrData.parse("http://www.carbit.com.cn/downsdk?modelid=37416&action=9") == nil)
    }

    @Test func rejectsSsidWithoutPassword() {
        #expect(QrData.parse("http://x?ssid=CFMOTO-f46457&action=1") == nil)
    }

    @Test func manualPairingBuildsValidQrData() throws {
        let qr = try #require(QrData.manual(ssid: "CFMOTO-abc123", password: "hunter2"))
        #expect(qr.ssid == "CFMOTO-abc123")
        #expect(qr.password == "hunter2")
        #expect(qr.auth == "wpa2-psk")
        #expect(qr.name == "CFMOTO-abc123")
    }

    @Test func manualPairingRejectsBlankSsidOrPassword() {
        #expect(QrData.manual(ssid: "", password: "hunter2") == nil)
        #expect(QrData.manual(ssid: "CFMOTO-abc123", password: "") == nil)
    }

    @Test func manualPairingUsesDisplayNameWhenProvided() throws {
        let qr = try #require(QrData.manual(ssid: "CFMOTO-abc123", password: "hunter2", displayName: "Aura 150"))
        #expect(qr.name == "Aura 150")
    }
}
