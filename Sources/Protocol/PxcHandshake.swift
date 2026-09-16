// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from PxcHandshake.kt. Server-side PXC control dispatcher: the phone is the SERVER — after
// EasyConnProber sends the ECP_PXC_MDNS_RESPOND probe to the bike, the bike connects back to our
// listening ports and drives the handshake; we only ever reply per-cmd. See
// docs/01-PROTOCOL-REFERENCE.md §3 for the full confirmed sequence.
//
// Verified against cfmoto-tcp-v5.log (Kotlin ground truth):
//   bike 0x10000 (CAR_CTRL select)   -> we 0x10001
//   bike 0x20000 (CAR_DATA select)   -> we 0x20001
//   bike 0x10010 CLIENT_INFO (JSON)  -> we 0x10011 (our info + RSA pubkey + signed HUID)
//   bike 0x10690 {usbSpeed,wifiSpeed}-> we 0x10691
//   bike 0x103e0 {client_set,sn}     -> we 0x103e1, then we proactively send 0x201c0 {isOk:true}
//   bike 0x70000000 heartbeat        -> we 0x70000001
//
// An `actor` because CAR_CTRL and CAR_DATA arrive on two independent sockets/Tasks but both mutate
// shared state (`profile`, `carHuid`, `lastClientInfo`) — the actor serializes that for free instead
// of hand-rolling a lock, matching the project's "async/await, not manual thread-safety" convention.

import Foundation

actor PxcHandshake {

    /// What the caller (EasyConnProber) should do after `handle(...)` returns.
    struct Outcome: Sendable {
        /// Frames to write back to the SAME socket the inbound frame arrived on, in order.
        let replies: [PxcFrame]
        /// Set when this frame was a channel-select (CAR_CTRL/CAR_DATA) — the caller should start a
        /// proactive 2s heartbeat sender on this socket. See docs/01-PROTOCOL-REFERENCE.md §3 step 5:
        /// leaving EITHER channel socket unheartbeated caused a real 800NK-family ~7s disconnect flap
        /// in the Android app, so heartbeat both, unconditionally, not just on CAR_CTRL.
        let channelSelected: String?

        static func reply(_ frames: PxcFrame...) -> Outcome { Outcome(replies: frames, channelSelected: nil) }
        static func channel(_ frame: PxcFrame, name: String) -> Outcome { Outcome(replies: [frame], channelSelected: name) }
        static let none = Outcome(replies: [], channelSelected: nil)
    }

    private let phoneUUID: String
    private(set) var carHuid: String?
    private(set) var lastClientInfo: BikeClientInfo?
    private(set) var profile: BikeProfile = BikeProfiles.default

    init(phoneUUID: String = PxcHandshake.persistentPhoneUUID()) {
        self.phoneUUID = phoneUUID
    }

    /// Dispatch one inbound control-plane frame. `tag` is a short label for log lines (e.g. ":10922").
    func handle(tag: String, frame: PxcFrame) async -> Outcome {
        switch frame.cmd {
        case PxcCmd.channelCarCtrl:
            await LogBus.shared.log("[\(tag)] bike selected CAR_CTRL (0x10000) → ack 0x10001")
            return .channel(PxcFrame(cmd: PxcCmd.channelCarCtrl &+ 1), name: "CAR_CTRL")

        case PxcCmd.channelCarData:
            await LogBus.shared.log("[\(tag)] bike selected CAR_DATA (0x20000) → ack 0x20001")
            return .channel(PxcFrame(cmd: PxcCmd.channelCarData &+ 1), name: "CAR_DATA")

        case PxcCmd.clientInfo:
            return await onClientInfo(tag: tag, frame: frame)

        case PxcCmd.querySpeed:
            await LogBus.shared.log("[\(tag)] QUERY_SPEED \(frame.payloadText) → reply 0x10691")
            return .reply(PxcFrame(cmd: PxcCmd.querySpeedReply))

        case PxcCmd.checkSn:
            return await onCheckSn(tag: tag, frame: frame)

        case PxcCmd.heartbeat:
            return .reply(PxcFrame(cmd: PxcCmd.heartbeatAck))

        case PxcCmd.heartbeatAck, PxcCmd.checkSnResultAck:
            return .none // acks from the bike — nothing to do

        case PxcCmd.huTimeSync:
            return await onHuTimeSync(tag: tag, frame: frame)

        case PxcCmd.huQueryTime:
            await LogBus.shared.log("[\(tag)] HU_QUERY_TIME (0x10450) len=\(frame.payload.count) → 0x10451 empty")
            return .reply(PxcFrame(cmd: PxcCmd.huQueryTimeAck, payload: HuQueryTime.emptyAck()))

        default:
            if let reply = profile.handleUnknownControl(cmd: frame.cmd, payload: frame.payload) {
                await LogBus.shared.log(
                    "[\(tag)] cmd=\(frame.cmdHex) (\(PxcCmd.name(of: frame.cmd))) len=\(frame.payload.count) "
                        + "\(frame.payloadText) → ack \(reply.cmdHex)"
                )
                return .reply(reply)
            }
            await LogBus.shared.log(
                "[\(tag)] cmd=\(frame.cmdHex) (\(PxcCmd.name(of: frame.cmd))) len=\(frame.payload.count) \(frame.payloadText)"
            )
            return .none
        }
    }

    private func onClientInfo(tag: String, frame: PxcFrame) async -> Outcome {
        let text = frame.payloadText
        await LogBus.shared.log("[\(tag)] *** CLIENT_INFO from bike *** \(text)")
        guard let info = BikeClientInfo.parse(frame.payload) else {
            await LogBus.shared.log("[\(tag)] CLIENT_INFO parse failed — no valid JSON in payload")
            return .none
        }
        lastClientInfo = info
        carHuid = info.huid
        await LogBus.shared.log("[\(tag)] carHuid=\(carHuid ?? "nil") HUName=\(info.huName) channel=\(info.channel) sdkVersion=\(info.sdkVersion)")

        let (selected, scoreLog) = BikeProfiles.select(info)
        await LogBus.shared.log(scoreLog)
        profile = selected
        await LogBus.shared.log("[\(tag)] *** BikeProfile selected: \(selected.name) ***")

        let reply = PhoneClientInfo.build(
            huid: carHuid,
            phoneUUID: phoneUUID,
            supportFunction: selected.advertisedSupportFunction,
            advertiseTouch: selected.supportsScreenTouch
        )
        let json: Data
        do {
            json = try reply.jsonData()
        } catch {
            await LogBus.shared.log("[\(tag)] CLIENT_INFO reply encode failed: \(error) — sending empty reply")
            json = Data()
        }
        let preview = String(data: json, encoding: .utf8).map { String($0.prefix(180)) } ?? ""
        await LogBus.shared.log("[\(tag)] → CLIENT_INFO reply \(preview)…")
        return .reply(PxcFrame(cmd: PxcCmd.clientInfoReply, payload: json))
    }

    private func onCheckSn(tag: String, frame: PxcFrame) async -> Outcome {
        let text = frame.payloadText
        await LogBus.shared.log("[\(tag)] CHECK_SN from bike: \(text)")
        let sn: String
        if let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] {
            sn = (obj["sn"] as? String) ?? ""
        } else {
            sn = ""
        }
        let ack = PxcFrame(cmd: PxcCmd.checkSnAck)
        let resultObj: [String: Any] = ["isOk": true, "errCode": 0, "errMsg": "", "id": sn, "client_set": "easy_conn"]
        let resultData = (try? JSONSerialization.data(withJSONObject: resultObj)) ?? Data()
        await LogBus.shared.log("[\(tag)] → CHECK_SN_RESULT \(String(data: resultData, encoding: .utf8) ?? "")")
        return Outcome(replies: [ack, PxcFrame(cmd: PxcCmd.checkSnResult, payload: resultData)], channelSelected: nil)
    }

    private func onHuTimeSync(tag: String, frame: PxcFrame) async -> Outcome {
        let ack = HuTimeSync.ack(for: frame.payload)
        await LogBus.shared.log("[\(tag)] HU_TIME_SYNC len=\(frame.payload.count) → ack 0x10601 mode=\(ack.mode) time=\(ack.stamp)")
        return .reply(PxcFrame(cmd: PxcCmd.huTimeSyncAck, payload: ack.payload))
    }

    /// Per-install phone UUID, generated once and persisted — the Kotlin app generates a fresh
    /// `UUID.randomUUID()` per PROCESS (not persisted); we persist instead since the protocol field
    /// is explicitly documented as "generate+persist per install" in docs/01-PROTOCOL-REFERENCE.md §3.
    /// A full `AppSettings` (Phase 6) will likely own this key instead — left here as a self-contained
    /// default so PxcHandshake has no dependency on a not-yet-written settings module.
    static func persistentPhoneUUID() -> String {
        let key = "com.amielsena.auralink.phoneUUID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
