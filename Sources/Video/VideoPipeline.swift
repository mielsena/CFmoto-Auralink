// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Ties `H264Encoder` + `FrameQueue` + a pluggable frame source together and implements
// `BikeVideoSource` (the seam `EasyConnProber` pulls frames through — see that file's header).
// Ported from the orchestration half of VideoPipeline.kt (`start`/`configureBikeCanvas`/
// `onBikeDataStart`/`pollFrame`); the Presentation/VirtualDisplay/MediaProjection source half has
// no iOS equivalent and is NOT ported. Phase 2 attaches `TestPatternSource`; Phase 3 will attach
// `NavigationCompositor` instead — `VideoPipeline` itself doesn't know or care which.

import CoreVideo
import Foundation

/// `CVPixelBuffer` (a CoreVideo CF type) isn't `Sendable`, but it's a thread-safe reference-counted
/// object in practice — Apple's own APIs pass it across queues freely (e.g. `AVCaptureVideoDataOutput`
/// delegate callbacks). This box makes that explicit at the one place it crosses an actor boundary
/// (`PixelBufferSource.currentPixelBuffer()` → `VideoPipeline`'s feed loop) instead of leaving a
/// Swift 6 concurrency warning that would become a hard error.
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Anything that can hand `VideoPipeline` a frame to encode. May return the SAME `CVPixelBuffer`
/// on consecutive calls if nothing changed — the fixed-rate feed loop below re-submits it anyway,
/// which is what satisfies the bike's repeat-frame requirement (see H264Encoder.swift's header).
protocol PixelBufferSource: Sendable {
    func currentPixelBuffer() async -> SendablePixelBuffer?
}

actor VideoPipeline: BikeVideoSource {
    private let encoder = H264Encoder()
    private let queue = FrameQueue()
    private var source: PixelBufferSource?
    private var feedTask: Task<Void, Never>?
    private var forceNextKeyframe = false
    private var configuredWidth = 0
    private var configuredHeight = 0
    private var frameRate = 30
    private var configured = false

    func attach(source: PixelBufferSource?) {
        self.source = source
    }

    // MARK: - BikeVideoSource

    func configureCanvas(
        width: Int, height: Int, bitrate: Int, frameRate: Int,
        keyframeIntervalSeconds: Int, forceBaseline: Bool
    ) async {
        guard width > 0, height > 0 else { return }
        if configured, configuredWidth == width, configuredHeight == height { return }
        do {
            try encoder.configure(
                width: width, height: height, bitrate: bitrate, frameRate: frameRate,
                keyframeIntervalSeconds: keyframeIntervalSeconds, forceBaseline: forceBaseline
            )
        } catch {
            await LogBus.shared.log("[VIDEO] configure failed: \(error)")
            return
        }
        encoder.onEncodedFrame = { [weak self] frame in
            Task { await self?.enqueue(frame) }
        }
        configuredWidth = width
        configuredHeight = height
        self.frameRate = frameRate
        configured = true
        await LogBus.shared.log(
            "[VIDEO] encoder configured \(width)x\(height) \(frameRate)fps \(bitrate / 1000)kbps "
                + (forceBaseline ? "Baseline@3.1" : "default profile")
        )
        startFeedLoopIfNeeded()
    }

    /// Bike is about to start pulling (`REQ_RV_DATA_START`). Flush stale frames and force the next
    /// encode to be a keyframe so the first access unit the bike receives is a full SPS+PPS+IDR —
    /// mirrors Kotlin `VideoPipeline.onBikeDataStart()`.
    func onBikeDataStart() async {
        await queue.clear()
        forceNextKeyframe = true
        await LogBus.shared.log("[VIDEO] bike attached → flushed queue, next frame will be a keyframe")
    }

    func pollFrame(timeout: Duration) async -> Data? {
        await queue.poll(timeout: timeout)
    }

    func stop() async {
        feedTask?.cancel()
        feedTask = nil
        encoder.invalidate()
        await queue.clear()
        configured = false
    }

    // MARK: - Internal feed loop

    private func enqueue(_ frame: H264EncodedFrame) async {
        await queue.offer(frame.annexB)
    }

    private func startFeedLoopIfNeeded() {
        guard feedTask == nil else { return }
        feedTask = Task { [weak self] in
            await self?.feedLoop()
        }
    }

    /// Fixed-rate feed at the encoder's configured frame rate. This always-on cadence is what
    /// satisfies the bike's repeat-frame requirement without a separate "idle" path — see
    /// H264Encoder.swift's header. A static source (test pattern, or a MapKit view that hasn't
    /// panned) just yields the same buffer every tick, which is fine: the encoder still emits
    /// (cheap, mostly-skip) frames well under the bike's ~9s socket timeout.
    private func feedLoop() async {
        while !Task.isCancelled {
            let interval = Duration.milliseconds(1000 / max(1, frameRate))
            guard let boxed = await source?.currentPixelBuffer() else {
                try? await Task.sleep(for: interval)
                continue
            }
            let forceKey = forceNextKeyframe
            forceNextKeyframe = false
            encoder.encode(pixelBuffer: boxed.buffer, forceKeyframe: forceKey)
            try? await Task.sleep(for: interval)
        }
    }
}
