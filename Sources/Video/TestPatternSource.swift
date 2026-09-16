// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Temporary `PixelBufferSource` for Phase 2 (docs/02-IOS-ARCHITECTURE-PLAN.md's phased build
// order): a solid-color test card instead of MapKit, so a black-screen/disconnect bug on first
// bike test can be isolated to the video path (encoder, framing, repeat-frame timing) rather than
// MapKit rendering. No Kotlin equivalent — the Android app never needed this scaffolding step
// because MediaCodec's surface-input model made the encoder path trivially testable with any
// Presentation content. Delete this file once Phase 3's `NavigationCompositor` is wired in and
// proven on the bike; it has no other purpose.

import CoreGraphics
import CoreVideo
import Foundation
import UIKit

actor TestPatternSource: PixelBufferSource {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    private var tick = 0

    func configure(width: Int, height: Int) {
        guard width > 0, height > 0, self.width != width || self.height != height else { return }
        self.width = width
        self.height = height
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool)
        pool = newPool
    }

    func currentPixelBuffer() async -> SendablePixelBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        render(into: pixelBuffer)
        return SendablePixelBuffer(buffer: pixelBuffer)
    }

    /// Cycling background color + a frame counter, so a captured bike-screen photo/video visibly
    /// proves frames are updating (not just a frozen first frame) without needing real map content.
    private func render(into buffer: CVPixelBuffer) {
        tick += 1
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return }

        let hue = CGFloat(tick % 360) / 360.0
        context.setFillColor(UIColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let text = "AuraLink test pattern — frame \(tick)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(12, CGFloat(height) / 10), weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        text.draw(at: CGPoint(x: 16, y: CGFloat(height) / 2 - 16), withAttributes: attrs)
        UIGraphicsPopContext()
    }
}
