// SPDX-License-Identifier: AGPL-3.0-or-later
// Part of AuraLink — an iOS port of OpenCfMoto (https://github.com/zanderp/open-cfmoto), AGPLv3.
// See LICENSE and NOTICE.
//
// STATUS: entry-point stub. Replace the placeholder root view below as the real UI in
// Sources/UI/Views/ is built (see docs/02-IOS-ARCHITECTURE-PLAN.md, phase 5).

import SwiftUI

@main
struct AuraLinkApp: App {
    var body: some Scene {
        WindowGroup {
            ScaffoldPlaceholderView()
        }
    }
}

/// Temporary root view so the project builds and runs end-to-end before the real Connect/Dash/
/// Setup screens exist. Delete once `Sources/UI/Views/ConnectView.swift` is wired up as the root.
struct ScaffoldPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("AuraLink")
                .font(.title.bold())
            Text("Scaffold builds. Real UI not wired up yet — see docs/02-IOS-ARCHITECTURE-PLAN.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
