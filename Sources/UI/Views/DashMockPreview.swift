// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// Design concept only — NOT wired into VideoPipeline/NavigationCompositor and not the real
// DashView. A throwaway mockup so Miel can react to the dash's visual language before Phase 5
// builds the real thing. Delete once a direction is picked.
//
// Sized to the CFDL16 default canvas (800x386, docs/01-PROTOCOL-REFERENCE.md §0).
//
// Third revision: full-bleed map + a single flat top bar, matching the Aura 150's actual stock
// dash layout (Miel supplied a reference photo of the OEM T-Box Google Maps screen: edge-to-edge
// map, one solid black status bar across the top, speed centered in it, no side rails). Earlier
// revisions used a right-side telemetry rail with individually-carded/glass readouts — Miel's
// feedback: that reads as a floating widget toolbar, not part of the dash; a flat bar with plain
// text/icons (no per-item background/border) matches the OEM convention and gives the map far
// more room. No "liquid glass" cards anywhere in this revision — the bar itself is flat opaque
// black, and nothing inside it has its own background.

import SwiftUI

struct DashMockPreview: View {
    private let accent = Color(red: 1.0, green: 0.62, blue: 0.13)
    private let barHeight: CGFloat = 62

    var body: some View {
        VStack(spacing: 0) {
            topBar
            mapArea
        }
        .frame(width: 800, height: 386)
        .background(Color.black)
        .clipped()
        .preferredColorScheme(.dark)
    }

    // Single flat bar, full width, no rounding/border/material — matches the OEM reference photo.
    // Three flex-spaced sections: turn instruction (left) / speed (center, dominant) / time +
    // connection + trip info (right). Nothing inside has its own background.
    private var topBar: some View {
        HStack(spacing: 0) {
            turnSection
                .frame(maxWidth: .infinity, alignment: .leading)

            speedSection
                .frame(maxWidth: .infinity, alignment: .center)

            statusSection
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var turnSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text("300 m")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    private var speedSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("62")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text("km/h")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("12 min · 6.4 km")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("14:02")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
    }

    // Full-bleed map, edge to edge, no margins — Phase 3's NavigationCompositor renders the real
    // thing here.
    private var mapArea: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.22, blue: 0.16), Color(red: 0.06, green: 0.14, blue: 0.11)],
                startPoint: .top, endPoint: .bottom
            )
            Text("MAP — Phase 3 (NavigationCompositor)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// `previewLayout`/`traits: .sizeThatFitsLayout` are unavailable pre-iOS 17 — the view already
// bakes in its own `.frame(width: 800, height: 386)`, so no extra layout hint is needed here.
#Preview("Dash mock — 800x386 CFDL16, full-bleed map") {
    DashMockPreview()
}
