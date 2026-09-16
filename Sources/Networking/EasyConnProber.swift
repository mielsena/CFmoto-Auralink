// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ported from EasyConnProber.kt, trimmed to the v1 scope docs/00-README-HANDOFF.md and
// docs/04-CONTINUE-HANDOFF.md call for: one non-touch AP-mode CFDL16 bike, not the Android app's
// 40-bike matrix. Deliberately NOT ported: touch-ghost-filtering (Aura 150 is non-touch), Wi-Fi
// Direct P2P, VPN-kill-switch detection, and the Yunmo SoftAP fallback (X-Cape/Moto Morini only).
// Kept because they're load-bearing, field-tested fixes even for a single bike: the reconnect/
// backoff constants, and — critically — the dual proactive heartbeat on BOTH :10922 channel
// sockets (CAR_CTRL and CAR_DATA), which fixed a real ~7s disconnect flap on 800NK-family units in
// the Android app. See docs/01-PROTOCOL-REFERENCE.md §2-3 for the topology/handshake this
// orchestrates.
//
// mDNS discovery (`_EasyConn._tcp.local.`) is deliberately NOT implemented for v1 — the protocol
// doc explicitly permits skipping it ("don't make mDNS a hard dependency"); this file only ever
// uses the documented fallback (gateway IP + port 10930 directly). Revisit only if the Aura 150's
// real firmware turns out to need mDNS (unlikely per docs/01-PROTOCOL-REFERENCE.md §2).

import Foundation
import Network
import Darwin

/// Feeds encoded video frames to the bike's data-pull loop (cmdType 112/114). `VideoPipeline`
/// (Phase 2) will conform to this — `EasyConnProber` has no video-pipeline dependency of its own,
/// just this seam, so Phase 1 (control-plane only, "no video yet") builds and is testable on real
/// hardware before Phase 2 exists.
protocol BikeVideoSource: Sendable {
    /// REQ_RV_CONFIG_CAPTURE (16): the bike told us its requested canvas; the profile-rounded
    /// width/height is what the encoder should actually target (docs/01-PROTOCOL-REFERENCE.md §4 —
    /// "this is where the ACTUAL encoder resolution gets decided"). The tuning params come from the
    /// active `BikeProfile` (`handshake.profile`), not hardcoded here, so a future non-CFDL16
    /// profile's different bitrate/fps/keyframe interval flows through automatically.
    func configureCanvas(
        width: Int, height: Int, bitrate: Int, frameRate: Int,
        keyframeIntervalSeconds: Int, forceBaseline: Bool
    ) async
    /// REQ_RV_DATA_START (112): the bike is about to start pulling frames. Make sure the very next
    /// one is a fresh keyframe (SPS/PPS + IDR) so a cold-starting decoder locks on immediately.
    func onBikeDataStart() async
    /// REQ_RV_DATA_NEXT (114): return one Annex-B access unit, or `nil` if none became ready within
    /// `timeout`.
    func pollFrame(timeout: Duration) async -> Data?
}

actor EasyConnProber {
    static let portPxcCtrl: UInt16 = 10922    // PXC control: CmdBaseHead framing
    static let portMediaCtrl: UInt16 = 10921  // media control: ReqBase framing
    static let portMediaData: UInt16 = 10920  // media data: ReqBase framing, raw frame replies
    static let bikeProbePort: UInt16 = 10930  // bike's one-shot probe/mDNS endpoint

    /// Cap before giving up and surfacing `.error` — resets to 0 on any fresh accepted connection.
    /// Matches Kotlin `MAX_RECONNECT_ATTEMPTS`.
    private static let maxReconnectAttempts = 20
    /// Proactive heartbeat interval on each live :10922 channel socket. Matches Kotlin
    /// `PXC_HEARTBEAT_INTERVAL_MS` — this is the fix for the 800NK-family ~7s flap, not a tunable.
    private static let heartbeatInterval: Duration = .seconds(2)

    private let handshake = PxcHandshake()
    private var servers: [PxcTcpServer] = []
    private var videoSource: BikeVideoSource?

    private var running = false
    private var probed = false
    private var everConnected = false
    private var reconnectAttempts = 0
    private var reprobing = false
    private var liveConnectionCount = 0
    private var negotiatedWidth = 800
    private var negotiatedHeight = 384
    private var framesSent = 0
    private var lastFrameAt: Date?

    private var myIP: String?
    private var bikeIP: String?

    private var heartbeatTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var readLoopTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var probeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// True once at least one frame has been delivered to the dash this session.
    var isStreaming: Bool { framesSent > 0 }

    /// Seconds since the last frame was sent (`nil` if none yet) — for the Phase 4 watchdog.
    func secondsSinceLastFrame() -> Double? {
        guard let lastFrameAt else { return nil }
        return Date().timeIntervalSince(lastFrameAt)
    }

    func attach(videoSource: BikeVideoSource?) {
        self.videoSource = videoSource
    }

    /// Joins the bike's control-plane. Assumes the phone is ALREADY associated with the bike's
    /// Wi-Fi AP (see `BikeWifiManager`) — this only handles the PXC/EasyConn side: resolve our IP +
    /// the bike's gateway IP, open the three listeners, then probe.
    func start() async {
        if running {
            await LogBus.shared.log("[PXC] already running — restarting cleanly")
            await stopInternal()
        }
        probed = false
        everConnected = false
        reconnectAttempts = 0
        liveConnectionCount = 0
        framesSent = 0
        lastFrameAt = nil

        guard let (ip, netmask) = await resolveWifiAddressWithRetry() else {
            await LogBus.shared.log("[PXC] could not resolve our IPv4 on the bike Wi-Fi — aborting")
            await ConnectionState.shared.set(.error, detail: "no IP on bike Wi-Fi")
            return
        }
        guard let gateway = Self.gatewayAddress(ip: ip, netmask: netmask) else {
            await LogBus.shared.log("[PXC] could not derive bike gateway IP from \(ip)/\(netmask) — aborting")
            await ConnectionState.shared.set(.error, detail: "no bike gateway")
            return
        }
        myIP = ip
        bikeIP = gateway
        await LogBus.shared.log("[PXC] our IP=\(ip) bike IP=\(gateway)")

        running = true

        do {
            try startListeners(localAddress: ip)
        } catch {
            await LogBus.shared.log("[PXC] !! \(error)")
            await ConnectionState.shared.set(.error, detail: "\(error)")
            await stopInternal()
            return
        }
        await LogBus.shared.log(
            "[PXC] listening on \(ip) ports [\(Self.portPxcCtrl), \(Self.portMediaCtrl), \(Self.portMediaData)]"
        )

        await ConnectionState.shared.set(.pxcConnecting)
        probeTask = Task { [weak self] in
            await self?.probeAndAwaitCallback(bikeIP: gateway)
        }
    }

    func stop() async {
        await stopInternal()
        await ConnectionState.shared.set(.stopped)
    }

    private func stopInternal() async {
        running = false
        probed = false
        everConnected = false
        reprobing = false
        probeTask?.cancel(); probeTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        for task in heartbeatTasks.values { task.cancel() }
        heartbeatTasks.removeAll()
        for task in readLoopTasks.values { task.cancel() }
        readLoopTasks.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        liveConnectionCount = 0
        await LogBus.shared.log("[PXC] stopped")
    }

    // MARK: - Listener setup

    private func startListeners(localAddress: String) throws {
        let ports: [UInt16] = [Self.portPxcCtrl, Self.portMediaCtrl, Self.portMediaData]
        for port in ports {
            let server = PxcTcpServer(port: port) { [weak self] socket in
                Task { await self?.handleAccepted(port: port, socket: socket) }
            }
            try server.start(localAddress: localAddress)
            servers.append(server)
        }
    }

    private func handleAccepted(port: UInt16, socket: BikeSocket) async {
        guard running else { socket.cancel(); return }
        let tag = ":\(port)"
        do {
            try await socket.start()
        } catch {
            await LogBus.shared.log("[\(tag)] accepted socket failed to start: \(error)")
            return
        }
        await LogBus.shared.log("[\(tag)] <<< bike connected (\(socket.remoteDescription))")
        everConnected = true
        reconnectAttempts = 0
        liveConnectionCount += 1

        let key = ObjectIdentifier(socket)
        readLoopTasks[key] = Task { [weak self] in
            if port == Self.portPxcCtrl {
                await self?.ctrlReadLoop(tag: tag, socket: socket)
            } else {
                await self?.mediaReadLoop(tag: tag, socket: socket)
            }
            await self?.onSocketClosed(key: key, socket: socket)
        }
    }

    private func onSocketClosed(key: ObjectIdentifier, socket: BikeSocket) async {
        readLoopTasks.removeValue(forKey: key)
        heartbeatTasks.removeValue(forKey: key)?.cancel()
        socket.cancel()
        liveConnectionCount = max(0, liveConnectionCount - 1)
        if liveConnectionCount == 0 {
            await scheduleReconnectIfNeeded()
        }
    }

    // MARK: - Control plane (:10922, CmdBaseHead framing)

    private func ctrlReadLoop(tag: String, socket: BikeSocket) async {
        while running {
            let frame: PxcFrame
            do {
                frame = try await readPxcFrame(socket)
            } catch {
                if running { await LogBus.shared.log("[\(tag)] ctrl closed: \(error)") }
                return
            }
            let outcome = await handshake.handle(tag: tag, frame: frame)
            for reply in outcome.replies {
                do {
                    try await socket.send(reply.encoded())
                } catch {
                    await LogBus.shared.log("[\(tag)] send failed: \(error)")
                    return
                }
            }
            if let channelName = outcome.channelSelected {
                startChannelHeartbeat(tag: "\(tag)/\(channelName)", socket: socket)
            }
        }
    }

    /// Proactive 0x70000000 heartbeat on a live :10922 channel socket, on top of replying to the
    /// bike's own heartbeats. Required on BOTH CAR_CTRL and CAR_DATA — see file header.
    private func startChannelHeartbeat(tag: String, socket: BikeSocket) {
        let key = ObjectIdentifier(socket)
        guard heartbeatTasks[key] == nil else { return }
        heartbeatTasks[key] = Task { [weak self] in
            var beats = 0
            while let self, await self.running {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard await self.running else { return }
                do {
                    try await socket.send(PxcFrame(cmd: PxcCmd.heartbeat).encoded())
                    beats += 1
                    if beats <= 3 || beats % 15 == 0 {
                        await LogBus.shared.log("[hb] → \(tag) heartbeat #\(beats)")
                    }
                } catch {
                    await LogBus.shared.log("[hb] \(tag) heartbeat send failed: \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Media plane (:10921/:10920, ReqBase framing)

    private func mediaReadLoop(tag: String, socket: BikeSocket) async {
        while running {
            let cmdType: Int16
            let body: Data
            do {
                (cmdType, _, body) = try await readReqBaseFrame(socket)
            } catch {
                if running { await LogBus.shared.log("[\(tag)] media closed: \(error)") }
                return
            }
            do {
                try await handleMediaRequest(tag: tag, cmdType: cmdType, body: body, socket: socket)
            } catch {
                await LogBus.shared.log("[\(tag)] media reply failed: \(error)")
                return
            }
        }
    }

    private func handleMediaRequest(tag: String, cmdType: Int16, body: Data, socket: BikeSocket) async throws {
        switch cmdType {
        case ReqCmd.reqRvConfigCapture:
            try await handleConfigCapture(tag: tag, body: body, socket: socket)

        case ReqCmd.reqGetVersion:
            await LogBus.shared.log("[\(tag)] REQ_GET_VERSION → RLY 49")
            var v = Data(capacity: 8)
            v.appendLE(Int32(3))
            v.appendLE(Int32(1))
            try await socket.send(ReqBaseFrame(cmdType: ReqCmd.rlyGetVersion, body: v).encoded())

        case ReqCmd.reqHeartbeat:
            try await socket.send(ReqBaseFrame(cmdType: ReqCmd.rlyHeartbeat).encoded())

        case ReqCmd.reqConfigCaptureExtend:
            await LogBus.shared.log("[\(tag)] REQ_CONFIGCAPTUREREXTEND len=\(body.count) → RLY 97")
            let state = Data(#"{"state":0}"#.utf8)
            try await socket.send(ReqBaseFrame(cmdType: ReqCmd.rlyConfigCaptureExtend, body: state).encoded())

        case ReqCmd.reqRvDataStart:
            await LogBus.shared.log("[\(tag)] *** REQ_RV_DATA_START *** \(videoSource == nil ? "(no video source attached yet)" : "")")
            await videoSource?.onBikeDataStart()
            try await socket.send(ReqBaseFrame(cmdType: ReqCmd.rlyRvDataStart).encoded())

        case ReqCmd.reqRvDataNext:
            try await handleDataNext(tag: tag, socket: socket)

        case ReqCmd.reqTouch:
            break // Aura 150 is non-touch; log only if it ever happens (surprising, worth knowing).

        default:
            await LogBus.shared.log("[\(tag)] media cmdType=\(cmdType) len=\(body.count)")
        }
    }

    private func handleConfigCapture(tag: String, body: Data, socket: BikeSocket) async throws {
        let req = RvConfigCaptureRequest.parse(body)
        await LogBus.shared.log(
            "[\(tag)] REQ_CONFIG_CAPTURE w=\(req.deviceWidth) h=\(req.deviceHeight) "
                + "fps=\(req.wantFps) wantEncoder=\(req.wantEncoder)"
        )
        let profile = await handshake.profile
        let (rw, rh) = profile.roundCaptureDimensions(width: req.deviceWidth, height: req.deviceHeight)
        negotiatedWidth = rw > 0 ? rw : negotiatedWidth
        negotiatedHeight = rh > 0 ? rh : negotiatedHeight
        await videoSource?.configureCanvas(
            width: negotiatedWidth, height: negotiatedHeight,
            bitrate: profile.videoBitrate, frameRate: profile.videoFrameRate,
            keyframeIntervalSeconds: profile.videoIFrameIntervalSec, forceBaseline: profile.forceBaseline
        )

        let reply = RvConfigCaptureReply(
            encoder: req.wantEncoder == 0 ? 2 : req.wantEncoder,
            captureWidth: negotiatedWidth,
            captureHeight: negotiatedHeight,
            supportExtendProtocol: req.supportExtendProtocol
        )
        await LogBus.shared.log("[\(tag)] → RLY_CONFIG_CAPTURE w=\(negotiatedWidth) h=\(negotiatedHeight)")
        try await socket.send(ReqBaseFrame(cmdType: ReqCmd.rlyRvConfigCapture, body: reply.encoded()).encoded())
    }

    /// The frame pull is lock-step: the bike blocks on this call for one access unit. Reply is
    /// RAW — `[frameSize Int32 LE][Annex-B bytes]`, NOT wrapped in a ReqBase header (see
    /// docs/01-PROTOCOL-REFERENCE.md §4).
    private func handleDataNext(tag: String, socket: BikeSocket) async throws {
        guard let frame = await videoSource?.pollFrame(timeout: .milliseconds(1500)) else {
            await LogBus.shared.log("[\(tag)] REQ_RV_DATA_NEXT: no frame ready")
            return
        }
        var out = Data(capacity: 4 + frame.count)
        out.appendLE(Int32(frame.count))
        out.append(frame)
        try await socket.send(out)
        framesSent += 1
        lastFrameAt = Date()
        if framesSent == 1 { await ConnectionState.shared.set(.streaming) }
        if framesSent <= 5 || framesSent % 60 == 0 {
            await LogBus.shared.log("[\(tag)] sent frame #\(framesSent) (\(frame.count)b)")
        }
    }

    // MARK: - Frame I/O helpers

    private func readPxcFrame(_ socket: BikeSocket) async throws -> PxcFrame {
        let header = try await socket.receiveExactly(16)
        let (cmd, totalLen) = try PxcFrame.decodeHeader(header)
        let payloadLen = max(0, Int(totalLen) - 16)
        let payload = payloadLen > 0 ? try await socket.receiveExactly(payloadLen) : Data()
        return PxcFrame(cmd: cmd, payload: payload)
    }

    private func readReqBaseFrame(_ socket: BikeSocket) async throws -> (cmdType: Int16, token: Int32, body: Data) {
        let header = try await socket.receiveExactly(8)
        let (cmdType, cmdLen, token) = try ReqBaseFrame.decodeHeader(header)
        let body = cmdLen > 0 ? try await socket.receiveExactly(cmdLen) : Data()
        return (cmdType, token, body)
    }

    // MARK: - Probe (phone → bike:10930, one-shot)

    private func probeAndAwaitCallback(bikeIP: String) async {
        let maxAttempts = 5
        var attempt = 0
        while running && !probed && attempt < maxAttempts {
            attempt += 1
            await LogBus.shared.log("[PROBE] connect #\(attempt) -> \(bikeIP):\(Self.bikeProbePort)")
            do {
                try await probeOnce(bikeIP: bikeIP)
                probed = true
                await LogBus.shared.log("[PROBE] *** accepted — bike should now connect back to our ports ***")
                return
            } catch {
                await LogBus.shared.log("[PROBE] attempt #\(attempt) failed: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(750 * Int64(attempt)))
        }
        if !probed && running {
            await LogBus.shared.log(
                "[PROBE] !! bike never answered on :\(Self.bikeProbePort) after \(maxAttempts) attempts "
                    + "— keep the pairing QR / MotoPlay screen open on the dash and try Connect again"
            )
            await ConnectionState.shared.set(.error, detail: "bike did not answer probe")
        }
    }

    private func probeOnce(bikeIP: String) async throws {
        let queue = DispatchQueue(label: "auralink.probe")
        let socket = try BikeSocket.outbound(host: bikeIP, port: Self.bikeProbePort, queue: queue)
        try await socket.start()
        defer { socket.cancel() }

        let packageName = Bundle.main.bundleIdentifier ?? "com.amielsena.auralink"
        let payload = Data(#"{"phoneType":"iOS","packageName":"\#(packageName)"}"#.utf8)
        try await socket.send(PxcFrame(cmd: PxcCmd.mdnsRespond, payload: payload).encoded())

        let frame = try await readPxcFrame(socket)
        await LogBus.shared.log("[PROBE] <- cmd=\(frame.cmdHex) \(frame.payloadText)")
        guard frame.cmd == PxcCmd.mdnsRespondAck, frame.payloadText.contains("true") else {
            throw ProbeError.rejected(frame.payloadText)
        }
    }

    private enum ProbeError: Error, CustomStringConvertible {
        case rejected(String)
        var description: String {
            switch self { case .rejected(let body): return "bike rejected probe: \(body)" }
        }
    }

    // MARK: - Reconnect

    /// Every bike socket closed while we're still supposed to be running. If we'd connected at
    /// least once this session, re-send the probe with backoff — no user Stop/Start needed for a
    /// brief Wi-Fi blip. Matches Kotlin `onAllConnectionsClosed`.
    private func scheduleReconnectIfNeeded() async {
        guard running, everConnected, !reprobing else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            await LogBus.shared.log("[reconnect] gave up after \(reconnectAttempts) attempts — tap Connect to retry")
            await ConnectionState.shared.set(.error, detail: "lost bike link")
            return
        }
        reprobing = true
        await ConnectionState.shared.set(.reconnecting, detail: "attempt \(reconnectAttempts + 1)")
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        defer { reprobing = false }
        guard let bikeIP else { return }
        while running, liveConnectionCount == 0, reconnectAttempts < Self.maxReconnectAttempts {
            reconnectAttempts += 1
            let backoffMs = min(500 + 500 * reconnectAttempts, 4000)
            await LogBus.shared.log(
                "[reconnect] link lost — re-probing (attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts)) "
                    + "in \(backoffMs)ms"
            )
            try? await Task.sleep(for: .milliseconds(Int64(backoffMs)))
            guard running, liveConnectionCount == 0 else { return }
            probed = false
            framesSent = 0
            do {
                try await probeOnce(bikeIP: bikeIP)
                probed = true
                await LogBus.shared.log("[reconnect] probe accepted — waiting for bike to reconnect")
            } catch {
                await LogBus.shared.log("[reconnect] probe failed: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(2500))
        }
    }

    // MARK: - Wi-Fi topology (our IP + the bike's gateway IP on the SoftAP)

    /// The IP assignment can lag slightly right after `NEHotspotManager` reports success, so retry
    /// briefly rather than failing on the first empty read.
    private func resolveWifiAddressWithRetry() async -> (ip: String, netmask: String)? {
        for attempt in 0..<10 {
            if let result = Self.currentWifiIPv4() { return result }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return nil
    }

    /// Reads `en0`'s (the iPhone's Wi-Fi interface) IPv4 address + netmask via `getifaddrs`. No
    /// `Network`/`LinkProperties` equivalent exists on iOS the way Android's `ConnectivityManager`
    /// provides one, so this is the standard POSIX fallback.
    private static func currentWifiIPv4() -> (ip: String, netmask: String)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let interface = p.pointee
            ptr = interface.ifa_next
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name) == "en0" else { continue }
            guard let netmaskPtr = interface.ifa_netmask else { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &ipBuf, socklen_t(ipBuf.count), nil, 0, NI_NUMERICHOST)
            var maskBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(netmaskPtr, socklen_t(netmaskPtr.pointee.sa_len),
                        &maskBuf, socklen_t(maskBuf.count), nil, 0, NI_NUMERICHOST)

            let ip = String(cString: ipBuf)
            let mask = String(cString: maskBuf)
            if !ip.isEmpty, !mask.isEmpty { return (ip, mask) }
        }
        return nil
    }

    /// The ".1" host of the phone's subnet — the CFMoto SoftAP's own DHCP-server convention (it is
    /// always the gateway at the low end of its /24). Simplified from the Kotlin
    /// `gatewayForSubnet` fallback: iOS has one always-on Wi-Fi interface and v1 has no Wi-Fi-Direct
    /// group-owner ambiguity to resolve (P2P is out of scope — see file header).
    private static func gatewayAddress(ip: String, netmask: String) -> String? {
        guard let ipVal = dottedToUInt32(ip), let maskVal = dottedToUInt32(netmask) else { return nil }
        let network = ipVal & maskVal
        let gateway = network | 1
        guard gateway != ipVal else { return nil }
        return uint32ToDotted(gateway)
    }

    private static func dottedToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func uint32ToDotted(_ v: UInt32) -> String {
        [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF].map { String($0) }.joined(separator: ".")
    }
}
