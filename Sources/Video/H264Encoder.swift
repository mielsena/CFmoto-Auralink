// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// `VTCompressionSession` wrapper matching the encoder contract in
// docs/01-PROTOCOL-REFERENCE.md §5. Ported from the MediaCodec-specific half of
// VideoPipeline.kt's `createEncoder` (the Presentation/VirtualDisplay half has no iOS equivalent
// and is NOT ported — see NavigationCompositor.swift, Phase 3, for the iOS frame source instead).
//
// Differences from the Android original, both intentional:
//  - No `KEY_REPEAT_PREVIOUS_FRAME_AFTER` equivalent. That MediaCodec flag exists because a
//    *surface*-input encoder only emits on new buffers. This wrapper takes a `CVPixelBuffer` per
//    call instead, and `VideoPipeline` drives it from a fixed-rate timer that re-submits the
//    current frame every tick whether or not it changed — satisfying the bike's ~9s socket
//    timeout by construction, not as a special "idle" case (see VideoPipeline.swift).
//  - `AllowFrameReordering = false` is the direct equivalent of the Kotlin `KEY_LATENCY = 1` hint:
//    the bike's wire format carries no timestamps, so a decoder fed reordered (B-)frames could
//    never reassemble display order.
//  - `forceKeyframe` is a plain per-call argument (VideoToolbox supports this directly via
//    `kVTEncodeFrameOptionKey_ForceKeyFrame`), so there's no separate "request a keyframe soon"
//    method the way `MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME` needed — the caller
//    (`VideoPipeline.onBikeDataStart`) just passes `true` on its next `encode(...)` call.

import CoreMedia
import Foundation
import VideoToolbox

struct H264EncodedFrame: Sendable {
    let annexB: Data
    let isKeyframe: Bool
}

enum H264EncoderError: Error, CustomStringConvertible {
    case sessionCreateFailed(OSStatus)
    case propertyFailed(String, OSStatus)
    case notConfigured

    var description: String {
        switch self {
        case .sessionCreateFailed(let s): return "H264Encoder: VTCompressionSessionCreate failed (\(s))"
        case .propertyFailed(let key, let s): return "H264Encoder: setProperty \(key) failed (\(s))"
        case .notConfigured: return "H264Encoder: encode called before configure"
        }
    }
}

final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private(set) var width = 0
    private(set) var height = 0
    private var frameCount: Int64 = 0
    private var timescale: Int32 = 30

    /// Delivered synchronously from `encode(...)` in the common case, but VideoToolbox may invoke
    /// its output handler asynchronously on its own thread — callers must not assume this fires on
    /// the calling thread/actor.
    var onEncodedFrame: ((H264EncodedFrame) -> Void)?

    func configure(
        width: Int, height: Int, bitrate: Int, frameRate: Int,
        keyframeIntervalSeconds: Int, forceBaseline: Bool
    ) throws {
        invalidate()
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &newSession
        )
        guard status == noErr, let session = newSession else {
            throw H264EncoderError.sessionCreateFailed(status)
        }

        try Self.setProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try Self.setProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        if forceBaseline {
            try Self.setProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_3_1)
        }
        try Self.setProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        try Self.setProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        try Self.setProperty(
            session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
            (frameRate * keyframeIntervalSeconds) as CFNumber
        )
        try Self.setProperty(
            session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            Double(keyframeIntervalSeconds) as CFNumber
        )

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        self.width = width
        self.height = height
        self.frameCount = 0
        self.timescale = Int32(max(1, frameRate))
    }

    /// Encodes one pixel buffer. Output (if any) arrives via `onEncodedFrame`. `forceKeyframe`
    /// should be `true` exactly once right after a bike client attaches (`REQ_RV_DATA_START`) so
    /// the very first access unit it pulls is a full SPS+PPS+IDR.
    func encode(pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        guard let session else { return }
        let pts = CMTime(value: frameCount, timescale: timescale)
        frameCount += 1

        var frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleOutput(sampleBuffer)
        }
    }

    private func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        guard var annexB = AnnexBConverter.avccToAnnexB(sampleBuffer) else { return }
        let isKeyframe = AnnexBConverter.isKeyframe(sampleBuffer)
        if isKeyframe, let params = AnnexBConverter.parameterSets(from: sampleBuffer) {
            annexB = params + annexB
        }
        onEncodedFrame?(H264EncodedFrame(annexB: annexB, isKeyframe: isKeyframe))
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func setProperty(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw H264EncoderError.propertyFailed(key as String, status) }
    }
}
