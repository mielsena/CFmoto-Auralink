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
// Three-column layout: left status rail / map / right telemetry rail. Deliberately NOT a CarPlay-
// style tappable icon rail — the Aura 150 is non-touch (handlebar buttons only, per
// docs/00-README-HANDOFF.md), so nothing here can be a button; both rails are read-only readouts.
//
// Data-source honesty: right rail only shows readouts we can actually source — Speed/ETA/distance
// come from GPS + route progress (CoreLocation/MKDirections, already planned for trip logging).
// Fuel/RPM/engine-temp are deliberately NOT in this design — per
// reference/android-docs/RE-VEHICLE-TELEMETRY.md, CFMoto gates them behind their paid T-Box and
// none of BLE, the PXC/video protocol, or the dash's Wi-Fi network expose them. The only real path
// is a separate Bluetooth OBD-II dongle at the bike's diagnostic port; Miel decided (2026-09-16)
// not to design around hardware he hasn't bought — revisit only if that changes.
//
// Background treatment: hand-built "liquid glass" look (frosted material + dark tint for text
// contrast + soft light rim gradient) since the iOS 16 deployment target predates Apple's real
// Liquid Glass APIs (iOS 26+).

import SwiftUI

private struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tintOpacity: Double = 0.55

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thickMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(tintOpacity))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.28), .white.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.25
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private extension View {
    func liquidGlass(cornerRadius: CGFloat = 16, tintOpacity: Double = 0.55) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tintOpacity: tintOpacity))
    }
}

struct DashMockPreview: View {
    private let accent = Color(red: 1.0, green: 0.62, blue: 0.13)

    var body: some View {
        HStack(spacing: 12) {
            leftRail
            mapArea
            rightRail
        }
        .padding(14)
        .frame(width: 800, height: 386)
        .background(
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.10, blue: 0.15), Color(red: 0.03, green: 0.05, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipped()
        .preferredColorScheme(.dark)
    }

    // Left rail: identity + connection status only — no icons to tap, this dash has no touch.
    private var leftRail: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(accent)
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 20, height: 1)
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
            Spacer()
        }
        .padding(.top, 14)
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .liquidGlass(cornerRadius: 20)
    }

    // Center: the map, with the turn instruction floating over it (Apple Maps CarPlay convention)
    // instead of taking its own dedicated row — frees up much more width for the map itself.
    private var mapArea: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.22, blue: 0.16), Color(red: 0.06, green: 0.14, blue: 0.11)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    Text("MAP — Phase 3 (NavigationCompositor)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                )

            turnCard
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var turnCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 0) {
                Text("300 m")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("Ortigas Ave Ext")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16)
    }

    // Right rail: real-data readouts stacked top to bottom. Speed is the biggest/most prominent
    // since it's both real (GPS) and the most safety-relevant. Fuel is explicitly "—" with a
    // caption, not a fabricated number — see file header.
    // Fuel/engine-temp deliberately omitted — confirmed unreachable without a separate OBD2
    // dongle (reference/android-docs/RE-VEHICLE-TELEMETRY.md), and Miel decided not to design
    // around hardware he hasn't bought. Revisit only if that changes.
    private var rightRail: some View {
        VStack(spacing: 10) {
            telemetryCard(value: "62", unit: "km/h", label: "SPEED", valueColor: .white, prominent: true)
            telemetryCard(value: "12", unit: "min", label: "ETA", valueColor: .white, prominent: false)
            telemetryCard(value: "6.4", unit: "km", label: "TO GO", valueColor: .white, prominent: false)
            Spacer(minLength: 0)
        }
        .frame(width: 168)
    }

    private func telemetryCard(value: String, unit: String, label: String, valueColor: Color, prominent: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1.2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: prominent ? 44 : 26, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: prominent ? 15 : 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.vertical, prominent ? 14 : 10)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 16)
    }

}

// `previewLayout`/`traits: .sizeThatFitsLayout` are unavailable pre-iOS 17 — the view already
// bakes in its own `.frame(width: 800, height: 386)`, so no extra layout hint is needed here.
#Preview("Dash mock — 800x386 CFDL16, 3-column") {
    DashMockPreview()
}
