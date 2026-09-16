// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// VideoToolbox emits H.264 access units as AVCC (4-byte big-endian length-prefixed NALUs); the
// bike's decoder expects Annex-B (start-code prefixed), per docs/01-PROTOCOL-REFERENCE.md §5. No
// direct Kotlin equivalent — MediaCodec's surface-input encoder emits Annex-B natively on Android,
// so this conversion step didn't exist in VideoPipeline.kt at all.

import CoreMedia
import Foundation

enum AnnexBConverter {
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Converts one AVCC length-prefixed access unit to Annex-B by replacing each 4-byte length
    /// prefix with a `00 00 00 01` start code. `nil` if the sample carries no data buffer.
    static func avccToAnnexB(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        var output = Data(capacity: totalLength)
        dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
            var offset = 0
            while offset + 4 <= totalLength {
                let nalLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard nalLength > 0, offset + nalLength <= totalLength else { break }
                output.append(contentsOf: startCode)
                output.append(UnsafeBufferPointer(start: bytes + offset, count: nalLength))
                offset += nalLength
            }
        }
        return output
    }

    /// Extracts Annex-B SPS+PPS ("parameter sets") from a sample's format description, each
    /// prefixed with a `00 00 00 01` start code. `nil` when the sample carries no format
    /// description (true for every frame after the first — only the initial/keyframe samples do).
    /// Prepend this to the first keyframe's bytes so the bike's decoder can cold-start mid-stream.
    static func parameterSets(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var count = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        guard countStatus == noErr, count > 0 else { return nil }

        var output = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { continue }
            output.append(contentsOf: startCode)
            output.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return output.isEmpty ? nil : output
    }

    /// A sample is a keyframe (IDR) unless explicitly marked "not sync" — the standard VideoToolbox
    /// convention (an absent attachments array also means "sync", i.e. a keyframe).
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              let attachments = (attachmentsArray as NSArray).firstObject as? NSDictionary else {
            return true
        }
        let notSync = (attachments[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }
}
